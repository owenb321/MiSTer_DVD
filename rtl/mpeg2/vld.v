/* 
 * vld.v
 * 
 * Copyright (c) 2007 Koen De Vleeschauwer. 
 * 
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND 
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE 
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL 
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS 
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY 
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF 
 * SUCH DAMAGE.
 */

/*
 * vld - Variable Length Decoder. Scalability not implemented. Maximum vertical size of image in pixels: 2800.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1
//`define DEBUG_VLC 1

/*
 * video decoding process as specified in 13818-2, par. 7.1 through 7.6
 */

module vld(clk, clk_en, rst, 
  getbits, signbit, advance, align, wait_state,                                             // interface with getbits
  quant_wr_data, quant_wr_addr, quant_rst,                                                  // interface with quantizer rams via rld_fifo
  wr_intra_quant, wr_non_intra_quant, wr_chroma_intra_quant, wr_chroma_non_intra_quant,     // interface with quantizer rams via rld_fifo
  rld_wr_en, rld_cmd, dct_coeff_run, dct_coeff_signed_level, dct_coeff_end,                 // interface with rld_fifo
  quantiser_scale_code, alternate_scan, q_scale_type, macroblock_intra, intra_dc_precision, // interface with rld_fifo
  picture_coding_type, picture_structure, motion_type, dct_type,                            // interface with motcomp
  motion_vert_field_select_0_0, motion_vert_field_select_0_1,                               // interface with motcomp
  motion_vert_field_select_1_0, motion_vert_field_select_1_1,                               // interface with motcomp
  second_field, update_picture_buffers, last_frame, mb_width, mb_height, chroma_format,     // interface with motcomp
  macroblock_address, macroblock_motion_forward, macroblock_motion_backward,                // interface with motcomp
  motion_vector_valid,                                                                      // interface with motcomp - motion vectors
  pmv_0_0_0, pmv_0_0_1, pmv_1_0_0, pmv_1_0_1, pmv_0_1_0, pmv_0_1_1, pmv_1_1_0, pmv_1_1_1,   // interface with motcomp - motion vectors
  dmv_0_0, dmv_0_1, dmv_1_0, dmv_1_1,                                                       // interface with motcomp - dual prime motion vectors
  horizontal_size, vertical_size, display_horizontal_size, display_vertical_size,           // interface with syncgen
  matrix_coefficients,                                                                      // interface with yuv2rgb
  frame_rate_code, frame_rate_extension_n, frame_rate_extension_d,                          // interface with regfile
  aspect_ratio_information,
  progressive_sequence, progressive_frame, repeat_first_field, top_field_first,             // interface with resample
  vld_err,                                                                                  // asserted when vld code parse error
  drop_pic_req, drop_pic_ack, drop_pic_rff, drop_pic_field,                                 // DVD-FORK (frame-drop governor O[19] + field-pair drop)
  dbg_drop_probe,                                                                           // DVD-FORK DEBUG (2026-08-05): in-vld drop-path probe (Thayer drops=0)
  flags_commit,                                                                             // DVD-FORK (round 11): per-picture display flags are valid (coding ext parsed)
  pic_informative, informative_commit,                                                      // DVD-FORK (film evidence gate): this picture carried real evidence
  cc_pair_valid, cc_pair, cc_pair_field,                                                    // DVD-FORK (line-21 CC): EIA-608 byte pairs sniffed out of user_data
  mpeg1                                                                                     // DVD-FORK FIX (mpeg1): stream is MPEG-1 (no sequence extension) — to rld via the rld fifo
  );

  input            clk;                           // clock
  input            clk_en;                        // clock enable
  input            rst;                           // synchronous active low reset
  input      [23:0]getbits;                       // bit-aligned slice data. 16 bits long as longest variable length code is 16 bits.
  input            signbit;                       // sign bit of dct coefficient

  output reg  [4:0]advance;                       // number of bits to advance the bitstream (advance <= 24)
  output reg       align;                         // byte-align getbits and move forward one byte.

  /* DVD-FORK (line-21 closed captions, 2026-08-25) — see docs/closed_captions.md.
   * EIA-608 caption bytes ride in MPEG-2 user_data attached to the GOP header. This
   * is a passive SNOOP, not a new FSM branch: user_data was already walked one
   * byte at a time by STATE_NEXT_START_CODE (next_advance=0, align=1), so the
   * payload bytes stream past in getbits[23:16] for free. Nothing in the state
   * graph, the advance/align logic, or the decode path changes. */
  output reg       cc_pair_valid;                 // one pulse per caption byte pair
  output reg [15:0]cc_pair;                       // {cc_byte_1, cc_byte_2} (parity bit included)
  output reg       cc_pair_field;                 // 1 = field 1 (CC1/CC2), 0 = field 2

  output reg  [7:0]quant_wr_data;                 // data bus for quantizer matrix rams
  output reg  [5:0]quant_wr_addr;                 // address bus for quantizer matrix rams
  output reg       quant_rst;                     // reset quant matrices to default values
  output reg       wr_intra_quant;                // write enable for intra quantiser matrix
  output reg       wr_non_intra_quant;            // write enable for non intra quantiser matrix
  output reg       wr_chroma_intra_quant;         // write enable for chroma intra quantiser matrix
  output reg       wr_chroma_non_intra_quant;     // write enable for chroma non intra quantiser matrix

  output reg       vld_err;                       // vld_err is asserted when a slice parsing error has occurred. self-repairing.

  /* DVD-FORK (frame-drop governor, O[19]).
   * drop_pic_req (level, from dvd/frame_drop_ctl.sv via mpeg2video): the decoder is
   *   behind the display cadence; drop the next droppable B-frame to catch up.
   * drop_pic_ack (1-cycle pulse, to frame_drop_ctl): a B-frame WAS dropped this
   *   picture — spend one drop credit.
   * A B-frame is never a reference, so skipping its decode cannot corrupt any later
   *   picture. When we drop, we (a) suppress update_picture_buffers for it so
   *   motcomp/picbuf never set it up, reconstruct, or emit it, and (b) skip its
   *   slices by routing the FSM straight to STATE_NEXT_START_CODE (a cheap
   *   byte-aligned start-code hunt) instead of decoding macroblocks — which is where
   *   the expensive VLC + IDCT + motion-comp work is. The governor simply repeats the
   *   previous frame in the dropped B's display slot. See docs/motcomp_throughput.md. */
  input            drop_pic_req;
  output reg       drop_pic_ack;
  output reg       drop_pic_rff;  // DVD-FORK (film-aware drop cost): rff of the DROPPED picture, valid with drop_pic_ack
  output reg       drop_pic_field; // DVD-FORK (field-pair drop): dropped picture was a FIELD (cost 1), valid with drop_pic_ack
  output reg       second_field;   // declared here (used by the field-pair drop_now_comb); driven near update_picture_buffers
  /* DVD-FORK DEBUG (2026-08-05, Thayer drops=0): the request reads asserted at
   * the mpeg2video-level export yet zero acks, and the identical RTL drops in
   * sim in every regime incl. display-blocked (+DRAIN). These taps read the
   * ACTUAL in-vld nodes so a build-level net divergence becomes visible:
   *   [9:6] hdr_cnt   — wrapping count of clk_en visits to STATE_PICTURE_HEADER
   *   [5:2] dropnow_cnt — wrapping count of drop_now_comb TRUE at those visits
   *   [1]   req_in    — drop_pic_req as sampled INSIDE the vld at the last header
   *   [0]   b_seen    — drop_hdr_is_b at the last header visit
   * All (* preserve *) so the fitter may not merge them with the export copies. */
  output wire [9:0] dbg_drop_probe;   // logic lives beside drop_now_comb (below)

  parameter [7:0]
    STATE_NEXT_START_CODE             = 8'h00,
    STATE_START_CODE                  = 8'h01,

    STATE_PICTURE_HEADER              = 8'h02,
    STATE_PICTURE_HEADER0             = 8'h03,
    STATE_PICTURE_HEADER1             = 8'h04,
    STATE_PICTURE_HEADER2             = 8'h05,

    STATE_SEQUENCE_HEADER             = 8'h06,
    STATE_SEQUENCE_HEADER0            = 8'h07,
    STATE_SEQUENCE_HEADER1            = 8'h08,
    STATE_SEQUENCE_HEADER2            = 8'h09,
    STATE_SEQUENCE_HEADER3            = 8'h0a,

    STATE_GROUP_HEADER                = 8'h0b,
    STATE_GROUP_HEADER0               = 8'h0c,

    STATE_EXTENSION_START_CODE        = 8'h10,
    STATE_SEQUENCE_EXT                = 8'h11,
    STATE_SEQUENCE_EXT0               = 8'h12,
    STATE_SEQUENCE_EXT1               = 8'h13,
    STATE_SEQUENCE_DISPLAY_EXT        = 8'h14,
    STATE_SEQUENCE_DISPLAY_EXT0       = 8'h15,
    STATE_SEQUENCE_DISPLAY_EXT1       = 8'h16,
    STATE_SEQUENCE_DISPLAY_EXT2       = 8'h17,
    STATE_QUANT_MATRIX_EXT            = 8'h18,
    STATE_PICTURE_CODING_EXT          = 8'h19,
    STATE_PICTURE_CODING_EXT0         = 8'h1a,
    STATE_PICTURE_CODING_EXT1         = 8'h1b,

    STATE_LD_INTRA_QUANT0             = 8'h20,
    STATE_LD_INTRA_QUANT1             = 8'h21,
    STATE_LD_NON_INTRA_QUANT0         = 8'h22,
    STATE_LD_NON_INTRA_QUANT1         = 8'h23,
    STATE_LD_CHROMA_INTRA_QUANT1      = 8'h24,
    STATE_LD_CHROMA_NON_INTRA_QUANT1  = 8'h25,

    STATE_SLICE                       = 8'h31,
    STATE_SLICE_EXTENSION             = 8'h32,
    STATE_SLICE_EXTRA_INFORMATION     = 8'h33,
    STATE_NEXT_MACROBLOCK             = 8'h34,
    STATE_MACROBLOCK_SKIP             = 8'h35,
    STATE_DELAY_EMPTY_BLOCK           = 8'h36,
    STATE_EMIT_EMPTY_BLOCK            = 8'h37,
    STATE_MACROBLOCK_TYPE             = 8'h38,
    STATE_MOTION_TYPE                 = 8'h39,
    STATE_DCT_TYPE                    = 8'h3a,
    STATE_MACROBLOCK_QUANT            = 8'h3b,

    STATE_NEXT_MOTION_VECTOR          = 8'h40,
    STATE_MOTION_VERT_FLD_SEL         = 8'h41, // motion_vectors: motion_vertical_field_select
    STATE_MOTION_CODE                 = 8'h42, // motion_vector: motion_code
    STATE_MOTION_RESIDUAL             = 8'h43, // motion_vector: motion_residual
    STATE_MOTION_DMVECTOR             = 8'h44, // motion_vector: dmvector
    STATE_MOTION_PREDICT              = 8'h45, // motion_vector: prediction pipeline begin
    STATE_MOTION_PIPELINE_FLUSH       = 8'h46, // motion_vector: prediction pipeline end

    STATE_MARKER_BIT_0                = 8'h60,
    STATE_CODED_BLOCK_PATTERN         = 8'h61,
    STATE_CODED_BLOCK_PATTERN_1       = 8'h62,
    STATE_CODED_BLOCK_PATTERN_2       = 8'h63,

    STATE_BLOCK                       = 8'h70,
    STATE_NEXT_BLOCK                  = 8'h71,
    STATE_DCT_DC_LUMI_SIZE            = 8'h72,
    STATE_DCT_DC_CHROMI_SIZE          = 8'h73,
    STATE_DCT_DC_DIFF                 = 8'h74,
    STATE_DCT_DC_DIFF_0               = 8'h75,
    STATE_DCT_SUBS_B15                = 8'h76,
    STATE_DCT_ESCAPE_B15              = 8'h77,
    STATE_DCT_SUBS_B14                = 8'h78,
    STATE_DCT_ESCAPE_B14              = 8'h79,
    STATE_DCT_NON_INTRA_FIRST         = 8'h7a,
    STATE_NON_CODED_BLOCK             = 8'h7b,
    STATE_DCT_ERROR                   = 8'h7c,
    STATE_DCT_ESCAPE_M1               = 8'h7d, // DVD-FORK FIX (mpeg1): second byte of a double-byte MPEG-1 escape level

    STATE_SEQUENCE_END                = 8'h80,

    STATE_ERROR                       = 8'hff;

  /* start codes */
  parameter [7:0]
    CODE_PICTURE_START                = 8'h00,
    CODE_USER_DATA_START              = 8'hb2,
    CODE_SEQUENCE_HEADER              = 8'hb3,
    CODE_SEQUENCE_ERROR               = 8'hb4,
    CODE_EXTENSION_START              = 8'hb5,
    CODE_SEQUENCE_END                 = 8'hb7,
    CODE_GROUP_START                  = 8'hb8;

  /* extension start codes */
  parameter [3:0]
    EXT_SEQUENCE                      = 4'b0001,
    EXT_SEQUENCE_DISPLAY              = 4'b0010,
    EXT_QUANT_MATRIX                  = 4'b0011,
    EXT_COPYRIGHT                     = 4'b0100,
    EXT_SEQUENCE_SCALABLE             = 4'b0101,
    EXT_PICTURE_DISPLAY               = 4'b0111,
    EXT_PICTURE_CODING                = 4'b1000,
    EXT_PICTURE_SPATIAL_SCALABLE      = 4'b1001,
    EXT_PICTURE_TEMPORAL_SCALABLE     = 4'b1010,
    EXT_CAMERA_PARAMETERS             = 4'b1011,
    EXT_ITU_T                         = 4'b1100;

`include "vld_codes.v"

  parameter
    STRICT_MARKER_BIT = 1'b0;  /* set to 1 to check marker bits are 1. May break some streams. */

  /*
   *  Table 7-7 Meaning of indices in PMV[r][s][t], vector[r][s][t] and vector'[r][s][t]
   *
   *    0                                 1
   *  r First motion vector in Macroblock Second motion vector in Macroblock
   *  s Forward motion Vector             Backwards motion Vector
   *  t Horizontal Component              Vertical Component
   *
   *  NOTE r also takes the values 2 and 3 for derived motion vectors used with dual-prime prediction.
   *  Since these motion vectors are derived they do not themselves have motion vector predictors.
   */
  parameter [2:0] /* motion vector codes */
    MOTION_VECTOR_0_0_0 = 3'd0,
    MOTION_VECTOR_0_0_1 = 3'd1,
    MOTION_VECTOR_1_0_0 = 3'd2,
    MOTION_VECTOR_1_0_1 = 3'd3,
    MOTION_VECTOR_0_1_0 = 3'd4,
    MOTION_VECTOR_0_1_1 = 3'd5,
    MOTION_VECTOR_1_1_0 = 3'd6,
    MOTION_VECTOR_1_1_1 = 3'd7;

  reg         [7:0]state;
  reg         [7:0]next;

  reg         [4:0]next_advance;

  reg         [5:0]cnt; // counter used when loading quant matrices

  /* in start code */
  wire        [7:0]start_code;

  /* position in video stream */
  reg              sequence_header_seen;    /* set when sequence header encountered, cleared when sequence end encountered  */
  reg              sequence_extension_seen; /* set when sequence extension encountered, cleared when sequence end encountered (and re-armed at every sequence header — see the mpeg1 latch) */
  reg              picture_header_seen;     /* set when picture header encountered, cleared when sequence end encountered  */

  /* DVD-FORK FIX (mpeg1): MPEG-1 decode mode. Latched at every accepted picture start
   * code (see the always block near sequence_extension_seen for the detection policy)
   * and muxes the extension-borne decode parameters to their MPEG-1 constants.
   * Exported to rld (per-picture, through the rld fifo) for mismatch control. */
  output reg       mpeg1;
  /* DVD-FORK FIX (mpeg1): skip the slices of an MPEG-1 D-picture (declared early —
   * used by the slice-routing gate in the next-state logic; policy at the latch). */
  reg              skip_d_picture;

  /* DVD-FORK (frame-drop governor, O[19]).
   * drop_now_comb is evaluated combinationally while the FSM is in STATE_PICTURE_HEADER,
   * where the incoming picture_coding_type is still in getbits (loadreg offset 10,
   * width 3 => getbits[13:11]) before it is registered. We only ever drop a
   * FRAME_PICTURE B-frame: B is never a reference (safe to skip) and picture_structure
   * here still holds the previous picture's value, which for progressive DVD content is
   * always FRAME_PICTURE — so interlaced field-picture B's are naturally left alone.
   * drop_this_picture latches the decision for the duration of the picture so the
   * slice-routing gate can bypass every slice of the dropped B. */
  wire             drop_now_comb;   // assigned below, after picture_structure is declared
  (* preserve *) reg drop_this_picture;   // DVD-FORK FIX (2026-08-05): see drop_now_comb hardening note

  /* in sequence header */
  output wire[13:0]horizontal_size;
  output wire[13:0]vertical_size;
  output reg  [7:0]mb_width;   /* par. 6.3.3. width of the encoded luminance component of pictures in macroblocks */
  output reg  [7:0]mb_height;  /* par. 6.3.3. height of the encoded luminance component of frame pictures in macroblocks */
  output wire [3:0]aspect_ratio_information;
  output wire [3:0]frame_rate_code;
  wire       [29:0]bit_rate;
  wire       [17:0]vbv_buffer_size;
  wire             constrained_parameters_flag;

  /* in sequence header extension */
  wire        [7:0]profile_and_level_indication;
  output wire      progressive_sequence;
  output wire [1:0]chroma_format;
  wire             low_delay;
  output wire [1:0]frame_rate_extension_n;
  output wire [4:0]frame_rate_extension_d;

  /* in sequence display extension */
  wire        [2:0]video_format;
  wire        [7:0]colour_primaries;
  wire        [7:0]transfer_characteristics;
  output wire [7:0]matrix_coefficients;
  output wire[13:0]display_horizontal_size;
  output wire[13:0]display_vertical_size;

  /* in picture coding extension */
  wire        [3:0]f_code_00;
  wire        [3:0]f_code_01;
  wire        [3:0]f_code_10;
  wire        [3:0]f_code_11;
  output wire [1:0]intra_dc_precision;
  output wire [1:0]picture_structure;

  // DVD-FORK (frame-drop governor, O[19]): droppable-B detection (see block above).
  // DVD-FORK FIX (2026-08-05, Thayer drops=0): HW ran with debt=15/req=1/en=1/ok=1
  // (row-16 readout) and B-frames plentiful, yet ZERO acks — while the IDENTICAL
  // RTL drops 43/43-faithfully in vld_drop_rff_tb on the same ES. That is the
  // round-10 failure class again (see drop_rff_lat below: a shared-register
  // compare mangled by physical synthesis in the BUILD, sim-perfect). Harden the
  // whole decision path the same proven way: (* keep *) the two compare terms so
  // synthesis may not narrow/merge them across the shared fan-out registers, and
  // (* preserve *) the decision/ack state bits below.
  (* keep *) wire drop_hdr_is_b = (getbits[13:11] == B_TYPE);
  /* DVD-FORK FIX (2026-08-05 round 2, THE Thayer drops=0 root): the in-vld probe
   * (row 16 v2) showed hdr_cnt ticking, req_in_vld=1, b_seen=1 at B headers —
   * and dropnow_cnt frozen at 0. Three of drop_now_comb's four terms probe TRUE
   * at the same instant, so the fourth — (picture_structure == FRAME_PICTURE) —
   * evaluates FALSE on HW, while the stream's every coding extension codes
   * frame (3) and the IDENTICAL RTL passes in sim (incl. +DRAIN display-blocked).
   * That is the round-10 failure class one register over: the shared
   * `picture_structure` loadreg fans out across the decoder and physical
   * synthesis is free to retime/duplicate it; the copy reaching this compare
   * did not carry the value (same as drop_rff_lat's mangled rff export, fixed
   * below by a preserved private copy). Same proven medicine: a (* preserve *)
   * PRIVATE register sampling the SAME bits the loadreg samples
   * (getbits[21:20] at STATE_PICTURE_CODING_EXT0, offset 2 width 2) — bitwise
   * identical semantics, immune to shared-fanout mangling. */
  (* preserve *) reg [1:0] drop_ps_lat;
  /* DVD-FORK FIX (mpeg1): STATE_PICTURE_CODING_EXT0 never occurs in MPEG-1, so
   * drop_ps_lat would stay stale (typically 0) and the governor could never drop a
   * B-frame. Every MPEG-1 picture is a frame picture: refresh the latch at the
   * picture header instead. Ordering matches the MPEG-2 convention exactly —
   * drop_now_comb samples drop_ps_lat AT the header, i.e. it reads the PREVIOUS
   * picture's structure, which from the second MPEG-1 picture onward is always
   * FRAME_PICTURE (the very first picture after a stream switch is conservatively
   * non-droppable, same one-picture conservatism the field-pair logic accepts).
   * The (* preserve *) hardening is untouched — this only adds a load arm. */
  always @(posedge clk)
    if (~rst) drop_ps_lat <= 2'd0;
    else if (clk_en && (state == STATE_PICTURE_CODING_EXT0)) drop_ps_lat <= getbits[21:20];
    else if (clk_en && mpeg1 && (state == STATE_PICTURE_HEADER)) drop_ps_lat <= FRAME_PICTURE;
    else drop_ps_lat <= drop_ps_lat;
  (* keep *) wire drop_ps_frame = (drop_ps_lat == FRAME_PICTURE);
  /* DVD-FORK (2026-08-05 round 3 — THE ACTUAL Thayer drops=0 truth): the disc is
   * mostly FIELD-CODED MPEG-2 (top/bottom field pictures: the VMGM intro past its
   * head, VTS_02/05/07/11 — while every earlier ES sample happened to hit the
   * frame-coded lead-ins and VTS_09). The row-16 probe proved it on HW: the
   * private drop_ps_lat ALSO read not-frame (ps=0) during play — the value is
   * genuine, not mangled; drops=0 was this design's DOCUMENTED punt on
   * field-picture B's. Extension: drop B FIELD PAIRS atomically.
   *  - Decide at the FIRST field of a B frame. second_field READS 1 at a
   *    first-field header (the seq/gop preset convention — the same read that
   *    fires update_picture_buffers there), so the pair's OWN update pulse is
   *    suppressed by the existing ~drop_now_comb term, exactly like a frame-B.
   *  - drop_pair_arm forces the SIBLING field (next header, second_field reads
   *    0, no update pulse to suppress) to the same fate, keeping the pair
   *    atomic — a half-dropped pair would emit a frame with a stale field.
   *  - Each dropped FIELD acks at cost 1 (a field = 1 refresh at 59.94), so a
   *    pair debits exactly the 2 refreshes it frees (drop_pic_field -> the
   *    mpeg2video cost/credit muxes).
   *  - drop_ps_lat at a first-field header holds the PREVIOUS picture's
   *    structure: correct in steady field-coded regions; at a frame->field
   *    content transition one boundary frame is misjudged conservatively
   *    (treated as frame-coded, its sibling not armed) — a one-frame glitch
   *    per cell transition worst case, accepted. */
  (* keep *) wire drop_ps_field = (drop_ps_lat == 2'd1) || (drop_ps_lat == 2'd2);
  (* preserve *) reg drop_pair_arm;
  assign drop_now_comb = (state == STATE_PICTURE_HEADER) && drop_hdr_is_b &&
                         ( (drop_pic_req &&
                            (drop_ps_frame || (drop_ps_field && second_field)))
                           || drop_pair_arm );
  always @(posedge clk)
    if (~rst) drop_pair_arm <= 1'b0;
    else if (clk_en && (state == STATE_PICTURE_HEADER))
      // armed by a dropped FIRST field (second_field reads 1 there); the
      // sibling's own header re-evaluates this with second_field=0 -> cleared.
      drop_pair_arm <= drop_now_comb && drop_ps_field && second_field;
    else drop_pair_arm <= drop_pair_arm;
  // DVD-FORK DEBUG (2026-08-05): in-vld drop-path probe — see the port comment.
  (* preserve *) reg [3:0] dbg_hdr_cnt;
  (* preserve *) reg [3:0] dbg_dropnow_cnt;
  (* preserve *) reg       dbg_req_in;
  (* preserve *) reg       dbg_b_seen;
  always @(posedge clk)
    if (~rst) begin
      dbg_hdr_cnt <= 4'd0; dbg_dropnow_cnt <= 4'd0;
      dbg_req_in <= 1'b0; dbg_b_seen <= 1'b0;
    end else if (clk_en && (state == STATE_PICTURE_HEADER)) begin
      dbg_hdr_cnt <= dbg_hdr_cnt + 4'd1;
      if (drop_now_comb) dbg_dropnow_cnt <= dbg_dropnow_cnt + 4'd1;
      dbg_req_in <= drop_pic_req;
      dbg_b_seen <= drop_ps_frame || drop_ps_field;   // round 3: droppable structure (frame OR field-pair)
    end
  assign dbg_drop_probe = {dbg_hdr_cnt, dbg_dropnow_cnt, dbg_req_in, dbg_b_seen};
  output wire      top_field_first;
  wire             frame_pred_frame_dct;
  wire             concealment_motion_vectors;
  output wire      q_scale_type;
  wire             intra_vlc_format;
  output wire      alternate_scan;
  output wire      repeat_first_field;
  wire             chroma_420_type;
  output wire      progressive_frame;
  wire             composite_display_flag;
  wire             v_axis;
  wire        [2:0]field_sequence;
  wire             sub_carrier;
  wire        [6:0]burst_amplitude;
  wire        [7:0]sub_carrier_phase;

  /* in group of pictures header */
  wire             drop_flag;
  wire        [4:0]time_code_hours;
  wire        [5:0]time_code_minutes;
  wire        [5:0]time_code_seconds;
  wire        [5:0]time_code_pictures;
  wire             closed_gop;
  wire             broken_link;

  /* in picture header */
  wire        [9:0]temporal_reference;
  output wire [2:0]picture_coding_type;
  wire       [15:0]vbv_delay;
  wire             full_pel_forward_vector;
  wire        [2:0]forward_f_code;
  wire             full_pel_backward_vector;
  wire        [2:0]backward_f_code;

  /* in slice */
  output reg  [4:0]quantiser_scale_code;
  reg              slice_extension_flag;
  reg              intra_slice;
  reg              slice_picture_id_enable;
  reg         [5:0]slice_picture_id;
  reg         [7:0]slice_vertical_position;
  reg              first_macroblock_of_slice;

  /* macroblock address increment */
  wire        [3:0]macroblock_addr_inc_length;
  wire        [5:0]macroblock_addr_inc_value;
  wire        [6:0]macroblock_addr_inc_value_ext = macroblock_addr_inc_value;
  wire             macroblock_addr_inc_escape;
  /* DVD-FORK FIX (mpeg1): macroblock_stuffing ('0000 0001 111', MPEG-1 only) decodes in
   * vlc_tables.v as {length=11, value=0, escape=0} — a combination no real increment
   * produces. Consumed-and-stayed in STATE_NEXT_MACROBLOCK when mpeg1; still the
   * value==0 error in MPEG-2 mode. */
  wire             macroblock_addr_inc_stuffing = (macroblock_addr_inc_length == 4'd11) && (macroblock_addr_inc_value == 6'd0) && ~macroblock_addr_inc_escape;
  reg         [6:0]macroblock_address_increment;
  /* 
   * macroblock address is valid after STATE_MACROBLOCK_TYPE and before STATE_NEXT_BLOCK. 
   * In particular: In the first slice of a picture, macroblock_address may be 0xffff after STATE_SLICE up to STATE_MACROBLOCK_TYPE.
   */
  output reg [12:0]macroblock_address; // High Level: macroblock_address is 13 bits, 0..8159, 8160..8191 unused.
  reg        [10:0]empty_blocks;

  /* macroblock type */
  wire        [3:0]macroblock_type_length;
  wire        [5:0]macroblock_type_value;
  reg              macroblock_quant;
  output reg       macroblock_motion_forward;
  output reg       macroblock_motion_backward;
  reg              macroblock_pattern;
  output reg       macroblock_intra;
  reg              macroblock_type_intra;
  reg              spatial_temporal_weight_code_flag; // ought always to be zero, as we don't do scaleability
  output reg  [1:0]motion_type; // one reg for both frame_motion_type and field_motion_type
  output reg       dct_type; // dct_type == 1 : field dct coded; dct_type == 0 : frame dct coded
  /* derived variables (par. 6.3.17.1, tables 6.17 and 6.18) */
  wire             motion_vector_count_is_one;
  reg         [1:0]mv_format;
  reg              dmv;

  /* motion vectors */
  reg         [2:0]motion_vector;  // current motion vector
  reg         [7:0]motion_vector_reg;  // bitmask of motion vectors present
  reg         [3:0]r_size; // f_code_xx  - 4'd1;
  wire             vertical_field_select_present;
  reg         [4:0]motion_code;
  reg              motion_code_neg;
  reg         [7:0]motion_code_residual; // motion_code_residual has up to r_size = f_code_xx - 1 bits. (par. 6.3.17.3) with f_code = 1..9 (Table E-8, high level)
  reg signed  [1:0]dmvector;

  /*
   * par. 7.6.3.1, if f_code_xx = 15 the pmv range low..high would need 21 bits.
   * But restricting ourselves to high level@high profile allows us to pack
   * the motion vectors tighter.
   * Table E-8: for High Level f_code_0_0, f_code_1_0: 1..9
   *                           f_code_0_1, f_code_1_1: 1..5
   *
   * Hence all f_code values are in the range 1..9.
   * This implies the motion vectors are in the range -4096..4095. (par. 7.6.3.1)
   * This means we can represent all motion vectors with 13 bits.
   *
   */ 
  output reg signed [12:0]pmv_0_0_0;
  output reg signed [12:0]pmv_0_0_1;
  output reg signed [12:0]pmv_1_0_0;
  output reg signed [12:0]pmv_1_0_1;
  output reg signed [12:0]pmv_0_1_0;
  output reg signed [12:0]pmv_0_1_1;
  output reg signed [12:0]pmv_1_1_0;
  output reg signed [12:0]pmv_1_1_1;
  output reg signed [12:0]dmv_0_0; // dual-prime motion vectors
  output reg signed [12:0]dmv_1_0;
  output reg signed [12:0]dmv_0_1;                                                              
  output reg signed [12:0]dmv_1_1;                                                              

  /* motion vector pipeline, stage 1 */
  reg         [2:0]motion_vector_0;
  reg              motion_vector_valid_0;
  reg              motion_code_neg_0;
  reg         [3:0]r_size_0;
  reg signed  [1:0]dmvector_0;
  reg signed [12:0]pmv_0;         
  reg signed [12:0]pmv_delta_0;         

  /* motion vector pipeline, stage 2 */
  reg         [2:0]motion_vector_1;
  reg              motion_vector_valid_1;
  reg         [3:0]r_size_1;
  reg signed  [1:0]dmvector_1;
  reg signed [12:0]pmv_1;         

  /* motion vector pipeline, stage 3 */
  reg         [2:0]motion_vector_2;
  reg              motion_vector_valid_2;
  reg signed  [1:0]dmvector_2;
  reg signed [12:0]pmv_2;         

  /* motion vector pipeline, stage 4 */
  reg         [2:0]motion_vector_3;
  reg              motion_vector_valid_3;
  reg signed [12:0]pmv_3;         
  reg signed  [1:0]dmvector_3;

  /* motion vector pipeline, stage 5 */
  reg         [2:0]motion_vector_4;
  reg              motion_vector_valid_4;
  reg signed [12:0]pmv_4;         

  /* motion vector pipeline, stage 6 */
  reg         [2:0]motion_vector_5;
  reg              motion_vector_valid_5;
  reg signed [12:0]pmv_5;         

  /* motion vector pipeline, output */
  output reg       motion_vector_valid; // motion_vector valid is asserted when pmv_x_x_x dmv_x_x valid

  /* coded block pattern */
  reg        [11:0]coded_block_pattern;  // derived from coded_block_pattern_420, coded_block_pattern_1 and coded_block_pattern_2

  /* dct coefficients */
  reg         [3:0]dct_dc_size;          // holds dct_dc_size_luminance or dct_dc_size_chrominance, depending.
  reg        [10:0]dct_dc_pred;          // dct_dc_pred_0, dct_dc_pred_1 or dct_dc_pred_2, depending upon whether it's a Y, Cr or Cb block.

  reg        [10:0]dct_dc_pred_0;        // luminance (Y) dct dc predictor, par. 7.2.1
  reg        [10:0]dct_dc_pred_1;        // first chrominance (Cb) dct dc predictor, par. 7.2.1
  reg        [10:0]dct_dc_pred_2;        // second chrominance (Cr) dct dc predictor, par. 7.2.1

  /*
   * Each bit in block_pattern_code, block_lumi_code, ... corresponds to a block. 
   * The first block corresponds to the leftmost bit (= bit 11) the second block to bit 10, etc.
   *
   * For instance, this is what things look like before the first block of a 4:2:0 macroblock:
   *
   * testbench.mpeg2_decoder.vld     STATE_BLOCK
   * testbench.mpeg2_decoder.vld     coded_block_pattern:  b111111000000
   * testbench.mpeg2_decoder.vld     block_pattern_code:   b111111000000
   * testbench.mpeg2_decoder.vld     block_lumi_code:     b011110
   * testbench.mpeg2_decoder.vld     block_chromi1_code:  b0000010101010
   * testbench.mpeg2_decoder.vld     block_chromi2_code:  b0000001010101
   *
   * 6 blocks, first 4 luminance blocks, then a chromi1 (Cb) block, finally a chromi2 (Cr) block.
   * Each block, block_pattern_code, block_lumi_code, block_chromi1_code and block_chromi2_code shift left one bit:
   *
   * testbench.mpeg2_decoder.vld     STATE_NEXT_BLOCK
   * testbench.mpeg2_decoder.vld     coded_block_pattern:  b111110000000
   * testbench.mpeg2_decoder.vld     block_pattern_code:   b111110000000
   * testbench.mpeg2_decoder.vld     block_lumi_code:     b111100
   * testbench.mpeg2_decoder.vld     block_chromi1_code:  b0000101010100
   * testbench.mpeg2_decoder.vld     block_chromi2_code:  b0000010101010
   * ...
   * testbench.mpeg2_decoder.vld     STATE_NEXT_BLOCK
   * testbench.mpeg2_decoder.vld     coded_block_pattern:  b111100000000
   * testbench.mpeg2_decoder.vld     block_pattern_code:   b111100000000
   * testbench.mpeg2_decoder.vld     block_lumi_code:     b111000
   * testbench.mpeg2_decoder.vld     block_chromi1_code:  b0001010101000
   * testbench.mpeg2_decoder.vld     block_chromi2_code:  b0000101010100
   * ...
   *
   * The loop ends when all bits have been shifted out of block_pattern_code:
   *
   * testbench.mpeg2_decoder.vld     STATE_NEXT_BLOCK
   * testbench.mpeg2_decoder.vld     coded_block_pattern:  b000000000000
   * testbench.mpeg2_decoder.vld     block_pattern_code:   b000000000000
   * testbench.mpeg2_decoder.vld     block_lumi_code:     b000000
   * testbench.mpeg2_decoder.vld     block_chromi1_code:  b0101010000000
   * testbench.mpeg2_decoder.vld     block_chromi2_code:  b1010101000000
   *
   * Note there still remain bits in block_chromi1_code and block_chromi2_code:
   * these would have been used in 4:2:2 and 4:4:4 video.
   *
   */

  reg        [11:0]block_pattern_code;   // block_pattern_code[i] is one if the corresponding block exists in the macroblock.
  reg        [12:7]block_lumi_code;      // block_lumi_code[i] is one if the corresponding block is a luminance block. bits 6:0 are always zero.
  reg        [12:0]block_chromi1_code;   // block_chromi1_code[i] is one if the corresponding block is a Cb chrominance block.
  reg        [12:0]block_chromi2_code;   // block_chromi2_code[i] is one if the corresponding block is a Cr chrominance block.

  wire             dct_coefficient_escape;
  output reg  [5:0]dct_coeff_run;
  output reg signed [11:0]dct_coeff_signed_level;
  output reg       dct_coeff_end;        // asserted after last dct_coeff_run/dct_coeff_signed_level
  reg              dct_coeff_valid;
  reg              dct_error;            // set when error occurs in dct decoding
  reg         [5:0]dct_coeff_run_0;
  reg signed [11:0]dct_coeff_signed_level_0;
  reg              dct_coeff_valid_0;
  reg              dct_coeff_end_0;
  reg              dct_coeff_apply_signbit_0;
  output reg       rld_wr_en;            // asserted when dct_coeff_run, dct_coeff_signed_level, and dct_coeff_end valid, or when quantizer rams need update
  output reg  [1:0]rld_cmd;              // RLD_DCT when dct_coeff_run, dct_coeff_signed_level, and dct_coeff_end valid, RLD_QUANT when quantizer rams need update, RLD_NOOP otherwise

  /* coded block pattern vlc lookup */
  wire        [3:0]coded_block_pattern_length;
  wire        [5:0]coded_block_pattern_value;

  /* motion code vlc lookup */
  wire        [3:0]motion_code_length;
  wire        [4:0]motion_code_value;
  wire             motion_code_sign;

  /* dmvector vlc lookup */
  wire        [1:0]dmvector_length;
  wire             dmvector_value;
  wire             dmvector_sign;

  /* dct dc size luminance vlc lookup */
  wire        [3:0]dct_dc_size_luminance_length;
  wire        [4:0]dct_dc_size_luminance_value;

  /* dct dc size chrominance vlc lookup */
  wire        [3:0]dct_dc_size_chrominance_length;
  wire        [4:0]dct_dc_size_chrominance_value;

  /* dct coefficient 0 vlc lookup */
  reg        [15:0]dct_coefficient_0_decoded;
  reg        [15:0]dct_non_intra_first_coefficient_0_decoded;

  /* dct coefficient 1 vlc lookup */
  reg        [15:0]dct_coefficient_1_decoded;

`include "vlc_tables.v"

  /* DVD-FORK FIX (mpeg1): MPEG-1 DCT escape level extension. In STATE_DCT_ESCAPE_B14
   * (mpeg1 mode) getbits[23:16] holds the FIRST 8-bit level byte: 0x00 or 0x80 mean a
   * second byte follows (level = +b / b-256); anything else is the level itself
   * (signed 8-bit). */
  wire dct_escape_m1_ext = mpeg1 && ((getbits[23:16] == 8'h00) || (getbits[23:16] == 8'h80));

  /* next state logic */
  always @*
    casex (state)
      STATE_NEXT_START_CODE:           if (getbits == 24'h000001) next = STATE_START_CODE;
                                       else next = STATE_NEXT_START_CODE;

      STATE_START_CODE:                casex(getbits[7:0])
                                         /* DVD-FORK FIX (mpeg1): a sequence extension is no longer required — a picture
                                          * start with sequence_header_seen && ~sequence_extension_seen means MPEG-1
                                          * (13818-2 sends the extension immediately after every sequence header, before
                                          * any picture). The mpeg1 flag latches on this very acceptance. */
                                         CODE_PICTURE_START:    if (sequence_header_seen) next = STATE_PICTURE_HEADER;
                                                                else next = STATE_NEXT_START_CODE;
                                         CODE_USER_DATA_START:  next = STATE_NEXT_START_CODE;
					 CODE_SEQUENCE_HEADER:  next = STATE_SEQUENCE_HEADER;
					 CODE_SEQUENCE_ERROR:   next = STATE_NEXT_START_CODE;
					 CODE_EXTENSION_START:  next = STATE_EXTENSION_START_CODE;
					 CODE_SEQUENCE_END:     next = STATE_SEQUENCE_END;
					 CODE_GROUP_START:      next = STATE_GROUP_HEADER;
					 8'h01,
					 8'h02,
					 8'h03,
					 8'h04,
					 8'h05,
					 8'h06,
					 8'h07,
					 8'h08,
					 8'h09,
					 8'h0a,
					 8'h0b,
					 8'h0c,
					 8'h0d,
					 8'h0e,
					 8'h0f,
					 8'h1x,
					 8'h2x,
					 8'h3x,
					 8'h4x,
					 8'h5x,
					 8'h6x,
					 8'h7x,
					 8'h8x,
					 8'h9x,
					 8'hax:                  if (drop_this_picture || skip_d_picture) next = STATE_NEXT_START_CODE; // DVD-FORK (frame-drop O[19]): skip this B-frame's slices cheaply; DVD-FORK FIX (mpeg1): also skip MPEG-1 D-picture slices (different mb syntax)
					                         else if (sequence_header_seen & (sequence_extension_seen | mpeg1) & picture_header_seen) next = STATE_SLICE; // DVD-FORK FIX (mpeg1): no extension needed in MPEG-1 mode
                                                                 else next = STATE_NEXT_START_CODE;
					 default                 next = STATE_NEXT_START_CODE;
				       endcase 

      STATE_EXTENSION_START_CODE:      casex(getbits[23:20])
                                         EXT_SEQUENCE:                  next = STATE_SEQUENCE_EXT;
                                         EXT_SEQUENCE_DISPLAY:          next = STATE_SEQUENCE_DISPLAY_EXT;
                                         EXT_QUANT_MATRIX:              next = STATE_QUANT_MATRIX_EXT;
                                         EXT_COPYRIGHT:                 next = STATE_NEXT_START_CODE;
                                         EXT_SEQUENCE_SCALABLE:         next = STATE_NEXT_START_CODE;
                                         EXT_PICTURE_DISPLAY:           next = STATE_NEXT_START_CODE; // Pan & scan
                                         EXT_PICTURE_CODING:            next = STATE_PICTURE_CODING_EXT;
                                         EXT_PICTURE_SPATIAL_SCALABLE:  next = STATE_NEXT_START_CODE;
                                         EXT_PICTURE_TEMPORAL_SCALABLE: next = STATE_NEXT_START_CODE;
                                         EXT_CAMERA_PARAMETERS:         next = STATE_NEXT_START_CODE;
                                         EXT_ITU_T:                     next = STATE_NEXT_START_CODE;
                                         default                        next = STATE_NEXT_START_CODE;
                                       endcase

      /* par. 6.2.2.1: sequence header */
      STATE_SEQUENCE_HEADER:           next = STATE_SEQUENCE_HEADER0; 

      STATE_SEQUENCE_HEADER0:          next = STATE_SEQUENCE_HEADER1; 

      STATE_SEQUENCE_HEADER1:          next = STATE_SEQUENCE_HEADER2; 

      STATE_SEQUENCE_HEADER2:          if (getbits[5] || ~STRICT_MARKER_BIT) next = STATE_SEQUENCE_HEADER3; // check marker bit
                                       else next = STATE_SEQUENCE_HEADER3; 

      STATE_SEQUENCE_HEADER3:          if (getbits[12]) next = STATE_LD_INTRA_QUANT0;
                                       else if (getbits[11]) next = STATE_LD_NON_INTRA_QUANT0;
				       else next = STATE_NEXT_START_CODE;

      STATE_LD_INTRA_QUANT0:           if (cnt != 6'b111111) next = STATE_LD_INTRA_QUANT0;
                                       else if (getbits[15]) next = STATE_LD_NON_INTRA_QUANT0;
				       else next = STATE_NEXT_START_CODE;

      STATE_LD_NON_INTRA_QUANT0:       if (cnt != 6'b111111) next = STATE_LD_NON_INTRA_QUANT0;
                                       else next = STATE_NEXT_START_CODE;

      /* par. 6.2.2.3: Sequence extension */ 
      STATE_SEQUENCE_EXT:              next = STATE_SEQUENCE_EXT0;

      STATE_SEQUENCE_EXT0:             if (getbits[11] || ~STRICT_MARKER_BIT) next = STATE_SEQUENCE_EXT1; // check marker bit
                                       else next = STATE_ERROR;

      STATE_SEQUENCE_EXT1:             next = STATE_NEXT_START_CODE;

      /* par. 6.2.2.4: Sequence display extension */
      STATE_SEQUENCE_DISPLAY_EXT:      if (getbits[20]) next = STATE_SEQUENCE_DISPLAY_EXT0;
                                       else next = STATE_SEQUENCE_DISPLAY_EXT1;

      STATE_SEQUENCE_DISPLAY_EXT0:     next = STATE_SEQUENCE_DISPLAY_EXT1;

      STATE_SEQUENCE_DISPLAY_EXT1:     if (getbits[9]) next = STATE_SEQUENCE_DISPLAY_EXT2;
                                       else next = STATE_NEXT_START_CODE;

      STATE_SEQUENCE_DISPLAY_EXT2:     next = STATE_NEXT_START_CODE;

      /* par. 6.2.3.2: Quant matrix  extension */
      STATE_QUANT_MATRIX_EXT:          if (getbits[23]) next = STATE_LD_INTRA_QUANT1;
                                       else if (getbits[22]) next = STATE_LD_NON_INTRA_QUANT1;
                                       else if (getbits[21]) next = STATE_LD_CHROMA_INTRA_QUANT1;
                                       else if (getbits[20]) next = STATE_LD_CHROMA_NON_INTRA_QUANT1;
                                       else next = STATE_NEXT_START_CODE;

      STATE_LD_INTRA_QUANT1:           if (cnt != 6'b111111) next = STATE_LD_INTRA_QUANT1;
                                       else if (getbits[14]) next = STATE_LD_NON_INTRA_QUANT1;
                                       else if (getbits[13]) next = STATE_LD_CHROMA_INTRA_QUANT1;
                                       else if (getbits[12]) next = STATE_LD_CHROMA_NON_INTRA_QUANT1;
                                       else next = STATE_NEXT_START_CODE;

      STATE_LD_NON_INTRA_QUANT1:       if (cnt != 6'b111111) next = STATE_LD_NON_INTRA_QUANT1;
                                       else if (getbits[13]) next = STATE_LD_CHROMA_INTRA_QUANT1;
                                       else if (getbits[12]) next = STATE_LD_CHROMA_NON_INTRA_QUANT1;
                                       else next = STATE_NEXT_START_CODE;

      STATE_LD_CHROMA_INTRA_QUANT1:    if (cnt != 6'b111111) next = STATE_LD_CHROMA_INTRA_QUANT1;
                                       else if (getbits[12]) next = STATE_LD_CHROMA_NON_INTRA_QUANT1;
                                       else next = STATE_NEXT_START_CODE;

      STATE_LD_CHROMA_NON_INTRA_QUANT1: if (cnt != 6'b111111) next = STATE_LD_CHROMA_NON_INTRA_QUANT1;
                                       else next = STATE_NEXT_START_CODE;

      /* par. 6.2.3.1: Picture coding extension */
      STATE_PICTURE_CODING_EXT:        next = STATE_PICTURE_CODING_EXT0;

      STATE_PICTURE_CODING_EXT0:       if (getbits[10]) next = STATE_PICTURE_CODING_EXT1;
                                       else next = STATE_NEXT_START_CODE;

      STATE_PICTURE_CODING_EXT1:       next = STATE_NEXT_START_CODE;

      /* par. 6.2.2.6: group of pictures header */
      STATE_GROUP_HEADER:              next = STATE_GROUP_HEADER0;

      STATE_GROUP_HEADER0:             next = STATE_NEXT_START_CODE;

      /* par. 6.2.3: picture header */
      STATE_PICTURE_HEADER:            next = STATE_PICTURE_HEADER0;

      STATE_PICTURE_HEADER0:           if ((picture_coding_type == 3'h2) || (picture_coding_type == 3'h3)) next = STATE_PICTURE_HEADER1;
                                       else next = STATE_NEXT_START_CODE;

      STATE_PICTURE_HEADER1:           if (picture_coding_type == 3'h3) next = STATE_PICTURE_HEADER2;
                                       else next = STATE_NEXT_START_CODE;

      STATE_PICTURE_HEADER2:           next = STATE_NEXT_START_CODE;

      /* par. 6.2.4: slice */
      STATE_SLICE:                     if (getbits[18]) next = STATE_SLICE_EXTENSION; // getbits[18] is slice_extension_flag
                                       else next = STATE_NEXT_MACROBLOCK;

      STATE_SLICE_EXTENSION:           if (getbits[15]) next = STATE_SLICE_EXTRA_INFORMATION; // getbits[15] is extra_bit_slice
                                       else next = STATE_NEXT_MACROBLOCK;

      STATE_SLICE_EXTRA_INFORMATION:   if (getbits[15]) next = STATE_SLICE_EXTRA_INFORMATION; // getbits[15] indicates another extra_information_slice byte follows
                                       else next = STATE_NEXT_MACROBLOCK;

      STATE_NEXT_MACROBLOCK:           if (macroblock_addr_inc_escape) next = STATE_NEXT_MACROBLOCK; // macroblock address escape
                                       else if (mpeg1 && macroblock_addr_inc_stuffing) next = STATE_NEXT_MACROBLOCK; // DVD-FORK FIX (mpeg1): macroblock_stuffing — consume 11 bits (value 0 adds nothing), stay
                                       else if (macroblock_addr_inc_value == 6'd0) next = STATE_ERROR;
				       else if (first_macroblock_of_slice) next = STATE_MACROBLOCK_TYPE; // par. 6.3.16.1: syntax does not allow the first and last macroblock of a slice to be skipped
				       else if ((macroblock_address_increment + macroblock_addr_inc_value_ext) != 7'd1) next = STATE_MACROBLOCK_SKIP; // macroblocks skipped. macroblock_address_increment + macroblock_addr_inc_value_ext is next value of macroblock_address_increment.
                                       else next = STATE_MACROBLOCK_TYPE;

      STATE_MACROBLOCK_SKIP:           if (macroblock_address_increment == 7'd1) next = STATE_MACROBLOCK_TYPE;
                                       else next = STATE_DELAY_EMPTY_BLOCK;

      STATE_DELAY_EMPTY_BLOCK:         next = STATE_EMIT_EMPTY_BLOCK; // to avoid motion vector and dct_coeff valid at same moment

      STATE_EMIT_EMPTY_BLOCK:          if ((empty_blocks[10] == 1'b0) && (macroblock_address_increment == 7'd1)) next = STATE_MACROBLOCK_TYPE;  
                                       else if (empty_blocks[10] == 1'b0) next = STATE_MACROBLOCK_SKIP;  // STATE_EMIT_EMPTY_BLOCK emits a block of 8x8 zeroes. par. 7.7.2.
                                       else next = STATE_EMIT_EMPTY_BLOCK;

      STATE_MACROBLOCK_TYPE:           /* This is what the following lines should look like, only the variables haven't been clocked in yet,
                                        * so we address macroblock_type_value directly.
                                        * if ((macroblock_type_length == 4'b0) || (spatial_temporal_weight_code_flag)) next = STATE_ERROR; // we don't do scaleability
                                        * else next = STATE_MOTION_TYPE; // frame or field motion_type
                                        */

                                       // macroblock_type_length == 0 if macroblock_type code lookup fails.
                                       // macroblock_type_value[0] indicates scaleability; we don't do scaleability.
                                       if ((macroblock_type_length == 4'b0) || macroblock_type_value[0]) next = STATE_ERROR; // we don't do scaleability
                                       else next = STATE_MOTION_TYPE; // frame or field motion_type

      STATE_MOTION_TYPE:               if ((picture_structure == FRAME_PICTURE) && (frame_pred_frame_dct == 1'b0) && (macroblock_intra || macroblock_pattern)) next = STATE_DCT_TYPE;
                                       else next = STATE_MACROBLOCK_QUANT;

      STATE_DCT_TYPE:                  next = STATE_MACROBLOCK_QUANT;

      STATE_MACROBLOCK_QUANT:          next = STATE_NEXT_MOTION_VECTOR;

      /* motion_vectors */
      STATE_NEXT_MOTION_VECTOR:        if (motion_vector_reg == 8'b0) next = STATE_MOTION_PIPELINE_FLUSH;
                                       // motion_vector_reg[7] indicates whether the current motion_vector is present
                                       else if (motion_vector_reg[7] && vertical_field_select_present) next = STATE_MOTION_VERT_FLD_SEL; 
                                       else if (motion_vector_reg[7]) next = STATE_MOTION_CODE;
                                       else next = STATE_NEXT_MOTION_VECTOR; // increment motion_vector; shift motion_vector_reg one bit to the left
				       
      STATE_MOTION_PIPELINE_FLUSH:     if (motion_vector_valid_0 || motion_vector_valid_1 || motion_vector_valid_2 || motion_vector_valid_3 || motion_vector_valid_4 || motion_vector_valid_5) next = STATE_MOTION_PIPELINE_FLUSH; // wait for motion vector pipeline to flush.	  
				       else // no more motion vectors present, motion vector pipeline empty.
                                         begin
                                           if (macroblock_intra && concealment_motion_vectors) next = STATE_MARKER_BIT_0;
                                           else if (macroblock_pattern) next = STATE_CODED_BLOCK_PATTERN;
                                           else next = STATE_BLOCK;
					 end

      STATE_MOTION_VERT_FLD_SEL:       next = STATE_MOTION_CODE; // motion_vectors(0), motion_vertical_field_select(0,0)

      STATE_MOTION_CODE:               // motion_vectors(0), motion_vector(0,0), motion_code(0,0,0) 
                                       if (motion_code_length == 4'b0) next = STATE_ERROR;
                                       else if ((r_size != 4'd0) && (getbits[23] != 1'b1)) next = STATE_MOTION_RESIDUAL; // (r_size != 4'd0) is equivalent to (f_code_xx != 4'd1)
                                       else if (dmv) next = STATE_MOTION_DMVECTOR;
                                       else next = STATE_MOTION_PREDICT;

      STATE_MOTION_RESIDUAL:           // motion_vectors(0), motion_vector(0,0), motion_residual(0,0,0)
                                       if (dmv) next = STATE_MOTION_DMVECTOR;
                                       else next = STATE_MOTION_PREDICT;

      STATE_MOTION_DMVECTOR:           // motion_vectors(0), motion_vector(0,0), dmvector(0)
                                       if (dmvector_length  == 2'b0) next = STATE_ERROR;
                                       else next = STATE_MOTION_PREDICT;

      STATE_MOTION_PREDICT:            next = STATE_NEXT_MOTION_VECTOR; // increment motion_vector; shift motion_vector_reg one bit to the left

      /* coded block pattern */
      STATE_MARKER_BIT_0:              // skip marker bit
                                       if (~getbits[23] && STRICT_MARKER_BIT) next = STATE_ERROR;
                                       else if (macroblock_pattern) next = STATE_CODED_BLOCK_PATTERN;
                                       else next = STATE_BLOCK;

      STATE_CODED_BLOCK_PATTERN:       if (coded_block_pattern_length == 4'b0) next = STATE_ERROR; // Invalid coded_block_pattern code
                                       else if (chroma_format == CHROMA422) next = STATE_CODED_BLOCK_PATTERN_1;
                                       else if (chroma_format == CHROMA444) next = STATE_CODED_BLOCK_PATTERN_2;
                                       else next = STATE_BLOCK;

      STATE_CODED_BLOCK_PATTERN_1:     next = STATE_BLOCK;

      STATE_CODED_BLOCK_PATTERN_2:     next = STATE_BLOCK;

      /* DCT coefficients */
      STATE_BLOCK:                     next = STATE_NEXT_BLOCK; // initialize coded_block_pattern, block_pattern_code,  block_lumi_code, block_chromi1_code, block_chromi2_code

      STATE_NEXT_BLOCK:                if (coded_block_pattern[11] && macroblock_intra && block_lumi_code[11]) next = STATE_DCT_DC_LUMI_SIZE; // luminance block
                                       else if (coded_block_pattern[11] && macroblock_intra) next = STATE_DCT_DC_CHROMI_SIZE; // chrominance block
                                       else if (coded_block_pattern[11]) next = STATE_DCT_NON_INTRA_FIRST;
                                       else if (block_pattern_code[11]) next = STATE_NON_CODED_BLOCK;
                                       else if (block_pattern_code != 12'b0) next = STATE_NEXT_BLOCK; // shift block_pattern_code and block_lumi_code one bit, find next block
                                       else if ((getbits[23:1] == 23'b0) || dct_error) next = STATE_NEXT_START_CODE; // end of slice, go to next start code (par. 6.2.4). In case of error, synchronize at next start code.
				       else next = STATE_NEXT_MACROBLOCK; // end of macroblock, but not end of slice: go to next macroblock. 

      STATE_DCT_DC_LUMI_SIZE:          if (dct_dc_size_luminance_length == 4'b0) next = STATE_DCT_ERROR;
                                       else next = STATE_DCT_DC_DIFF; // table B-12 lookup of first luminance dct coefficient

      STATE_DCT_DC_CHROMI_SIZE:        if (dct_dc_size_chrominance_length == 4'b0) next = STATE_DCT_ERROR;
                                       else next = STATE_DCT_DC_DIFF; // table B-13 lookup of first chrominance dct coefficient

      STATE_DCT_DC_DIFF:               next = STATE_DCT_DC_DIFF_0;

      STATE_DCT_DC_DIFF_0:             if (intra_vlc_format) next = STATE_DCT_SUBS_B15; // see table 7-3. look up subsequent dct coefficient of intra block in table B-15
                                       else next = STATE_DCT_SUBS_B14; // see table 7-3. look up subsequent dct coefficient of intra block in table B-14

      STATE_DCT_SUBS_B15:              // subsequent dct coefficients of intra block, as in table B-15
                                       if (getbits[23:20] == 4'b0110) next = STATE_NEXT_BLOCK; // end of this block, go to next block
                                       else if (dct_coefficient_escape) next = STATE_DCT_ESCAPE_B15; // Escape
                                       else if (dct_coefficient_1_decoded[15:11] == 5'b0) next = STATE_DCT_ERROR; // unknown code
                                       else next = STATE_DCT_SUBS_B15;

      STATE_DCT_ESCAPE_B15:            // table B-16 escapes to table B-15
                                       next = STATE_DCT_SUBS_B15;

      STATE_DCT_NON_INTRA_FIRST:       // first dct coefficient of non-intra block, as in table B-14, note 2 and 3
                                       if (dct_coefficient_escape) next = STATE_DCT_ESCAPE_B14; // table B-14 escape
                                       else if (dct_non_intra_first_coefficient_0_decoded[15:11] == 5'b0) next = STATE_DCT_ERROR; // unknown code
                                       else  next = STATE_DCT_SUBS_B14;

      STATE_DCT_SUBS_B14:              // table B-14 (with B-16 escapes) lookup of subsequent dct coefficients.
                                       if (getbits[23:22] == 2'b10) next = STATE_NEXT_BLOCK; // end of this block, go to next block
                                       else if (dct_coefficient_escape) next = STATE_DCT_ESCAPE_B14; // Escape
                                       else if (dct_coefficient_0_decoded[15:11] == 5'b0) next = STATE_DCT_ERROR; // unknown code
                                       else next = STATE_DCT_SUBS_B14;

      STATE_DCT_ESCAPE_B14:            // table B-16 escapes to table B-14 (MPEG-2: fixed 12-bit level)
                                       // DVD-FORK FIX (mpeg1): MPEG-1 escape level is 8 bits; first byte
                                       // 0x00/0x80 announces a second (double-byte) level byte.
                                       if (dct_escape_m1_ext) next = STATE_DCT_ESCAPE_M1;
                                       else next = STATE_DCT_SUBS_B14;

      STATE_DCT_ESCAPE_M1:             // DVD-FORK FIX (mpeg1): second escape-level byte (128..255 / -255..-128)
                                       next = STATE_DCT_SUBS_B14;

      STATE_NON_CODED_BLOCK:           next = STATE_NEXT_BLOCK; // Output end-of-block for all-zeroes non-coded block

      STATE_DCT_ERROR:                 next = STATE_NON_CODED_BLOCK; // Output all remaining blocks as non-coded blocks. clears coded_block_pattern and sets dct_error and vld_err flags.

      STATE_SEQUENCE_END:              next = STATE_NEXT_START_CODE; // Output last frame 

      STATE_ERROR:                     next = STATE_NEXT_START_CODE;

      default                          next = STATE_ERROR;

    endcase
 
  /* ------------------------------------------------------------------------
   * DVD-FORK (line-21 closed captions): user_data byte snoop -> EIA-608 pairs
   * ------------------------------------------------------------------------
   * Format (verified against real discs by tools/cc_scan.py, which checks every
   * filler bit and the 608 odd parity of every data byte -- see
   * docs/closed_captions.md §1):
   *
   *   00 00 01 B2  43 43 01 F8  <flags>  { <marker> <b1> <b2> } x 2*cc_count
   *      flags: bit7 odd_field_first | bit6 filler | bit5:1 cc_count | bit0 extra_field
   *      marker: bits 7:1 = 0x7F filler, bit 0 = 1 -> field 1 (CC1/CC2)
   *
   * WHY HERE AND NOT IN ps_demux: ps_demux sits IN FRONT of the VBUF, which runs
   * up to ~1 s ahead of the screen, so a demux-side sniff is the stale-display-
   * flags bug (drift saga rounds 11-12) wearing a new hat. The vld sits BEHIND
   * the VBUF -- the same reason flags_commit had to move here. Captions then
   * arrive at most a reorder depth ahead of display and are paced out one pair
   * per displayed FIELD downstream (dvd/cc_line21.sv), which is exactly how the
   * encoder framed them: cc_count counts DISPLAY frames, not coded pictures.
   *
   * ud_active is armed by the user_data start code and disarmed the moment the
   * FSM leaves the byte walk, so a non-caption user_data block (CLUE carries
   * ~1100 of them) simply fails the signature match and is ignored. */
  reg        ud_active;                           // inside a user_data byte walk
  reg  [1:0] ud_hit;                              // 0=matching sig, 1=flags, 2=groups, 3=done
  reg  [3:0] ud_sig;                              // signature match progress / group phase
  reg  [5:0] ud_left;                             // caption_field_blocks remaining (2*cc_count)
  reg  [7:0] ud_b1;                               // first caption byte, held for the pair
  reg        ud_fld;                              // marker's field bit

  wire       ud_walk  = (state == STATE_NEXT_START_CODE) && (getbits != 24'h000001);
  wire [7:0] ud_byte  = getbits[23:16];

  always @(posedge clk)
    if (~rst) begin
      ud_active     <= 1'b0;
      ud_hit        <= 2'd0;
      ud_sig        <= 4'd0;
      ud_left       <= 6'd0;
      ud_b1         <= 8'd0;
      ud_fld        <= 1'b0;
      cc_pair_valid <= 1'b0;
      cc_pair       <= 16'd0;
      cc_pair_field <= 1'b0;
    end else if (clk_en) begin
      cc_pair_valid <= 1'b0;                      // default: single-cycle pulse
      if (state == STATE_START_CODE) begin
        // arm on 00 00 01 B2; any other start code disarms
        ud_active <= (getbits[7:0] == CODE_USER_DATA_START);
        ud_hit    <= 2'd0;
        ud_sig    <= 4'd0;
      end else if (ud_active && ud_walk) begin
        case (ud_hit)
          2'd0: begin                             // "CC" 0x01 0xF8
            case (ud_sig)
              4'd0: if (ud_byte == 8'h43) ud_sig <= 4'd1; else ud_active <= 1'b0;
              4'd1: if (ud_byte == 8'h43) ud_sig <= 4'd2; else ud_active <= 1'b0;
              4'd2: if (ud_byte == 8'h01) ud_sig <= 4'd3; else ud_active <= 1'b0;
              4'd3: if (ud_byte == 8'hf8) begin ud_hit <= 2'd1; ud_sig <= 4'd0; end
                    else ud_active <= 1'b0;
              default: ud_active <= 1'b0;
            endcase
          end
          2'd1: begin                             // flags byte -> 2*cc_count groups
            ud_left <= {ud_byte[5:1], 1'b0};      // 2 * cc_count, saturating at 62
            ud_hit  <= (ud_byte[5:1] == 5'd0) ? 2'd3 : 2'd2;
            ud_sig  <= 4'd0;
          end
          2'd2: begin                             // { marker, b1, b2 } groups
            case (ud_sig)
              4'd0: begin
                // marker filler must be 0x7F; anything else means we have lost
                // sync inside the block -- stop rather than emit garbage.
                if (ud_byte[7:1] == 7'h7f) begin
                  ud_fld <= ud_byte[0];
                  ud_sig <= 4'd1;
                end else begin
                  ud_active <= 1'b0;
                end
              end
              4'd1: begin ud_b1 <= ud_byte; ud_sig <= 4'd2; end
              default: begin
                cc_pair       <= {ud_b1, ud_byte};
                cc_pair_field <= ud_fld;
                cc_pair_valid <= 1'b1;
                ud_sig        <= 4'd0;
                ud_left       <= ud_left - 6'd1;
                if (ud_left == 6'd1) ud_hit <= 2'd3;
              end
            endcase
          end
          default: ud_active <= 1'b0;             // block consumed; ignore the tail
        endcase
      end else if (state != STATE_NEXT_START_CODE) begin
        ud_active <= 1'b0;                        // left the byte walk
      end
    end else begin
      cc_pair_valid <= 1'b0;
    end

  /* advance and align logic. advance is number of bits to advance the bitstream. */
  always @*
    if (~rst) next_advance = 5'b0;
    else
      case (state)
        STATE_NEXT_START_CODE:            next_advance = 5'd0;             // next_advance is zero in STATE_INIT; but align = 1: we move one byte at a time.
	STATE_START_CODE:                 next_advance = 5'd24;            // skip over the 24'h0001sc, where sc = start_code
	STATE_EXTENSION_START_CODE:       next_advance = 5'd4;             // skip over the extension start code
	/* par. 6.2.2.1: sequence header */
	STATE_SEQUENCE_HEADER:            next_advance = 5'd12;            // size of horizontal_size_value
	STATE_SEQUENCE_HEADER0:           next_advance = 5'd12;            // size of vertical_size_value
	STATE_SEQUENCE_HEADER1:           next_advance = 5'd8;             // size of aspect_ratio_information and frame_rate_code
	STATE_SEQUENCE_HEADER2:           next_advance = 5'd19;            // size of bit_rate_value and marker bit
	STATE_SEQUENCE_HEADER3:           next_advance = 5'd12;            // size of vbv_buffer_size[9:0], constrained_parameters_flag and load_intra_quantiser_matrix
	STATE_LD_INTRA_QUANT0:            next_advance = 5'd8;             // size of one item of quantization table
	STATE_LD_NON_INTRA_QUANT0:        next_advance = 5'd8;             // size of one item of quantization table
	/* par. 6.2.2.3: Sequence extension */
	STATE_SEQUENCE_EXT:               next_advance = 5'd15;            // size of profile_and_level_indication, progressive_sequence, chroma_format, horizontal_size ext, vertical_size ext.
	STATE_SEQUENCE_EXT0:              next_advance = 5'd13;            // size of bit_rate ext, marker bit.
	STATE_SEQUENCE_EXT1:              next_advance = 5'd16;            // size of vbv_buffer_size ext, low_delay, frame_rate_extension_n, frame_rate_extension_d
	/* par. 6.2.2.4: Sequence display extension */
	STATE_SEQUENCE_DISPLAY_EXT:       next_advance = 5'd4;             // size of video_format, colour_description
	STATE_SEQUENCE_DISPLAY_EXT0:      next_advance = 5'd24;            // size of colour_primaries, transfer_characteristics, matrix_coefficients
	STATE_SEQUENCE_DISPLAY_EXT1:      next_advance = 5'd15;            // size of display_horizontal_size, marker bit
	STATE_SEQUENCE_DISPLAY_EXT2:      next_advance = 5'd14;            // size of display_vertical_size
	/* par. 6.2.3.2: Quant matrix  extension */
	STATE_QUANT_MATRIX_EXT:           next_advance = 5'd0;             // no move
	STATE_LD_INTRA_QUANT1:            next_advance = 5'd8;             // size of one item of quantization table
	STATE_LD_NON_INTRA_QUANT1:        next_advance = 5'd8;             // size of one item of quantization table
	STATE_LD_CHROMA_INTRA_QUANT1:     next_advance = 5'd8;             // size of one item of quantization table
	STATE_LD_CHROMA_NON_INTRA_QUANT1: next_advance = 5'd8;             // size of one item of quantization table
	/* par. 6.2.3.1: Picture coding extension */
	STATE_PICTURE_CODING_EXT:         next_advance = 5'd16;            // size of f_code_00, f_code_01, f_code_10, f_code_11
	STATE_PICTURE_CODING_EXT0:        next_advance = 5'd14;            // size of intra_dc_precision .. composite_display_flag
	STATE_PICTURE_CODING_EXT1:        next_advance = 5'd20;            // size of v_axis, field_sequence, sub_carrier, burst_amplitude, sub_carrier_phase
	/* par. 6.2.2.6: group of pictures header */
	STATE_GROUP_HEADER:               next_advance = 5'd19;
	STATE_GROUP_HEADER0:              next_advance = 5'd8;
	/* par. 6.2.3: picture header */
	STATE_PICTURE_HEADER:             next_advance = 5'd13;            // size of temporal_reference, picture_coding_type
	STATE_PICTURE_HEADER0:            next_advance = 5'd16;            // size of vbv_delay
	STATE_PICTURE_HEADER1:            next_advance = 5'd4;             // size of full_pel_forward_vector, forward_f_code
	STATE_PICTURE_HEADER2:            next_advance = 5'd4;             // size of full_pel_backward_vector, backward_f_code

        /* par. 6.2.4: slice */
        STATE_SLICE:                      next_advance = 5'd6;
        STATE_SLICE_EXTENSION:            next_advance = 5'd9;
        STATE_SLICE_EXTRA_INFORMATION:    next_advance = 5'd9;
        STATE_NEXT_MACROBLOCK:            next_advance = macroblock_addr_inc_length;
        STATE_MACROBLOCK_SKIP:            next_advance = 5'd0;
        STATE_MACROBLOCK_TYPE:            next_advance = macroblock_type_length;
        STATE_MOTION_TYPE:                next_advance = (macroblock_motion_forward || macroblock_motion_backward) ? 
	                                                  (((picture_structure == FRAME_PICTURE) && (frame_pred_frame_dct == 1'b1)) ? 5'd0 : 5'd2)  
							  : 5'd0;
        STATE_DCT_TYPE:                   next_advance = 5'd1;
        STATE_MACROBLOCK_QUANT:           next_advance = macroblock_quant ? 5'd5 : 5'd0;

        STATE_NEXT_MOTION_VECTOR:         next_advance = 5'd0;
        STATE_MOTION_VERT_FLD_SEL:        next_advance = 5'd1;                         // motion_vertical_field_select
        STATE_MOTION_CODE:                next_advance = motion_code_length;           // motion_code
        STATE_MOTION_RESIDUAL:            next_advance = r_size;                       // motion_residual
        STATE_MOTION_DMVECTOR:            next_advance = dmvector_length;              // dmvector
        STATE_MOTION_PREDICT:             next_advance = 5'd0;
        STATE_MOTION_PIPELINE_FLUSH:      next_advance = 5'd0;

        STATE_MARKER_BIT_0:               next_advance = 5'd1;
        STATE_CODED_BLOCK_PATTERN:        next_advance = coded_block_pattern_length;
        STATE_CODED_BLOCK_PATTERN_1:      next_advance = 5'd2;
        STATE_CODED_BLOCK_PATTERN_2:      next_advance = 5'd6;
        STATE_BLOCK:                      next_advance = 5'd0;
        STATE_NEXT_BLOCK:                 next_advance = 5'd0;
        STATE_DCT_DC_LUMI_SIZE:           next_advance = dct_dc_size_luminance_length;
        STATE_DCT_DC_CHROMI_SIZE:         next_advance = dct_dc_size_chrominance_length;
        STATE_DCT_DC_DIFF:                next_advance = dct_dc_size;

        STATE_DCT_SUBS_B15:               next_advance = dct_coefficient_escape ? 5'd12 : dct_coefficient_1_decoded[15:11]; // escape + fixed-length run encoding as in table B-16 or variable length encoding as in table B-15
        STATE_DCT_ESCAPE_B15:             next_advance = 5'd12; // 12-bit fixed-length signed_level (table B-16)
        STATE_DCT_SUBS_B14:               next_advance = dct_coefficient_escape ? 5'd12 : dct_coefficient_0_decoded[15:11]; // escape + fixed-length run encoding as in table B-16 or variable length encoding as in table B-14
        STATE_DCT_ESCAPE_B14      :       next_advance = mpeg1 ? 5'd8 : 5'd12; // 12-bit fixed-length signed_level (table B-16); DVD-FORK FIX (mpeg1): 8-bit first level byte
        STATE_DCT_ESCAPE_M1:              next_advance = 5'd8;  // DVD-FORK FIX (mpeg1): second level byte
        STATE_DCT_NON_INTRA_FIRST:        next_advance = dct_coefficient_escape ? 5'd12 : dct_non_intra_first_coefficient_0_decoded[15:11]; // escape + fixed-length run encoding as in table B-16 or variable length encoding as in table B-14, modified as in table b-14 note 2, 3
        STATE_NON_CODED_BLOCK:            next_advance = 5'd0;
        STATE_DCT_ERROR:                  next_advance = 5'd0;

        STATE_SEQUENCE_END:               next_advance = 5'd0;
        STATE_ERROR:                      next_advance = 5'd0;

	/* default value */
	default                           next_advance = 5'd0;
      endcase


  /*
   * Note: align and advance are zero when clk_en is false; 
   * this avoids the fifo moving forward while the vld is not enabled.
   */

  wire next_align = (state == STATE_NEXT_START_CODE);

  always @(posedge clk)
    if (~rst) align <= 1'b0;
    else if (clk_en) align <= next_align;
    else align <= 1'b0;

  always @(posedge clk)
    if (~rst) advance <= 1'b0;
    else if (clk_en) advance <= next_advance;
    else advance <= 1'b0;

  /*
   * wait_state is asserted if align or advance will be non-zero during the next clock cycle, 
   * and getbits will need to do some work. 
   * Unregistered output; the registering happens in getbits.
   */
  output wait_state;
  assign wait_state = ((next_align != 1'b0) || (next_advance != 4'b0));

  /* state */
  
  always @(posedge clk)
    if(~rst) state <= STATE_NEXT_START_CODE;
    else if (clk_en) state <= next;
    else state <= state;

  always @(posedge clk)
    if (~rst) dct_error <= 1'b0;
    else if (clk_en && (state == STATE_NEXT_START_CODE)) dct_error <= 1'b0;
    else if (clk_en && (state == STATE_DCT_ERROR)) dct_error <= 1'b1;
    else dct_error <= dct_error;

  always @(posedge clk)
    if (~rst) vld_err <= 1'b0;
    else if (clk_en && (state == STATE_NEXT_START_CODE)) vld_err <= 1'b0;
    else if (clk_en && ((state == STATE_ERROR) || (state == STATE_DCT_ERROR))) vld_err <= 1'b1;
    else vld_err <= vld_err;

  /* position in video stream */

  always @(posedge clk)
    if (~rst) sequence_header_seen <= 1'b0;
    else if (clk_en && (state == STATE_SEQUENCE_HEADER)) sequence_header_seen <= 1'b1;
    else if (clk_en && (state == STATE_SEQUENCE_END)) sequence_header_seen <= 1'b0;
    else sequence_header_seen <= sequence_header_seen;

  always @(posedge clk)
    if (~rst) sequence_extension_seen <= 1'b0;
    /* DVD-FORK FIX (mpeg1): re-arm at every sequence header. 13818-2 requires each
     * sequence_header to be immediately followed by its sequence_extension (before
     * any picture), so this clear is invisible to legal MPEG-2 streams — and it makes
     * the MPEG-1 verdict robust across an MPEG-2 -> MPEG-1 splice with no intervening
     * sequence_end (the old clear-at-SEQUENCE_END-only left the flag stale). */
    else if (clk_en && (state == STATE_SEQUENCE_HEADER)) sequence_extension_seen <= 1'b0;
    else if (clk_en && (state == STATE_SEQUENCE_EXT)) sequence_extension_seen <= 1'b1;
    else if (clk_en && (state == STATE_SEQUENCE_END)) sequence_extension_seen <= 1'b0;
    else sequence_extension_seen <= sequence_extension_seen;

  /* DVD-FORK FIX (mpeg1): MPEG-1/MPEG-2 stream discrimination.
   * MPEG-1 (11172-2) has no extensions at all, while 13818-2 sends sequence_extension
   * immediately after EVERY sequence header, before any picture. So: a picture start
   * code accepted while sequence_header_seen && ~sequence_extension_seen == the stream
   * is MPEG-1. The flag is (re)latched at every accepted picture start (self-heals one
   * picture after a corrupt/missing extension) and cleared the moment any sequence
   * extension parses (instant MPEG-2 confirmation). Combined with the re-arm above,
   * MPEG-1<->MPEG-2 splices re-detect at the first picture of the new sequence. */
  always @(posedge clk)
    if (~rst) mpeg1 <= 1'b0;
    else if (clk_en && (state == STATE_SEQUENCE_EXT)) mpeg1 <= 1'b0;
    else if (clk_en && (state == STATE_START_CODE) && (getbits[7:0] == CODE_PICTURE_START) && sequence_header_seen) mpeg1 <= ~sequence_extension_seen;
    else mpeg1 <= mpeg1;

  /* DVD-FORK FIX (mpeg1): D-pictures (picture_coding_type == 4; MPEG-1 only, illegal
   * on DVD/VCD) use a different macroblock syntax (end_of_macroblock bit, no EOB) that
   * the I/P/B slice FSM would mis-decode into STATE_ERROR spam. Guard: route a
   * D-picture's slice start codes to STATE_NEXT_START_CODE — the same pattern
   * drop_this_picture uses — and suppress its update_picture_buffers (hdr_is_d_m1
   * below), so the previous frame simply repeats. picture_coding_type is valid here:
   * its loadreg latches at STATE_PICTURE_HEADER. Self-clears at the next picture. */
  always @(posedge clk)
    if (~rst) skip_d_picture <= 1'b0;
    else if (clk_en && (state == STATE_PICTURE_HEADER0)) skip_d_picture <= mpeg1 && (picture_coding_type == D_TYPE);
    else skip_d_picture <= skip_d_picture;

  always @(posedge clk)
    if (~rst) picture_header_seen <= 1'b0;
    else if (clk_en && (state == STATE_PICTURE_HEADER)) picture_header_seen <= 1'b1;
    else if (clk_en && (state == STATE_SEQUENCE_END)) picture_header_seen <= 1'b0;
    else picture_header_seen <= picture_header_seen;

  /* par. 6.2.2.1: Sequence header */
  loadreg #( .offset(16), .width(8), .fsm_state(STATE_START_CODE))                    loadreg_start_code (.fsm_reg(start_code), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(12), .fsm_state(STATE_SEQUENCE_HEADER))               loadreg_horizontal_size_lsb (.fsm_reg(horizontal_size[11:0]), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(12), .fsm_state(STATE_SEQUENCE_HEADER0))              loadreg_vertical_size_lsb (.fsm_reg(vertical_size[11:0]), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(4), .fsm_state(STATE_SEQUENCE_HEADER1))               loadreg_aspect_ratio_information(.fsm_reg(aspect_ratio_information), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(4), .width(4), .fsm_state(STATE_SEQUENCE_HEADER1))               loadreg_frame_rate_code(.fsm_reg(frame_rate_code), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(18), .fsm_state(STATE_SEQUENCE_HEADER2))              loadreg_bit_rate_lsb(.fsm_reg(bit_rate[17:0]), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(10), .fsm_state(STATE_SEQUENCE_HEADER3))              loadreg_vbv_buffer_size_lsb(.fsm_reg(vbv_buffer_size[9:0]), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(10), .width(1), .fsm_state(STATE_SEQUENCE_HEADER3))              loadreg_constrained_parameters_flag(.fsm_reg(constrained_parameters_flag), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));

  /* calculation of picture width in macroblocks , par. 6.3.3 */
  always @(posedge clk)
    if (~rst) mb_width <= 8'b0;
    else if (clk_en) mb_width <= (horizontal_size + 11'd15) >> 4;
    else mb_width <= mb_width;

  /* calculation of picture height in macroblocks , par. 6.3.3 */
  always @(posedge clk)
    if (~rst) mb_height <= 8'b0;
    else if (clk_en) mb_height <= progressive_sequence ? ((vertical_size + 11'd15) >> 4)  :  
                                    ((vertical_size + 11'd31) >> 5) << 1;  
//                                    ( (picture_structure==FRAME_PICTURE) ? (((vertical_size + 11'd31) >> 5) << 1) : ((vertical_size + 11'd31) >> 5) );  
    else mb_height <= mb_height;

  /* Reset quantisation matrices to default values when sequence header code is decoded (par. 6.3.11) */
  always @(posedge clk)
    if(~rst) quant_rst <= 1'b1;
    else if (clk_en) quant_rst <= (state == STATE_SEQUENCE_HEADER);
    else quant_rst <= quant_rst;

  always @(posedge clk)
    if (~rst) cnt <= 6'b0;
    else if (clk_en && ((state == STATE_SEQUENCE_HEADER3) || (state == STATE_QUANT_MATRIX_EXT))) cnt <= 6'h0;
    else if (clk_en && ((state == STATE_LD_INTRA_QUANT0)
                     || (state == STATE_LD_NON_INTRA_QUANT0)
                     || (state == STATE_LD_INTRA_QUANT1)
                     || (state == STATE_LD_NON_INTRA_QUANT1)
                     || (state == STATE_LD_CHROMA_INTRA_QUANT1)
                     || (state == STATE_LD_CHROMA_NON_INTRA_QUANT1))) cnt <= cnt + 1;
    else cnt <= cnt;

  always @(posedge clk)
    if (~rst) quant_wr_data <= 8'b0;
    else if (clk_en && (state == STATE_LD_INTRA_QUANT0)) quant_wr_data <= getbits[23:16];
    else if (clk_en && (state == STATE_LD_NON_INTRA_QUANT0)) quant_wr_data <= getbits[22:15];
    else if (clk_en && (state == STATE_LD_INTRA_QUANT1)) quant_wr_data <= getbits[22:15];
    else if (clk_en && (state == STATE_LD_NON_INTRA_QUANT1)) quant_wr_data <= getbits[21:14];
    else if (clk_en && (state == STATE_LD_CHROMA_INTRA_QUANT1)) quant_wr_data <= getbits[20:13];
    else if (clk_en && (state == STATE_LD_CHROMA_NON_INTRA_QUANT1)) quant_wr_data <= getbits[19:12];
    else quant_wr_data <= quant_wr_data;

  always @(posedge clk)
    if (~rst) quant_wr_addr <= 6'b0;
    else if (clk_en) quant_wr_addr <= cnt;
    else quant_wr_addr <= quant_wr_addr;

  always @(posedge clk)
    if (~rst) wr_intra_quant <= 1'b0;
    else if (clk_en) wr_intra_quant <= ((state == STATE_LD_INTRA_QUANT0) || (state == STATE_LD_INTRA_QUANT1));
    else wr_intra_quant <= wr_intra_quant;

  always @(posedge clk)
    if (~rst) wr_non_intra_quant <= 1'b0;
    else if (clk_en) wr_non_intra_quant <= ((state == STATE_LD_NON_INTRA_QUANT0) || (state == STATE_LD_NON_INTRA_QUANT1));
    else wr_non_intra_quant <= wr_non_intra_quant;

  always @(posedge clk)
    if (~rst) wr_chroma_intra_quant <= 1'b0;
    else if (clk_en) wr_chroma_intra_quant <= ((state == STATE_LD_INTRA_QUANT0) || (state == STATE_LD_INTRA_QUANT1) || (state == STATE_LD_CHROMA_INTRA_QUANT1));
    else wr_chroma_intra_quant <= wr_chroma_intra_quant;

  always @(posedge clk)
    if (~rst) wr_chroma_non_intra_quant <= 1'b0;
    else if (clk_en) wr_chroma_non_intra_quant <= ((state == STATE_LD_NON_INTRA_QUANT0) || (state == STATE_LD_NON_INTRA_QUANT1) || (state == STATE_LD_CHROMA_NON_INTRA_QUANT1));
    else wr_chroma_non_intra_quant <= wr_chroma_non_intra_quant;

  /* rld fifo interface */
  always @(posedge clk)
    if (~rst) rld_wr_en <= 1'b0;
    else if (clk_en) rld_wr_en <= dct_coeff_valid_0 || 
                                  ((state == STATE_SEQUENCE_HEADER) ||               // quant_rst
                                   (state == STATE_LD_INTRA_QUANT0) ||               // wr_intra_quant, wr_chroma_intra_quant
                                   (state == STATE_LD_INTRA_QUANT1) ||               // wr_intra_quant, wr_chroma_intra_quant
                                   (state == STATE_LD_NON_INTRA_QUANT0) ||           // wr_non_intra_quant, wr_chroma_non_intra_quant
                                   (state == STATE_LD_NON_INTRA_QUANT1) ||           // wr_non_intra_quant, wr_chroma_non_intra_quant
                                   (state == STATE_LD_CHROMA_INTRA_QUANT1) ||        // wr_chroma_intra_quant
                                   (state == STATE_LD_CHROMA_NON_INTRA_QUANT1));     // wr_chroma_non_intra_quant
    else rld_wr_en <= 1'b0;

  always @(posedge clk)
    if (~rst) rld_cmd <= 1'b0;
    else if (clk_en) rld_cmd <= ( dct_coeff_valid_0 ? RLD_DCT : 
                                  ((state == STATE_SEQUENCE_HEADER) ||               // quant_rst
                                   (state == STATE_LD_INTRA_QUANT0) ||               // wr_intra_quant, wr_chroma_intra_quant
                                   (state == STATE_LD_INTRA_QUANT1) ||               // wr_intra_quant, wr_chroma_intra_quant
                                   (state == STATE_LD_NON_INTRA_QUANT0) ||           // wr_non_intra_quant, wr_chroma_non_intra_quant
                                   (state == STATE_LD_NON_INTRA_QUANT1) ||           // wr_non_intra_quant, wr_chroma_non_intra_quant
                                   (state == STATE_LD_CHROMA_INTRA_QUANT1) ||        // wr_chroma_intra_quant
                                   (state == STATE_LD_CHROMA_NON_INTRA_QUANT1))      // wr_chroma_non_intra_quant
                                  ? RLD_QUANT : RLD_NOOP);
    else rld_cmd <= rld_cmd;


  /* DVD-FORK FIX (mpeg1): extension defaults. MPEG-1 has no sequence/picture-coding
   * extension, so every extension-loaded parameter would otherwise be stale (reset
   * zeroes, or the last MPEG-2 stream's values after a splice). Each affected loadreg
   * now lands in a private *_ld net and the visible signal — module output AND every
   * internal consumer alike — is muxed to the MPEG-1 constant while mpeg1 is high:
   *   progressive_sequence=1, chroma_format=4:2:0, size MSBs=0 (they only load in
   *   STATE_SEQUENCE_EXT — stale-value hazard after an MPEG-2->MPEG-1 switch),
   *   f_code_xx={0,forward/backward_f_code} (the MPEG-1 picture-header fields, parsed
   *   at STATE_PICTURE_HEADER1/2, previously unconsumed; r_size = f_code-1 per
   *   direction falls out), intra_dc_precision=8-bit, picture_structure=FRAME,
   *   tff=0, frame_pred_frame_dct=1, concealment_motion_vectors=0, q_scale_type=0
   *   (linear — arithmetically identical to MPEG-1 dequant), intra_vlc_format=0
   *   (table B-14), alternate_scan=0, rff=0, progressive_frame=1. */
  wire        progressive_sequence_ld;
  wire   [1:0]chroma_format_ld;
  wire   [1:0]horizontal_size_msb_ld;
  wire   [1:0]vertical_size_msb_ld;
  wire   [3:0]f_code_00_ld;
  wire   [3:0]f_code_01_ld;
  wire   [3:0]f_code_10_ld;
  wire   [3:0]f_code_11_ld;
  wire   [1:0]intra_dc_precision_ld;
  wire   [1:0]picture_structure_ld;
  wire        top_field_first_ld;
  wire        frame_pred_frame_dct_ld;
  wire        concealment_motion_vectors_ld;
  wire        q_scale_type_ld;
  wire        intra_vlc_format_ld;
  wire        alternate_scan_ld;
  wire        repeat_first_field_ld;
  wire        progressive_frame_ld;

  assign progressive_sequence       = mpeg1 ? 1'b1                     : progressive_sequence_ld;
  assign chroma_format              = mpeg1 ? CHROMA420                : chroma_format_ld;
  assign horizontal_size[13:12]     = mpeg1 ? 2'b00                    : horizontal_size_msb_ld;
  assign vertical_size[13:12]       = mpeg1 ? 2'b00                    : vertical_size_msb_ld;
  assign f_code_00                  = mpeg1 ? {1'b0, forward_f_code}   : f_code_00_ld;
  assign f_code_01                  = mpeg1 ? {1'b0, forward_f_code}   : f_code_01_ld;
  assign f_code_10                  = mpeg1 ? {1'b0, backward_f_code}  : f_code_10_ld;
  assign f_code_11                  = mpeg1 ? {1'b0, backward_f_code}  : f_code_11_ld;
  assign intra_dc_precision         = mpeg1 ? 2'b00                    : intra_dc_precision_ld;
  assign picture_structure          = mpeg1 ? FRAME_PICTURE            : picture_structure_ld;
  assign top_field_first            = mpeg1 ? 1'b0                     : top_field_first_ld;
  assign frame_pred_frame_dct       = mpeg1 ? 1'b1                     : frame_pred_frame_dct_ld;
  assign concealment_motion_vectors = mpeg1 ? 1'b0                     : concealment_motion_vectors_ld;
  assign q_scale_type               = mpeg1 ? 1'b0                     : q_scale_type_ld;
  assign intra_vlc_format           = mpeg1 ? 1'b0                     : intra_vlc_format_ld;
  assign alternate_scan             = mpeg1 ? 1'b0                     : alternate_scan_ld;
  assign repeat_first_field         = mpeg1 ? 1'b0                     : repeat_first_field_ld;
  assign progressive_frame          = mpeg1 ? 1'b1                     : progressive_frame_ld;

  /* par. 6.2.2.3: Sequence extension */ 
  loadreg #( .offset(0), .width(8), .fsm_state(STATE_SEQUENCE_EXT))                  loadreg_profile_and_level_indication(.fsm_reg(profile_and_level_indication), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(8), .width(1), .fsm_state(STATE_SEQUENCE_EXT))                  loadreg_progressive_sequence(.fsm_reg(progressive_sequence_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(9), .width(2), .fsm_state(STATE_SEQUENCE_EXT))                  loadreg_chroma_format(.fsm_reg(chroma_format_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(11), .width(2), .fsm_state(STATE_SEQUENCE_EXT))                 loadreg_horizontal_size_msb(.fsm_reg(horizontal_size_msb_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(13), .width(2), .fsm_state(STATE_SEQUENCE_EXT))                 loadreg_vertical_size_msb(.fsm_reg(vertical_size_msb_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(12), .fsm_state(STATE_SEQUENCE_EXT0))                loadreg_bit_rate_msb(.fsm_reg(bit_rate[29:18]), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(8), .fsm_state(STATE_SEQUENCE_EXT1))                 loadreg_vbv_buffer_size_msb(.fsm_reg(vbv_buffer_size[17:10]), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(8), .width(1), .fsm_state(STATE_SEQUENCE_EXT1))                 loadreg_low_delay(.fsm_reg(low_delay), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(9), .width(2), .fsm_state(STATE_SEQUENCE_EXT1))                 loadreg_frame_rate_extension_n(.fsm_reg(frame_rate_extension_n), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(11), .width(5), .fsm_state(STATE_SEQUENCE_EXT1))                loadreg_frame_rate_extension_d(.fsm_reg(frame_rate_extension_d), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));


  /* par. 6.2.2.4: Sequence display extension */
  loadreg #( .offset(0), .width(3), .fsm_state(STATE_SEQUENCE_DISPLAY_EXT))          loadreg_video_format(.fsm_reg(video_format), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(8), .fsm_state(STATE_SEQUENCE_DISPLAY_EXT0))         loadreg_colour_primaries(.fsm_reg(colour_primaries), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(8), .width(8), .fsm_state(STATE_SEQUENCE_DISPLAY_EXT0))         loadreg_transfer_characteristics(.fsm_reg(transfer_characteristics), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(16), .width(8), .fsm_state(STATE_SEQUENCE_DISPLAY_EXT0))        loadreg_matrix_coefficients(.fsm_reg(matrix_coefficients), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(14), .fsm_state(STATE_SEQUENCE_DISPLAY_EXT1))        loadreg_display_horizontal_size(.fsm_reg(display_horizontal_size), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(14), .fsm_state(STATE_SEQUENCE_DISPLAY_EXT2))        loadreg_display_vertical_size(.fsm_reg(display_vertical_size), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));

  /* par. 6.2.3.1: Picture coding extension */
  loadreg #( .offset(0), .width(4), .fsm_state(STATE_PICTURE_CODING_EXT))            loadreg_f_code_00(.fsm_reg(f_code_00_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(4), .width(4), .fsm_state(STATE_PICTURE_CODING_EXT))            loadreg_f_code_01(.fsm_reg(f_code_01_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(8), .width(4), .fsm_state(STATE_PICTURE_CODING_EXT))            loadreg_f_code_10(.fsm_reg(f_code_10_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(12), .width(4), .fsm_state(STATE_PICTURE_CODING_EXT))           loadreg_f_code_11(.fsm_reg(f_code_11_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(2), .fsm_state(STATE_PICTURE_CODING_EXT0))           loadreg_intra_dc_precision(.fsm_reg(intra_dc_precision_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(2), .width(2), .fsm_state(STATE_PICTURE_CODING_EXT0))           loadreg_picture_structure(.fsm_reg(picture_structure_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(4), .width(1), .fsm_state(STATE_PICTURE_CODING_EXT0))           loadreg_top_field_first(.fsm_reg(top_field_first_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(5), .width(1), .fsm_state(STATE_PICTURE_CODING_EXT0))           loadreg_frame_pred_frame_dct(.fsm_reg(frame_pred_frame_dct_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(6), .width(1), .fsm_state(STATE_PICTURE_CODING_EXT0))           loadreg_concealment_motion_vectors(.fsm_reg(concealment_motion_vectors_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(7), .width(1), .fsm_state(STATE_PICTURE_CODING_EXT0))           loadreg_q_scale_type(.fsm_reg(q_scale_type_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(8), .width(1), .fsm_state(STATE_PICTURE_CODING_EXT0))           loadreg_intra_vlc_format(.fsm_reg(intra_vlc_format_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(9), .width(1), .fsm_state(STATE_PICTURE_CODING_EXT0))           loadreg_alternate_scan(.fsm_reg(alternate_scan_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(10), .width(1), .fsm_state(STATE_PICTURE_CODING_EXT0))          loadreg_repeat_first_field(.fsm_reg(repeat_first_field_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(11), .width(1), .fsm_state(STATE_PICTURE_CODING_EXT0))          loadreg_chroma_420_type(.fsm_reg(chroma_420_type), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(12), .width(1), .fsm_state(STATE_PICTURE_CODING_EXT0))          loadreg_progressive_frame(.fsm_reg(progressive_frame_ld), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(13), .width(1), .fsm_state(STATE_PICTURE_CODING_EXT0))          loadreg_composite_display_flag(.fsm_reg(composite_display_flag), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(1), .fsm_state(STATE_PICTURE_CODING_EXT1))           loadreg_v_axis(.fsm_reg(v_axis), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(1), .width(3), .fsm_state(STATE_PICTURE_CODING_EXT1))           loadreg_field_sequence(.fsm_reg(field_sequence), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(4), .width(1), .fsm_state(STATE_PICTURE_CODING_EXT1))           loadreg_sub_carrier(.fsm_reg(sub_carrier), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(5), .width(7), .fsm_state(STATE_PICTURE_CODING_EXT1))           loadreg_burst_amplitude(.fsm_reg(burst_amplitude), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(12), .width(8), .fsm_state(STATE_PICTURE_CODING_EXT1))          loadreg_sub_carrier_phase(.fsm_reg(sub_carrier_phase), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));

  /* par. 6.2.2.6: group of pictures header */
  loadreg #( .offset(0), .width(1), .fsm_state(STATE_GROUP_HEADER))                  loadreg_drop_flag(.fsm_reg(drop_flag), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(1), .width(5), .fsm_state(STATE_GROUP_HEADER))                  loadreg_time_code_hours(.fsm_reg(time_code_hours), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(6), .width(6), .fsm_state(STATE_GROUP_HEADER))                  loadreg_time_code_minutes(.fsm_reg(time_code_minutes), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(13), .width(6), .fsm_state(STATE_GROUP_HEADER))                 loadreg_time_code_seconds(.fsm_reg(time_code_seconds), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(6), .fsm_state(STATE_GROUP_HEADER0))                 loadreg_time_code_pictures(.fsm_reg(time_code_pictures), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(6), .width(1), .fsm_state(STATE_GROUP_HEADER0))                 loadreg_closed_gop(.fsm_reg(closed_gop), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(7), .width(1), .fsm_state(STATE_GROUP_HEADER0))                 loadreg_broken_link(.fsm_reg(broken_link), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));

  /* par. 6.2.3: picture header */
  loadreg #( .offset(0), .width(10), .fsm_state(STATE_PICTURE_HEADER))               loadreg_temporal_reference(.fsm_reg(temporal_reference), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(10), .width(3), .fsm_state(STATE_PICTURE_HEADER))               loadreg_picture_coding_type(.fsm_reg(picture_coding_type), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(16), .fsm_state(STATE_PICTURE_HEADER0))              loadreg_vbv_delay(.fsm_reg(vbv_delay), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(1), .fsm_state(STATE_PICTURE_HEADER1))               loadreg_full_pel_forward_vector(.fsm_reg(full_pel_forward_vector), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(1), .width(3), .fsm_state(STATE_PICTURE_HEADER1))               loadreg_forward_f_code(.fsm_reg(forward_f_code), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(0), .width(1), .fsm_state(STATE_PICTURE_HEADER2))               loadreg_full_pel_backward_vector(.fsm_reg(full_pel_backward_vector), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));
  loadreg #( .offset(1), .width(3), .fsm_state(STATE_PICTURE_HEADER2))               loadreg_backward_f_code(.fsm_reg(backward_f_code), .clk(clk), .clk_en(clk_en), .rst(rst), .state(state), .getbits(getbits));

  /* par. 6.2.4: slice */
  /* macroblock address increment vlc lookup */
  assign {macroblock_addr_inc_length, macroblock_addr_inc_value, macroblock_addr_inc_escape} = macroblock_address_increment_dec(getbits[23:13]);

  /* macroblock type vlc lookup */
  assign {macroblock_type_length, macroblock_type_value} = macroblock_type_dec(getbits[23:18], picture_coding_type);

  /* coded block pattern vlc lookup */
  assign {coded_block_pattern_length, coded_block_pattern_value} = coded_block_pattern_dec(getbits[23:15]);

  /* motion code vlc lookup */
  assign {motion_code_length, motion_code_value, motion_code_sign} = motion_code_dec(getbits[23:13]);

  /* dmvector vlc lookup */
  assign {dmvector_length, dmvector_value, dmvector_sign} = dmvector_dec(getbits[23:22]);

  /* dct dc size luminance vlc lookup */
  assign {dct_dc_size_luminance_length, dct_dc_size_luminance_value} = dct_dc_size_luminance_dec(getbits[23:15]);

  /* dct dc size chrominance vlc lookup */
  assign {dct_dc_size_chrominance_length, dct_dc_size_chrominance_value} = dct_dc_size_chrominance_dec(getbits[23:14]);

  /* dct coefficient 0 vlc lookup */
  always @(getbits)
    dct_coefficient_0_decoded = dct_coefficient_0_dec(getbits[23:8]);

  /* dct first coefficient 0 vlc lookup */
  /* see note 2 and 3 of table B-14: first coefficient handled differently. */
  /* Code 2'b10 = 1, Code 2'b11 = -1 */
  always @(getbits, dct_coefficient_0_decoded)
    dct_non_intra_first_coefficient_0_decoded = getbits[23] ? {5'd2, 5'd0, 6'd1} : dct_coefficient_0_decoded;

  /* dct coefficient 1 vlc lookup */
  always @(getbits)
    dct_coefficient_1_decoded = dct_coefficient_1_dec(getbits[23:8]);

  /* internal registers */
  /* slice start code */
  /* this does not take into account slice_vertial_position_extension (par.  6.3.16). This limits vertical resolution to 2800 lines. */
  always @(posedge clk)
    if (~rst) slice_vertical_position <= 8'b0;
    else if (clk_en && (state == STATE_SLICE)) slice_vertical_position <= start_code;
    else slice_vertical_position <= slice_vertical_position;

  /* slice quantiser scale */
  always @(posedge clk)
    if (~rst) quantiser_scale_code <= 5'b0;
    else if (clk_en && ((state == STATE_SLICE) || ((state == STATE_MACROBLOCK_QUANT) && macroblock_quant))) quantiser_scale_code <= getbits[23:19];
    else quantiser_scale_code <= quantiser_scale_code;

  always @(posedge clk)
    if (~rst) slice_extension_flag <= 1'b0;
    else if (clk_en && (state == STATE_SLICE)) slice_extension_flag <= getbits[18];
    else slice_extension_flag <= slice_extension_flag;

  /* slice extension */
  always @(posedge clk)
    if (~rst) intra_slice <= 1'b0;
    else if (clk_en && (state == STATE_SLICE_EXTENSION)) intra_slice <= getbits[23];
    else intra_slice <= intra_slice;

  always @(posedge clk)
    if (~rst) slice_picture_id_enable <= 1'b0;
    else if (clk_en && (state == STATE_SLICE_EXTENSION)) slice_picture_id_enable <= getbits[22];
    else slice_picture_id_enable <= slice_picture_id_enable;

  always @(posedge clk)
    if (~rst) slice_picture_id <= 6'b0;
    else if (clk_en && (state == STATE_SLICE_EXTENSION)) slice_picture_id <= getbits[21:16];
    else slice_picture_id <= slice_picture_id;

  /* macroblock address */
  /* 
   * Note macroblock address calculation is for the restricted slice structure (par. 6.1.2.2) where slices seamlessly cover the whole picture.
   * Support for the general slice structure (par. 6.1.2.1) with gaps between slices could be added if needed.
   */

  always @(posedge clk)
    if (~rst) first_macroblock_of_slice <= 1'b0;
    else if (clk_en && (state == STATE_SLICE)) first_macroblock_of_slice <= 1'b1;
    else if (clk_en && (state == STATE_MACROBLOCK_TYPE)) first_macroblock_of_slice <= 1'b0;
    else first_macroblock_of_slice <= first_macroblock_of_slice;

  reg [15:0]mb_row_by_mb_width;
  wire [7:0]mb_row = start_code - 8'd1;

  always @(posedge clk)
    if (~rst) mb_row_by_mb_width <= 13'b0;
    else if (clk_en && (state == STATE_SLICE)) mb_row_by_mb_width <= mb_row * mb_width;
    else mb_row_by_mb_width <= mb_row_by_mb_width;

  /* 
   * no skipped macroblocks allowed at slice start. At slice start:
   * macroblock_address <= ( start_code - 1 ) * mb_width + macroblock_address_increment - 1; 
   * macroblock_address_increment <= 1;
   */

  wire [15:0]macroblock_address_increment_ext = macroblock_address_increment;
  wire [15:0]next_macroblock_address = mb_row_by_mb_width + macroblock_address_increment_ext - 16'd1;

  always @(posedge clk)
    if (~rst) macroblock_address <= 13'b0;
    else if (clk_en && (state == STATE_MACROBLOCK_TYPE) && first_macroblock_of_slice) macroblock_address <= next_macroblock_address[12:0]; // macroblock in 1920x1080 are numbered 0..8159, hence 13 bits.
    else if (clk_en && ((state == STATE_MACROBLOCK_TYPE) || (state == STATE_MACROBLOCK_SKIP))) macroblock_address <= macroblock_address + 13'b1;
    else macroblock_address <= macroblock_address;

  always @(posedge clk)
    if (~rst) macroblock_address_increment <= 7'b0;
    else if (clk_en && ((state == STATE_SLICE) || (state == STATE_NEXT_BLOCK))) macroblock_address_increment <= 7'd0;
    else if (clk_en && (state == STATE_NEXT_MACROBLOCK) && macroblock_addr_inc_escape) macroblock_address_increment <= macroblock_address_increment + 7'd33; // par. 6.3.17, macroblock_escape
    else if (clk_en && (state == STATE_NEXT_MACROBLOCK)) macroblock_address_increment <=  macroblock_address_increment + macroblock_addr_inc_value_ext;
    else if (clk_en && (state == STATE_MACROBLOCK_SKIP)) macroblock_address_increment <= macroblock_address_increment - 7'd1; // counting down number of macroblocks to skip
    else macroblock_address_increment <= macroblock_address_increment;

  always @(posedge clk)
    if (~rst) empty_blocks <= 11'b0;
    else if (clk_en && (state == STATE_MACROBLOCK_SKIP)) 
      begin
        case (chroma_format)
          CHROMA420: empty_blocks <= {11'b11111000000};  // emit 6 empty (all-zeroes) blocks for 4:2:0
          CHROMA422: empty_blocks <= {11'b11111110000};  // emit 8 empty (all-zeroes) blocks for 4:2:2
          CHROMA444: empty_blocks <= {11'b11111111111};  // emit 12 empty (all-zeroes) blocks for 4:4:4
          default    empty_blocks <= {11'b00000000000};  // error
        endcase
      end
    else if (clk_en && (state == STATE_EMIT_EMPTY_BLOCK)) empty_blocks <= empty_blocks << 1;
    else empty_blocks <= empty_blocks;

  /* macroblock type */
  always @(posedge clk)
    if (~rst) macroblock_quant <= 1'b0;
    else if (clk_en && (state == STATE_MACROBLOCK_TYPE)) macroblock_quant <= macroblock_type_value[5];
    else macroblock_quant <= macroblock_quant;

  always @(posedge clk)
    if (~rst) macroblock_motion_forward <= 1'b0;
    else if (clk_en && (state == STATE_MACROBLOCK_TYPE)) macroblock_motion_forward <= macroblock_type_value[4];
    else macroblock_motion_forward <= macroblock_motion_forward;

  always @(posedge clk)
    if (~rst) macroblock_motion_backward <= 1'b0;
    else if (clk_en && (state == STATE_MACROBLOCK_TYPE)) macroblock_motion_backward <= macroblock_type_value[3];
    else macroblock_motion_backward <= macroblock_motion_backward;

  always @(posedge clk)
    if (~rst) macroblock_pattern <= 1'b0;
    else if (clk_en && (state == STATE_MACROBLOCK_TYPE)) macroblock_pattern <= macroblock_type_value[2];
    else macroblock_pattern <= macroblock_pattern;

  /*
   * macroblock_type_intra is asserted when macroblock_type indicates this macroblock is an intra macroblock.
   * Intra macroblocks are fully coded. Skipped macroblocks are fully predicted.
   * However, skipped macroblocks are never intra macroblocks. 
   * Hence macroblock_intra is low when we're emitting a skipped macroblock,
   * even if the macroblock being decoded is an intra macroblock.
   * If we're not emitting a skipped macroblock, macroblock_intra has the same
   * value as macroblock_type_intra.
   */

  always @(posedge clk)
    if (~rst) macroblock_type_intra <= 1'b0;
    else if (clk_en && (state == STATE_MACROBLOCK_TYPE)) macroblock_type_intra <= macroblock_type_value[1];
    else macroblock_type_intra <= macroblock_type_intra;

  always @(posedge clk)
    if (~rst) macroblock_intra <= 1'b0;
    else if (clk_en && (state == STATE_MACROBLOCK_TYPE)) macroblock_intra <= macroblock_type_value[1];
    else if (clk_en && (state == STATE_MACROBLOCK_SKIP)) macroblock_intra <= 1'b0;
    else if (clk_en) macroblock_intra <= macroblock_type_intra;
    else macroblock_intra <= macroblock_intra;

  always @(posedge clk)
    if (~rst) spatial_temporal_weight_code_flag <= 1'b0;
    else if (clk_en && (state == STATE_MACROBLOCK_TYPE)) spatial_temporal_weight_code_flag <= macroblock_type_value[0];
    else spatial_temporal_weight_code_flag <= spatial_temporal_weight_code_flag;

  /* motion type */
  always @(posedge clk)
    // par. 6.3.17.1: In this case motion vector decoding and prediction formation shall be performed as if frame_motion_type had indicated "Frame-based prediction".
    // 2 == Frame-based prediction.
    // par. 6.3.17.1: In the case of intra macroblocks (in a field picture) when concealment_motion_vectors is equal to 1 field_motion_type is not present in the bitstream.
    // In this case, motion vector decoding and update of the motion vector predictors shall be performed as if field_motion_type had indicated "Field-based"
    // 2'b1 == Field-based prediction.
    if (~rst) motion_type <= 2'd0;
    else if (clk_en && (state == STATE_MOTION_TYPE) && (macroblock_motion_forward || macroblock_motion_backward)  && (picture_structure == FRAME_PICTURE)) motion_type <= frame_pred_frame_dct ? MC_FRAME : getbits[23:22]; /* frame_motion_type */
    else if (clk_en && (state == STATE_MOTION_TYPE) && (macroblock_motion_forward || macroblock_motion_backward)) motion_type <= getbits[23:22]; /* field_motion_type */
    else if (clk_en && (state == STATE_MOTION_TYPE) && (macroblock_intra && concealment_motion_vectors)) motion_type <= (picture_structure==FRAME_PICTURE) ? MC_FRAME : MC_FIELD; /* concealment motion vectors */
    else if (clk_en && (state == STATE_MOTION_TYPE)) motion_type <= MC_NONE;
    else if (clk_en && (state == STATE_MACROBLOCK_SKIP)) motion_type <= (picture_structure == FRAME_PICTURE) ? MC_FRAME : MC_FIELD; // par. 7.6.6 the prediction shall be made as if (field|frame)_motion_type is "Field-based"|"Frame-based"
    else motion_type <= motion_type;

  /* dct type */
  /*
   dct_type is a flag indicating whether the macroblock is frame DCT coded or field DCT coded. If this is set to '1', the macroblock is field DCT coded. 
   In the case that dct_type is not present in the bitstream, then the value of dct_type (used in the remainder of the decoding process) shall be derived as shown in Table 6-19. 
   (par. 6.3.17.1, Macroblock modes)
   */

  always @(posedge clk)
    if (~rst) dct_type <= 1'b0;
    else if (clk_en && (state == STATE_MOTION_TYPE)) dct_type <= 1'b0;
    else if (clk_en && (state == STATE_DCT_TYPE)) dct_type <= getbits[23];
    else dct_type <= dct_type;

  // derived variables (par. 6.3.17.1, tables 6.17 and 6.18)
  // note  spatial_temporal_weight is always zero, we don't do scaleability.
  assign motion_vector_count_is_one = (picture_structure==FRAME_PICTURE) ? (motion_type != MC_FIELD) : (motion_type != MC_16X8);

  always @(posedge clk)
    if (~rst) mv_format <= 2'b0;
    else if (clk_en) mv_format <= (picture_structure==FRAME_PICTURE) ? ((motion_type==MC_FRAME) ? MV_FRAME : MV_FIELD) : MV_FIELD;
    else mv_format <= mv_format;

  always @(posedge clk)
    if (~rst) dmv <= 1'b0;
    else if (clk_en) dmv <= (motion_type==MC_DMV);
    else dmv <= dmv;

  /* motion vectors */

  /* motion_vectors(0), motion_vertical_field_select(0,0) */
  /* par. 6.3.17.3: The number of bits in the bitstream for motion_residual[r][s][t], r_size, is derived from f_code[s][t] as follows:
   * r_size = f_code[s][t] - 1;
   */
  always @(posedge clk)
    if (~rst) r_size <= 4'd0;
    else if (clk_en && (state == STATE_NEXT_MOTION_VECTOR) && ((motion_vector == MOTION_VECTOR_0_0_0) || (motion_vector == MOTION_VECTOR_1_0_0))) r_size <= f_code_00 - 4'd1;
    else if (clk_en && (state == STATE_NEXT_MOTION_VECTOR) && ((motion_vector == MOTION_VECTOR_0_0_1) || (motion_vector == MOTION_VECTOR_1_0_1))) r_size <= f_code_01 - 4'd1;
    else if (clk_en && (state == STATE_NEXT_MOTION_VECTOR) && ((motion_vector == MOTION_VECTOR_0_1_0) || (motion_vector == MOTION_VECTOR_1_1_0))) r_size <= f_code_10 - 4'd1;
    else if (clk_en && (state == STATE_NEXT_MOTION_VECTOR) && ((motion_vector == MOTION_VECTOR_0_1_1) || (motion_vector == MOTION_VECTOR_1_1_1))) r_size <= f_code_11 - 4'd1;
    else r_size <= r_size;

  // vertical_field_select_present - one if motion_vector(s) begins with a 'motion_vertical_field_select'.
  assign vertical_field_select_present = (motion_vector_count_is_one ? ( (mv_format == MV_FIELD) && (dmv != 1'b1) ) : 1'd1 ) 
                                         && ((motion_vector == MOTION_VECTOR_0_0_0) || (motion_vector == MOTION_VECTOR_1_0_0) || 
                                             (motion_vector == MOTION_VECTOR_0_1_0) || (motion_vector == MOTION_VECTOR_1_1_0)); // par. 6.2.5.1

  /* motion code variables, par. 6.2.5, 6.2.5.2, 6.2.5.2.1 */
  /*
   * motion_vector cycles through the different motion vectors MOTION_VECTOR_0_0_0 ... MOTION_VECTOR_1_1_1
   * The msb of  motion_vector_reg is one if the motion vector actually occurs in the bitstream.
   */
  always @(posedge clk)
    if (~rst) motion_vector <= 3'b0;
    else if (clk_en && (state == STATE_MACROBLOCK_QUANT)) motion_vector <= MOTION_VECTOR_0_0_0; 
    else if (clk_en && (state == STATE_MOTION_PREDICT)) motion_vector <= motion_vector + 1;
    else if (clk_en && (state == STATE_NEXT_MOTION_VECTOR) && (motion_vector_reg[7] == 1'b0)) motion_vector <= motion_vector + 1;
    else motion_vector <= motion_vector;

  always @(posedge clk)
    if (~rst) motion_vector_reg <= 8'b0;
    else if (clk_en && (state == STATE_MACROBLOCK_QUANT)) /* set up motion_vector_reg */
      case ({macroblock_motion_forward || (macroblock_intra && concealment_motion_vectors), macroblock_motion_backward, motion_vector_count_is_one})
        3'b000: motion_vector_reg <= 8'b00000000; // no motion vectors
        3'b001: motion_vector_reg <= 8'b00000000; // no motion vectors
        3'b100: motion_vector_reg <= 8'b11110000; // motion_code_000, 001, 100, 101
        3'b101: motion_vector_reg <= 8'b11000000; // motion_code_000, 001
        3'b010: motion_vector_reg <= 8'b00001111; // motion_code_                    010, 011, 110, 111
        3'b011: motion_vector_reg <= 8'b00001100; // motion_code_                    010, 011
        3'b110: motion_vector_reg <= 8'b11111111; // motion_code_000, 001, 100, 101, 010, 011, 110, 111
        3'b111: motion_vector_reg <= 8'b11001100; // motion_code_000, 001,           010, 011
      endcase
    else if (clk_en && (state == STATE_MOTION_PREDICT)) motion_vector_reg <= motion_vector_reg << 1;
    else if (clk_en && (state == STATE_NEXT_MOTION_VECTOR) && (motion_vector_reg[7] == 1'b0)) motion_vector_reg <= motion_vector_reg << 1;
    else motion_vector_reg <= motion_vector_reg;

  always @(posedge clk)
    if (~rst) motion_code <= 5'b0;
    else if (clk_en && (state == STATE_NEXT_MOTION_VECTOR)) motion_code <= 5'b0;
    else if (clk_en && (state == STATE_MOTION_CODE)) motion_code <= motion_code_value;
    else motion_code <= motion_code;

  always @(posedge clk)
    if (~rst) motion_code_neg <= 1'b0;
    else if (clk_en && (state == STATE_NEXT_MOTION_VECTOR)) motion_code_neg <= 1'b0;
    else if (clk_en && (state == STATE_MOTION_CODE)) motion_code_neg <= motion_code_sign;
    else motion_code_neg <= motion_code_neg;

  always @(posedge clk)
    if (~rst) motion_code_residual <= 8'b0;
    else if (clk_en && (state == STATE_NEXT_MOTION_VECTOR)) motion_code_residual <= 8'b0;
    else if (clk_en && (state == STATE_MOTION_RESIDUAL))
                     begin
                       case (r_size)
                        14'd00: motion_code_residual <= {8'b0}; // Error, f_code != 1 hence r_size != 0.
                        14'd01: motion_code_residual <= {7'b0, getbits[23]};
                        14'd02: motion_code_residual <= {6'b0, getbits[23:22]};
                        14'd03: motion_code_residual <= {5'b0, getbits[23:21]};
                        14'd04: motion_code_residual <= {4'b0, getbits[23:20]};
                        14'd05: motion_code_residual <= {3'b0, getbits[23:19]};
                        14'd06: motion_code_residual <= {2'b0, getbits[23:18]};
                        14'd07: motion_code_residual <= {1'b0, getbits[23:17]};
                        14'd08: motion_code_residual <=        getbits[23:16];
                        default motion_code_residual <=        getbits[23:16]; // Should never happen, as r_size is 1..8 (f_code = 1..9 in Table E-8 at high level)
                       endcase
                     end
    else motion_code_residual <= motion_code_residual;

  always @(posedge clk)
    if (~rst) dmvector <= 2'b0;
    else if (clk_en && (state == STATE_NEXT_MOTION_VECTOR)) dmvector <= 2'b0;
    else if (clk_en && (state == STATE_MOTION_DMVECTOR)) 
      begin
        case ({dmvector_sign, dmvector_value}) 
	  {1'b0, 1'b0}:  dmvector <= 2'b0;
	  {1'b0, 1'b1}:  dmvector <= 2'b1;
	  {1'b1, 1'b0}:  dmvector <= 2'b0;
	  {1'b1, 1'b1}:  dmvector <= -2'b1;
	endcase
      end
    else dmvector <= dmvector;

  /*
   * Resetting motion vector predictors, par. 7.6.3.4. 
   * Also includes updating motion vector predictors to zero, par. 7.6.3.3.
   *
   * The difference between resetting and updating is that updating occurs
   * after the motion vectors have been processed, in STATE_BLOCK
   */

  wire pmv_reset = (state == STATE_SLICE) || /* par. 7.6.3.4, At the start of each slice. */ 
                   ((state == STATE_MACROBLOCK_QUANT) && macroblock_intra && ~concealment_motion_vectors) || /* par. 7.6.3.4, Whenever an intra macroblock is decoded which has no concealment motion vectors. */ 
                   ((state == STATE_MACROBLOCK_QUANT) && (picture_coding_type == P_TYPE) && ~macroblock_intra && ~macroblock_motion_forward) || /* par. 7.6.3.4, In a P-picture when a non-intra macroblock is decoded in which macroblock_motion_forward is zero. */ 
		   ((state == STATE_MACROBLOCK_SKIP) && (picture_coding_type == P_TYPE)); /* par. 7.6.3.4, In a P-picture when a macroblock is skipped. Also 7.6.6.1, 7.6.6.2 */ 

		   
  /*
   * Updating motion vector predictors. Table 7-9 and 7-10.
   * When to PMV[1][0][1:0] = PMV[0][0][1:0]
   */

  wire pmv_update0 =   ((picture_structure == FRAME_PICTURE) && (motion_type == MC_FRAME) && macroblock_intra) ||
                       ((picture_structure == FRAME_PICTURE) && (motion_type == MC_FRAME) && macroblock_motion_forward) ||
                       ((picture_structure == FRAME_PICTURE) && (motion_type == MC_DMV) && macroblock_motion_forward && ~macroblock_motion_backward && ~macroblock_intra) ||
		       (((picture_structure == TOP_FIELD) || (picture_structure == BOTTOM_FIELD)) && (motion_type == MC_FIELD) && macroblock_intra) ||
		       (((picture_structure == TOP_FIELD) || (picture_structure == BOTTOM_FIELD)) && (motion_type == MC_FIELD) && macroblock_motion_forward) ||
		       (((picture_structure == TOP_FIELD) || (picture_structure == BOTTOM_FIELD)) && (motion_type == MC_DMV) && macroblock_motion_forward && ~macroblock_motion_backward && ~macroblock_intra) ;

  /*
   * Updating motion vector predictors. Table 7-9 and 7-10.
   * When to PMV[1][1][1:0] = PMV[0][1][1:0]
   */

  wire pmv_update1 =  ((picture_structure == FRAME_PICTURE) && (motion_type == MC_FRAME) && ~macroblock_intra && macroblock_motion_backward) ||
		      (((picture_structure == TOP_FIELD) || (picture_structure == BOTTOM_FIELD)) && (motion_type == MC_FIELD) && ~macroblock_intra && macroblock_motion_backward) ;

  /* motion vector pipeline */
  always @(posedge clk)  
    if (~rst) 
      begin
        motion_vector_0 <= 2'b0;
        motion_vector_1 <= 2'b0;
        motion_vector_2 <= 2'b0;
        motion_vector_3 <= 2'b0;
        motion_vector_4 <= 2'b0;
        motion_vector_5 <= 2'b0;
      end
    else if (clk_en)
      begin
        motion_vector_0 <= motion_vector;
        motion_vector_1 <= motion_vector_0;
        motion_vector_2 <= motion_vector_1;
        motion_vector_3 <= motion_vector_2;
        motion_vector_4 <= motion_vector_3;
        motion_vector_5 <= motion_vector_4;
      end
    else 
      begin
        motion_vector_0 <= motion_vector_0;
        motion_vector_1 <= motion_vector_1;
        motion_vector_2 <= motion_vector_2;
        motion_vector_3 <= motion_vector_3;
        motion_vector_4 <= motion_vector_4;
        motion_vector_5 <= motion_vector_5;
      end

  always @(posedge clk)  
    if (~rst) 
      begin
        motion_vector_valid_0 <= 1'b0;
        motion_vector_valid_1 <= 1'b0;
        motion_vector_valid_2 <= 1'b0;
        motion_vector_valid_3 <= 1'b0;
        motion_vector_valid_4 <= 1'b0;
        motion_vector_valid_5 <= 1'b0;
      end
    else if (clk_en)
      begin
        motion_vector_valid_0 <= (state == STATE_MOTION_PREDICT);
        motion_vector_valid_1 <= motion_vector_valid_0;
        motion_vector_valid_2 <= motion_vector_valid_1;
        motion_vector_valid_3 <= motion_vector_valid_2;
        motion_vector_valid_4 <= motion_vector_valid_3;
        motion_vector_valid_5 <= motion_vector_valid_4;
      end
    else 
      begin
        motion_vector_valid_0 <= motion_vector_valid_0;
        motion_vector_valid_1 <= motion_vector_valid_1;
        motion_vector_valid_2 <= motion_vector_valid_2;
        motion_vector_valid_3 <= motion_vector_valid_3;
        motion_vector_valid_4 <= motion_vector_valid_4;
        motion_vector_valid_5 <= motion_vector_valid_5;
      end

  always @(posedge clk)  
    if (~rst) 
      begin
        r_size_0 <= 4'b0;
        r_size_1 <= 4'b0;
      end
    else if (clk_en)
      begin
        r_size_0 <= r_size;
        r_size_1 <= r_size_0;
      end
    else 
      begin
        r_size_0 <= r_size_0;
        r_size_1 <= r_size_1;
      end

  always @(posedge clk)  
    if (~rst) motion_code_neg_0 <= 1'b0;
    else if (clk_en) motion_code_neg_0 <= motion_code_neg;
    else motion_code_neg_0 <= motion_code_neg_0;

  wire signed [12:0]motion_code_signed = {8'b0, motion_code};
  wire signed [12:0]motion_code_residual_signed = {5'b0, motion_code_residual};

  always @(posedge clk)  
    if (~rst) pmv_delta_0 <= 13'b0;
    else if (clk_en) pmv_delta_0 <= ((r_size == 4'b0) || (motion_code == 5'b0)) ? motion_code_signed : ((motion_code_signed - 13'sd1) <<< r_size) + motion_code_residual_signed + 13'sd1;
    else pmv_delta_0 <= pmv_delta_0;

  wire shift_pmv = (mv_format == MV_FIELD) && (picture_structure == FRAME_PICTURE);

  /* DVD-FORK FIX (mpeg1): full-pel motion vectors (MPEG-1 picture-header flags
   * full_pel_forward_vector / full_pel_backward_vector). MSSG reference semantics:
   * PMV storage stays in HALF-pel units; when full-pel applies to the vector being
   * reconstructed:  vec = (pred >> 1) + delta;  wrap on lim = 16 << r_size (the
   * existing stage-3 sign-truncation, operating on the full-pel value);
   * stored pred = vec << 1.  The >>1 is exact — every PMV stored in full-pel mode is
   * a vec<<1 (even), and pmv_reset zeroes are even too. Applied per DIRECTION:
   * motion_vector[2] is the s index (0 = forward, 1 = backward). shift_pmv (the
   * MPEG-2 field-in-frame vertical halving) is mutually exclusive with mpeg1
   * (picture_structure forced FRAME + frame_pred_frame_dct=1 -> MV_FRAME), so the
   * ORed conditions below can never double-shift. full_pel_rd keys off the CURRENT
   * motion_vector (stage-1 predictor read); full_pel_wr keys off motion_vector_5
   * (stage-6 write-back), both against the same per-picture header flags. */
  wire full_pel_rd = mpeg1 && (motion_vector[2]   ? full_pel_backward_vector : full_pel_forward_vector);
  wire full_pel_wr = mpeg1 && (motion_vector_5[2] ? full_pel_backward_vector : full_pel_forward_vector);

  always @(posedge clk)  
    if (~rst) 
      begin
        pmv_0 <= 13'b0;
        pmv_1 <= 13'b0;
        pmv_2 <= 13'b0;
        pmv_3 <= 13'b0;
        pmv_4 <= 13'b0;
        pmv_5 <= 13'b0;
      end
    else if (clk_en)
      begin
        /* stage 1 */
        /* DVD-FORK FIX (mpeg1): full_pel_rd halves the predictor into full-pel units
         * before the delta add (see the comment at full_pel_rd above). */
        case (motion_vector)
          MOTION_VECTOR_0_0_0: pmv_0 <= full_pel_rd ? pmv_0_0_0 >>> 1 : pmv_0_0_0;
          MOTION_VECTOR_0_0_1: pmv_0 <= (shift_pmv || full_pel_rd) ? pmv_0_0_1 >>> 1 : pmv_0_0_1;
          MOTION_VECTOR_1_0_0: pmv_0 <= full_pel_rd ? pmv_1_0_0 >>> 1 : pmv_1_0_0;
          MOTION_VECTOR_1_0_1: pmv_0 <= (shift_pmv || full_pel_rd) ? pmv_1_0_1 >>> 1 : pmv_1_0_1;
          MOTION_VECTOR_0_1_0: pmv_0 <= full_pel_rd ? pmv_0_1_0 >>> 1 : pmv_0_1_0;
          MOTION_VECTOR_0_1_1: pmv_0 <= (shift_pmv || full_pel_rd) ? pmv_0_1_1 >>> 1 : pmv_0_1_1;
          MOTION_VECTOR_1_1_0: pmv_0 <= full_pel_rd ? pmv_1_1_0 >>> 1 : pmv_1_1_0;
          MOTION_VECTOR_1_1_1: pmv_0 <= (shift_pmv || full_pel_rd) ? pmv_1_1_1 >>> 1 : pmv_1_1_1;
          default              pmv_0 <= 13'b0;
        endcase
        /* stage 2 */
        pmv_1 <= motion_code_neg_0 ? pmv_0 - pmv_delta_0 : pmv_0 + pmv_delta_0;
        /*
         * stage 3
         * next case statement ought to be equivalent to:
         * pmv <= (pmv < low) ? (pmv + range) : ((pmv > high) ? (pmv - range) : pmv);
         *
         * As f_code_ is restricted to the range 1..9, (Table E-8, High Level)
         * r_size is restricted to the range 0..8. 
         */
        case (r_size_1)
          4'd0:   pmv_2 <= { {9{pmv_1[4]}},  pmv_1[3:0]  };
          4'd1:   pmv_2 <= { {8{pmv_1[5]}},  pmv_1[4:0]  };
          4'd2:   pmv_2 <= { {7{pmv_1[6]}},  pmv_1[5:0]  };
          4'd3:   pmv_2 <= { {6{pmv_1[7]}},  pmv_1[6:0]  };
          4'd4:   pmv_2 <= { {5{pmv_1[8]}},  pmv_1[7:0]  };
          4'd5:   pmv_2 <= { {4{pmv_1[9]}},  pmv_1[8:0]  };
          4'd6:   pmv_2 <= { {3{pmv_1[10]}}, pmv_1[9:0]  };
          4'd7:   pmv_2 <= { {2{pmv_1[11]}}, pmv_1[10:0] };
          4'd8:   pmv_2 <= { {1{pmv_1[12]}}, pmv_1[11:0] };
          default pmv_2 <=                   pmv_1[12:0]  ; // never occurs
        endcase
	/*
	 * stage 4..5: dmv calculations only
	 */
	pmv_3 <= pmv_2;
	pmv_4 <= pmv_3;
	pmv_5 <= pmv_4;
      end
    else 
      begin
        pmv_0 <= pmv_0;
        pmv_1 <= pmv_1;
        pmv_2 <= pmv_2;
        pmv_3 <= pmv_3;
        pmv_4 <= pmv_4;
        pmv_5 <= pmv_5;
      end

  /*
   * predicted motion vectors. 
   * pmv_reset is asserted when the motion vectors are reset to zero;
   * pmv_update0 is asserted when pmv_1_0_x <= pmv_0_0_x
   * pmv_update1 is asserted when pmv_1_1_x <= pmv_0_1_x
   */
  always @(posedge clk)  
    if (~rst) pmv_0_0_0 <= 13'b0;
    else if (clk_en && pmv_reset) pmv_0_0_0 <= 13'b0;
    else if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_0_0_0)) pmv_0_0_0 <= full_pel_wr ? pmv_5 <<< 1 : pmv_5; // DVD-FORK FIX (mpeg1): full-pel store = vec<<1
    else pmv_0_0_0 <= pmv_0_0_0;

  always @(posedge clk)  
    if (~rst) pmv_0_0_1 <= 13'b0;
    else if (clk_en && pmv_reset) pmv_0_0_1 <= 13'b0;
    else if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_0_0_1)) pmv_0_0_1 <= (shift_pmv || full_pel_wr) ? pmv_5 <<< 1 : pmv_5; // DVD-FORK FIX (mpeg1): full-pel store = vec<<1
    else pmv_0_0_1 <= pmv_0_0_1;

  always @(posedge clk)  
    if (~rst) pmv_1_0_0 <= 13'b0;
    else if (clk_en && pmv_reset) pmv_1_0_0 <= 13'b0;
    else if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_1_0_0)) pmv_1_0_0 <= full_pel_wr ? pmv_5 <<< 1 : pmv_5; // DVD-FORK FIX (mpeg1)
    else if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_0_0_0) && pmv_update0) pmv_1_0_0 <= full_pel_wr ? pmv_5 <<< 1 : pmv_5; // DVD-FORK FIX (mpeg1)
    else pmv_1_0_0 <= pmv_1_0_0;

  always @(posedge clk)  
    if (~rst) pmv_1_0_1 <= 13'b0;
    else if (clk_en && pmv_reset) pmv_1_0_1 <= 13'b0;
    else if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_1_0_1)) pmv_1_0_1 <= (shift_pmv || full_pel_wr) ? pmv_5 <<< 1 : pmv_5; // DVD-FORK FIX (mpeg1)
    else if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_0_0_1) && pmv_update0) pmv_1_0_1 <= (shift_pmv || full_pel_wr) ? pmv_5 <<< 1 : pmv_5; // DVD-FORK FIX (mpeg1)
    else pmv_1_0_1 <= pmv_1_0_1;

  always @(posedge clk)  
    if (~rst) pmv_0_1_0 <= 13'b0;
    else if (clk_en && pmv_reset) pmv_0_1_0 <= 13'b0;
    else if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_0_1_0)) pmv_0_1_0 <= full_pel_wr ? pmv_5 <<< 1 : pmv_5; // DVD-FORK FIX (mpeg1)
    else pmv_0_1_0 <= pmv_0_1_0;

  always @(posedge clk)  
    if (~rst) pmv_0_1_1 <= 13'b0;
    else if (clk_en && pmv_reset) pmv_0_1_1 <= 13'b0;
    else if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_0_1_1)) pmv_0_1_1 <= (shift_pmv || full_pel_wr) ? pmv_5 <<< 1 : pmv_5; // DVD-FORK FIX (mpeg1)
    else pmv_0_1_1 <= pmv_0_1_1;

  always @(posedge clk)  
    if (~rst) pmv_1_1_0 <= 13'b0;
    else if (clk_en && pmv_reset) pmv_1_1_0 <= 13'b0;
    else if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_1_1_0)) pmv_1_1_0 <= full_pel_wr ? pmv_5 <<< 1 : pmv_5; // DVD-FORK FIX (mpeg1)
    else if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_0_1_0) && pmv_update1) pmv_1_1_0 <= full_pel_wr ? pmv_5 <<< 1 : pmv_5; // DVD-FORK FIX (mpeg1)
    else pmv_1_1_0 <= pmv_1_1_0;

  always @(posedge clk)  
    if (~rst) pmv_1_1_1 <= 13'b0;
    else if (clk_en && pmv_reset) pmv_1_1_1 <= 13'b0;
    else if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_1_1_1)) pmv_1_1_1 <= (shift_pmv || full_pel_wr) ? pmv_5 <<< 1 : pmv_5; // DVD-FORK FIX (mpeg1)
    else if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_0_1_1) && pmv_update1) pmv_1_1_1 <= (shift_pmv || full_pel_wr) ? pmv_5 <<< 1 : pmv_5; // DVD-FORK FIX (mpeg1)
    else pmv_1_1_1 <= pmv_1_1_1;

  /* motion vector field select */
  output reg       motion_vert_field_select_0_0; // motion_vertical_field_select. Indicates which reference field shall be used to form the prediction. 
                                                 // If motion_vertical_field_select[r][s] is zero, then the top reference field shall be used, 
                                                 // if it is one then the bottom reference field shall be used.
  output reg       motion_vert_field_select_0_1;
  output reg       motion_vert_field_select_1_0;
  output reg       motion_vert_field_select_1_1;

  always @(posedge clk)  
    if (~rst) motion_vert_field_select_0_0 <= 1'b0;
    else if (clk_en && (state == STATE_PICTURE_HEADER)) motion_vert_field_select_0_0 <= 1'b0; // I take the liberty of resetting at the start of a picture
    else if (clk_en && (state == STATE_MACROBLOCK_SKIP) && (picture_structure != FRAME_PICTURE)) motion_vert_field_select_0_0 <= (picture_structure==BOTTOM_FIELD); // par. 7.6.6.1 and 7.6.6.3, skipped macroblocks. predict from field of same parity.
    else if (clk_en && (state == STATE_MACROBLOCK_QUANT) && (picture_coding_type == P_TYPE) && ~macroblock_intra && ~macroblock_motion_forward && (picture_structure != FRAME_PICTURE)) motion_vert_field_select_0_0 <= (picture_structure==BOTTOM_FIELD); // par. 7.6.3.5 Prediction in P pictures. non-intra mb without forward mv in a P picture. 
    else if (clk_en && (state == STATE_MOTION_VERT_FLD_SEL) && (motion_vector == MOTION_VECTOR_0_0_0)) motion_vert_field_select_0_0 <= getbits[23];
    else motion_vert_field_select_0_0 <= motion_vert_field_select_0_0;

  always @(posedge clk)  
    if (~rst) motion_vert_field_select_0_1 <= 1'b0;
    else if (clk_en && (state == STATE_PICTURE_HEADER)) motion_vert_field_select_0_1 <= 1'b0;
    else if (clk_en && (state == STATE_MACROBLOCK_SKIP) && (picture_structure != FRAME_PICTURE)) motion_vert_field_select_0_1 <= (picture_structure==BOTTOM_FIELD); // par. 7.6.6.1 and 7.6.6.3, skipped macroblocks. predict from field of same parity.
    else if (clk_en && (state == STATE_MOTION_VERT_FLD_SEL) && (motion_vector == MOTION_VECTOR_0_1_0)) motion_vert_field_select_0_1 <= getbits[23];
    else motion_vert_field_select_0_1 <= motion_vert_field_select_0_1;

  always @(posedge clk)  
    if (~rst) motion_vert_field_select_1_0 <= 1'b0;
    else if (clk_en && (state == STATE_PICTURE_HEADER)) motion_vert_field_select_1_0 <= 1'b0;
    else if (clk_en && (state == STATE_MOTION_VERT_FLD_SEL) && (motion_vector == MOTION_VECTOR_1_0_0)) motion_vert_field_select_1_0 <= getbits[23];
    else if (clk_en && (state == STATE_MOTION_VERT_FLD_SEL) && motion_vector_count_is_one && (mv_format == MV_FIELD) && ~dmv && (motion_vector == MOTION_VECTOR_0_0_0)) motion_vert_field_select_1_0 <= getbits[23]; // case of only one motion vector
    else motion_vert_field_select_1_0 <= motion_vert_field_select_1_0;

  always @(posedge clk)  
    if (~rst) motion_vert_field_select_1_1 <= 1'b0;
    else if (clk_en && (state == STATE_PICTURE_HEADER)) motion_vert_field_select_1_1 <= 1'b0;
    else if (clk_en && (state == STATE_MOTION_VERT_FLD_SEL) && (motion_vector == MOTION_VECTOR_1_1_0)) motion_vert_field_select_1_1 <= getbits[23];
    else if (clk_en && (state == STATE_MOTION_VERT_FLD_SEL) && motion_vector_count_is_one && (mv_format == MV_FIELD) && ~dmv && (motion_vector == MOTION_VECTOR_0_1_0)) motion_vert_field_select_1_1 <= getbits[23]; // case of only one motion vector
    else motion_vert_field_select_1_1 <= motion_vert_field_select_1_1;

  /* additional dual-prime arithmetic, par. 7.6.3.6 */
  always @(posedge clk)  
    if (~rst) 
      begin
        dmvector_0 <= 2'b0; 
        dmvector_1 <= 2'b0;
        dmvector_2 <= 2'b0;
        dmvector_3 <= 2'b0;
      end
    else if (clk_en)
      begin
        dmvector_0 <= dmvector;
        dmvector_1 <= dmvector_0;
        dmvector_2 <= dmvector_1;
        dmvector_3 <= dmvector_2;
      end
    else 
      begin
        dmvector_0 <= dmvector_0;
        dmvector_1 <= dmvector_1;
        dmvector_2 <= dmvector_2;
        dmvector_3 <= dmvector_3;
      end

  wire pmv_2_pos = (~pmv_2[12] && (pmv_2 != 13'b0)); // asserted if pmv_2 > 0
  wire top_field_at_bottom = (picture_structure==FRAME_PICTURE) && (~top_field_first);

  reg signed [1:0] e_parity_ref_parity_pred_4;
  reg signed [12:0]dmvector_aux_a_3;
  reg signed [12:0]dmvector_aux_b_3;
  reg signed [12:0]dmvector_aux_a_4;
  reg signed [12:0]dmvector_aux_b_4;
  reg signed [12:0]dmvector_aux_a_5;
  reg signed [12:0]dmvector_aux_b_5;

  always @(posedge clk)
    if (~rst) e_parity_ref_parity_pred_4 <= 2'd0;
    else if (clk_en && (motion_vector_3 == MOTION_VECTOR_0_0_0)) e_parity_ref_parity_pred_4 <= 2'd0;
    else if (clk_en && (motion_vector_3 == MOTION_VECTOR_0_0_1)) e_parity_ref_parity_pred_4 <= ((picture_structure==FRAME_PICTURE) || (picture_structure==TOP_FIELD)) ? -2'd1 : 2'd1;
    else e_parity_ref_parity_pred_4 <= e_parity_ref_parity_pred_4;

  always @(posedge clk)
    if (~rst)
      begin
        dmvector_aux_a_3 <= 13'd0;
        dmvector_aux_a_4 <= 13'd0;
        dmvector_aux_a_5 <= 13'd0;
      end
    else if (clk_en)
      begin
        dmvector_aux_a_3 <= pmv_2 + pmv_2_pos;
        dmvector_aux_a_4 <= {dmvector_aux_a_3[12], dmvector_aux_a_3[12:1]} + { {12{dmvector_3[1]}}, dmvector_3[0] }; // sign-extend dmvector before adding
        dmvector_aux_a_5 <= (top_field_at_bottom ? dmvector_aux_b_4 : dmvector_aux_a_4) + { {12{e_parity_ref_parity_pred_4[1]}}, e_parity_ref_parity_pred_4[0] }; // sign-extend e_parity_ref_parity_pred before adding
      end
    else 
      begin
        dmvector_aux_a_3 <= dmvector_aux_a_3;
        dmvector_aux_a_4 <= dmvector_aux_a_4;
        dmvector_aux_a_5 <= dmvector_aux_a_5;
      end

  always @(posedge clk)
    if (~rst)
      begin
        dmvector_aux_b_3 <= 13'd0;
        dmvector_aux_b_4 <= 13'd0;
        dmvector_aux_b_5 <= 13'd0;
      end
    else if (clk_en)
      begin
        dmvector_aux_b_3 <= (pmv_2 <<< 1) + pmv_2 + pmv_2_pos;
        dmvector_aux_b_4 <= {dmvector_aux_b_3[12], dmvector_aux_b_3[12:1]} + { {12{dmvector_3[1]}}, dmvector_3[0] }; // sign-extend dmvector before adding
        dmvector_aux_b_5 <= (top_field_at_bottom ? dmvector_aux_a_4 : dmvector_aux_b_4) - { {12{e_parity_ref_parity_pred_4[1]}}, e_parity_ref_parity_pred_4[0] }; // sign-extend e_parity_ref_parity_pred before adding
      end
    else 
      begin
        dmvector_aux_b_3 <= dmvector_aux_b_3;
        dmvector_aux_b_4 <= dmvector_aux_b_4;
        dmvector_aux_b_5 <= dmvector_aux_b_5;
      end

  always @(posedge clk)
    if (~rst) dmv_0_0 <= 13'd0;
    else if (clk_en && (motion_vector_valid_5) && dmv && (motion_vector_5 == MOTION_VECTOR_0_0_0)) dmv_0_0 <= dmvector_aux_a_5;
    else dmv_0_0 <= dmv_0_0;

  always @(posedge clk)
    if (~rst) dmv_1_0 <= 13'd0;
    else if (clk_en && (motion_vector_valid_5) && dmv && (motion_vector_5 == MOTION_VECTOR_0_0_0)) dmv_1_0 <= dmvector_aux_b_5;
    else dmv_1_0 <= dmv_1_0;

  always @(posedge clk)
    if (~rst) dmv_0_1 <= 13'd0;
    else if (clk_en && (motion_vector_valid_5) && dmv && (motion_vector_5 == MOTION_VECTOR_0_0_1)) dmv_0_1 <= dmvector_aux_a_5;
    else dmv_0_1 <= dmv_0_1;

  always @(posedge clk)
    if (~rst) dmv_1_1 <= 13'd0;
    else if (clk_en && (motion_vector_valid_5) && dmv && (motion_vector_5 == MOTION_VECTOR_0_0_1)) dmv_1_1 <= dmvector_aux_b_5;
    else dmv_1_1 <= dmv_1_1;

  /* motion vector output */
  always @(posedge clk)  
    if (~rst) motion_vector_valid <= 1'b0;
    /*
     * par. 7.6.6: Skipped macroblocks. 
     * In a P picture the motion vector shall be zero;
     * in a B picture the motion vectors are taken from the appropriate motion vector predictors. 
     *
     * Here:
     * - motion vectors of skipped macroblocks are reset (for P pictures) during STATE_MACROBLOCK_SKIP and valid the state after STATE_MACROBLOCK_SKIP
     * - motion vectors of non-skipped macroblocks are computed during STATE_NEXT_MOTION_VECTOR .. STATE_MOTION_PIPELINE_FLUSH. The
     *   motion vectors are valid after STATE_MOTION_PIPELINE_FLUSH, and, by extension, at STATE_BLOCK.
     */
    else if (clk_en) motion_vector_valid <= (state == STATE_MACROBLOCK_SKIP) || (state == STATE_BLOCK); 
    else motion_vector_valid <= 1'b0;

  /* second field */
  /* second_field DECLARED early (near the drop ports) — the field-pair drop's
   * drop_now_comb reads it and iverilog requires declaration before use. */
  always @(posedge clk)
    if (~rst) second_field <= 1'b0;
    else if (clk_en && ((state == STATE_SEQUENCE_HEADER) || (state == STATE_GROUP_HEADER))) second_field <= 1'b1;
    else if (clk_en && (state == STATE_PICTURE_HEADER) && (picture_structure == FRAME_PICTURE)) second_field <= 1'b0; /* recover from illegal number of field pictures, if necessary */
    else if (clk_en && (state == STATE_PICTURE_HEADER)) second_field <= ~second_field; /* field picture */
    else second_field <= second_field;

  /*
     tell motion compensation to switch picture buffers.
     If frame picture, switch picture buffers every picture header.
     If field picture, switch picture buffers every other picture header. 
     (Field pictures use two picture headers, one for each field)
   */
  output reg       update_picture_buffers;
  output reg       last_frame;

  // DVD-FORK (frame-drop governor, O[19]): when dropping this B-frame, SUPPRESS its
  // update_picture_buffers so motcomp/picbuf never freeze the VLD for it, never rotate
  // for it (B never rotates anyway), and never set it up to be reconstructed/emitted.
  // The dropped B becomes fully invisible downstream; the next I/P picture's update
  // proceeds normally.
  // DVD-FORK FIX (mpeg1): an MPEG-1 D-picture's slices are skipped (skip_d_picture),
  // so its update must be suppressed like a dropped B's — it must not rotate/freeze
  // picbuf for a picture that never delivers data. Combinational off the same getbits
  // field the drop test reads (the loadreg only latches this cycle).
  wire hdr_is_d_m1 = mpeg1 && (getbits[13:11] == D_TYPE);
  always @(posedge clk)
    if (~rst) update_picture_buffers <= 1'b0;
    else if (clk_en) update_picture_buffers <= ((state == STATE_PICTURE_HEADER) && ((picture_structure == FRAME_PICTURE) || second_field) && ~drop_now_comb && ~hdr_is_d_m1) // emit frame at picture header
                                               || ((state == STATE_SEQUENCE_END) && ~last_frame); // emit last frame
    else update_picture_buffers <= 1'b0;

  /* DVD-FORK (frame-drop governor, O[19]): drop bookkeeping.
   * drop_this_picture is (re)evaluated at every picture header: set when this is a
   * droppable frame-picture B and the governor is behind (drop_now_comb), else cleared.
   * It persists through the picture so the slice-routing gate bypasses every slice, and
   * is naturally re-armed at the next picture header.
   *
   * drop_pic_ack (REVISED 2026-07-03, film-aware drop COST — the Shea-Stadium
   * over-advance): the ack used to pulse at the PICTURE HEADER and frame_drop_ctl
   * debited the governor's on-display cur_show as a proxy for the dropped frame's
   * display duration. HW (MiB crash sequence, OSD recording): a heavy-drop burst
   * left video ~900 ms AHEAD with audio provably still on schedule (play_err flat
   * to the LSB) — the crush drops correlate with the rff phase (+268 lates vs
   * +103 drops balancing at cost ~2.6 while the dropped frames' true durations
   * averaged ~3.0), leaking ~+0.5 refresh of unaccounted timeline advance per
   * drop. Fix: pulse the ack at the FIRST SKIPPED SLICE — by then THIS picture's
   * coding extension has parsed, so repeat_first_field holds the DROPPED
   * picture's own flag — and export it (drop_pic_rff) so the ledger debits the
   * dropped frame's own would-be duration, exactly cancelling the content-time
   * the drop skips. A dropped picture with no slices never acks (nothing was
   * skipped that would have displayed). */
  always @(posedge clk)
    if (~rst) drop_this_picture <= 1'b0;
    else if (clk_en && (state == STATE_PICTURE_HEADER)) drop_this_picture <= drop_now_comb;
    else drop_this_picture <= drop_this_picture;

  wire drop_slice_hit = (state == STATE_START_CODE) && drop_this_picture &&
                        (getbits[7:0] >= 8'h01) && (getbits[7:0] <= 8'haf);
  (* preserve *) reg drop_acked;   // one ack per dropped picture (many slices are skipped); preserved per the drop_now_comb hardening note

  /* DVD-FORK FIX (round 10, the drop-debit leak): dedicated, synthesis-
   * preserved capture of the current picture's repeat_first_field for the
   * drop export. On HW (DVD_drift6 overlay row-16 read) the ack exported
   * rff=0 for ~90-100% of drops while the dropped pictures are provably rff
   * (their true display durations measure ~3.0 from the recording) and the
   * IDENTICAL RTL is 43/43 faithful in simulation (vld_drop_rff_tb over a
   * real MiB ES) — i.e. the shared `repeat_first_field` loadreg's value did
   * not reach this export intact in the BUILD. That register fans out to
   * picbuf/resample (where it provably works — the 3:2 cadence is HW-good)
   * and physical synthesis is enabled, making it a retime/duplicate
   * candidate; a mangled private copy is the same failure class as the
   * synth-narrowed disp_y==0 compare (docs/history.md). This register is
   * private to the drop path, samples the SAME bit the loadreg samples
   * (getbits[13] at STATE_PICTURE_CODING_EXT0, offset 10 of the extension
   * word), and is marked (* preserve *) so the fitter may not retime, merge
   * or duplicate it. Verified sim-equivalent by vld_drop_rff_tb. */
  (* preserve *) reg drop_rff_lat;
  always @(posedge clk)
    if (~rst) drop_rff_lat <= 1'b0;
    else if (clk_en && (state == STATE_PICTURE_CODING_EXT0)) drop_rff_lat <= getbits[13];
    else if (clk_en && mpeg1 && (state == STATE_PICTURE_HEADER)) drop_rff_lat <= 1'b0; // DVD-FORK FIX (mpeg1): no coding ext — rff is 0 for every MPEG-1 picture
    else drop_rff_lat <= drop_rff_lat;

  /* DVD-FORK FIX (round 11, 2026-07-04 — THE STALE DISPLAY FLAGS, the real
   * lip-sync engine): update_picture_buffers fires right after
   * STATE_PICTURE_HEADER, and motcomp_picbuf saves the per-picture display
   * flags (repeat_first_field / top_field_first / progressive_frame) on that
   * pulse — but those fields parse ~10 states LATER in the picture CODING
   * EXTENSION, so every picture's saved flags are the PREVIOUS coded
   * picture's. On clean 3:2 film the display-order flag sequence is then
   * merely phase-shifted (still alternating — the cadence looks perfect,
   * which is why this survived the film-3:2 HW confirmation), and the ±1
   * refresh per-frame error is zero-mean. FRAME DROPS break the pairing:
   * the governor's debit reclaims the dropped frame's OWN duration (the ack
   * path samples post-extension — the one consumer that reads fresh) while
   * the display timeline actually freed the STALE duration; the drop
   * selection is cadence-phase-locked (HW rows 16: ~90 % own-rff=0 drops,
   * whose stale predecessor flag is 1), so each drop leaks ~+1 refresh of
   * video lead — the measured ~+3 % video-fast ramp that burns the VBUF and
   * parks lips ~0.9 s audio-behind (drift6a/drift7a; behavioral sim
   * reproduces the ratio 2.00 and the sign/magnitude).
   * FIX: pulse flags_commit at the coding extension so picbuf RE-LATCHES the
   * three per-picture flags for the CURRENT picture (its update pulse has
   * already selected the slot; emission happens at the NEXT picture's update,
   * long after). Gated off for dropped pictures — their extension still
   * parses, but they own no picbuf slot and must not clobber the current
   * picture's committed flags. */
  output reg flags_commit;
  /* DVD-FORK FIX (mpeg1): MPEG-1 has no picture coding extension, so the MPEG-2 pulse
   * below would never fire and picbuf would display STALE flags forever (the round-11
   * bug all over again). Pulse at the SLICE header instead: STATE_SLICE is (a)
   * strictly after picbuf's STATE_UPDATE for this picture (the vld freezes at the
   * header until picbuf has processed the update), and (b) never reached for dropped
   * pictures or skipped D-pictures (their slice start codes route to
   * STATE_NEXT_START_CODE) — so the "never for dropped pictures" gating comes
   * structurally, mirroring the ~drop_this_picture term of the MPEG-2 arm. Re-pulsing
   * on every slice of the picture is idempotent: the committed values are the MPEG-1
   * constants progressive_frame=1 / tff=0 / rff=0 from the mpeg1 default muxes. */
  always @(posedge clk)
    if (~rst) flags_commit <= 1'b0;
    else if (clk_en) flags_commit <= mpeg1 ? (state == STATE_SLICE)
                                           : ((state == STATE_PICTURE_CODING_EXT0) && ~drop_this_picture);
    else flags_commit <= 1'b0;

  /* DVD-FORK (film evidence gate, 2026-08-30) — see docs/film_24p_plan.md §14.
   *
   * progressive_frame is NOT a measurement. It is one bit the ENCODER chose to
   * write into the picture coding extension, and on a near-black picture there
   * is no field structure to analyse, so the encoder takes the MPEG-2 default
   * and marks it interlaced — mismarking progressive costs visible artifacts,
   * mismarking interlaced costs a few bytes of disc space. The film detector in
   * dvd/resample_addrgen.v then counts that meaningless flag at full weight
   * (DN_HARD=8) and falls out of film lock. Measured on APOLLO_13: NINE raster
   * changes inside the first 46 s of the main title, every one of them driven
   * by the credits fading through black.
   *
   * VLC's IVTC survives the same clip because it reads PIXELS and explicitly
   * discards uninformative frames as evidence — "If no motion, the result from
   * this algorithm cannot be reliable". We cannot see pixels at the display
   * pickup, but we can see how many bits the encoder spent, and that separates
   * the cases cleanly: APOLLO_13's black pictures code 384 B against that
   * title's own 17,704 B median.
   *
   * ★ THE COMPARISON MUST BE RELATIVE, NOT A BYTE CONSTANT. HIGH_SCHOOL_MUSICAL
   * codes a 318 B MEDIAN — there, small pictures ARE the content, and a fixed
   * threshold discards 55 % of the disc and delays its video verdict by 17 s.
   * The core also plays VCD/SVCD, where the whole scale shifts again. So the
   * reference is a running mean PER PICTURE CODING TYPE: a black I-frame codes
   * 7,580 B where a real one codes ~82,000 B — tiny for an I, yet larger than
   * any threshold that does not also swallow legitimate B-frames.
   *
   * ★ THE WARM-UP IS LOAD-BEARING, not a detail. Seeding the mean from whichever
   * picture happened to arrive first made two rips of near-identical content
   * (same median, same p10, same p90) gate 0.0 % and 85.8 %. For the first
   * EV_WARM pictures of a coding type nothing is gated and the mean tracks every
   * picture, so it converges on what THIS stream looks like; after that it
   * tracks ACCEPTED pictures only, so a long fade cannot walk the reference down
   * to meet itself and start trusting black frames again.
   *
   * ★ ORDERING — why this cannot ride flags_commit. A picture's size is only
   * known when it ENDS, whereas flags_commit fires at the coding extension near
   * its START. informative_commit fires instead at STATE_START_CODE for the code
   * that TERMINATES the picture, which is strictly before the next picture's
   * STATE_PICTURE_HEADER and therefore before picbuf rotates slots
   * (update_picture_buffers fires at that header, and the vld then freezes until
   * picbuf has processed it). Same slot, later write.
   *
   * Dropped pictures are excluded from both the commit and the mean: they own no
   * picbuf slot (so a commit would clobber the displayed picture's verdict) and
   * their slices are walked rather than decoded, so their size is not evidence.
   *
   * MPEG-1 needs no special case — this keys on picture start codes, not on the
   * coding extension MPEG-1 lacks.
   *
   * Defaults are legacy-identical: pic_informative resets to 1, so until a
   * verdict is committed every picture counts exactly as it does today. */
  output reg        pic_informative;    // this picture carried real evidence
  output reg        informative_commit; // pic_informative valid for the current picbuf slot

  /* parameter, not localparam, so a testbench can arm the gate on a short ES cut
   * instead of needing 16 pictures of every coding type before it does anything. */
  parameter   [4:0] EV_WARM   = 5'd16;  // pictures per coding type before the gate arms
  localparam        EV_ASHIFT = 4;      // running-mean time constant (1/16 per picture)
  localparam        EV_GSHIFT = 3;      // uninformative below mean/8
  localparam [21:0] EV_SAT    = 22'h3FFF00;

  reg        [21:0] pic_bits;           // bits consumed by the picture being measured
  reg        [21:0] ev_mean [0:3];      // running mean, indexed by picture_coding_type
  reg         [4:0] ev_warm [0:3];      // warm-up count, same index
  reg               pic_active;         // between a picture header and its terminator

  /* Direct array expressions, NOT a function-mediated read: a read behind a
   * function loses array sensitivity and goes stale (the dvd_vm gprm[] lesson). */
  wire        [1:0] ev_ct   = picture_coding_type[1:0];   // 1=I, 2=P, 3=B, 0=D
  wire       [21:0] ev_m    = ev_mean[ev_ct];
  wire        [4:0] ev_n    = ev_warm[ev_ct];
  wire              ev_hot  = (ev_n >= EV_WARM);
  wire              ev_ok   = ~ev_hot || (pic_bits >= (ev_m >> EV_GSHIFT));
  wire       [21:0] ev_next = ev_m - (ev_m >> EV_ASHIFT) + (pic_bits >> EV_ASHIFT);

  /* Bits the bitstream cursor moves this clock, mirroring getbits_fifo's own
   * next_cursor logic: align byte-aligns and steps one byte, else advance bits. */
  wire        [5:0] ev_step = align ? 6'd8 : {1'b0, advance};

  wire              pic_ends = (state == STATE_START_CODE) &&
                               ((getbits[7:0] == CODE_PICTURE_START)   ||
                                (getbits[7:0] == CODE_GROUP_START)     ||
                                (getbits[7:0] == CODE_SEQUENCE_HEADER) ||
                                (getbits[7:0] == CODE_SEQUENCE_END));

  integer ev_i;
  always @(posedge clk)
    if (~rst)
      begin
        pic_bits           <= 22'd0;
        pic_active         <= 1'b0;
        pic_informative    <= 1'b1;      // legacy default: everything counts
        informative_commit <= 1'b0;
        for (ev_i = 0; ev_i < 4; ev_i = ev_i + 1)
          begin
            ev_mean[ev_i] <= 22'd0;
            ev_warm[ev_i] <= 5'd0;
          end
      end
    else if (clk_en)
      begin
        informative_commit <= 1'b0;

        if (pic_active && (pic_bits < EV_SAT))
          pic_bits <= pic_bits + {16'd0, ev_step};

        if (state == STATE_PICTURE_HEADER)
          begin                          // a new picture: start measuring it
            pic_bits   <= 22'd0;
            pic_active <= 1'b1;
          end
        else if (pic_ends && pic_active)
          begin
            pic_active <= 1'b0;
            if (~drop_this_picture)
              begin
                pic_informative    <= ev_ok;
                informative_commit <= 1'b1;
                if (~ev_hot)      ev_warm[ev_ct] <= ev_n + 5'd1;
                if (ev_n == 5'd0) ev_mean[ev_ct] <= pic_bits;   // first of its type
                else if (~ev_hot || ev_ok)
                                  ev_mean[ev_ct] <= ev_next;
              end
          end
      end
    else
      informative_commit <= 1'b0;

  always @(posedge clk)
    if (~rst) begin
      drop_pic_ack <= 1'b0;
      drop_pic_rff <= 1'b0;
      drop_pic_field <= 1'b0;
      drop_acked   <= 1'b0;
    end else if (clk_en) begin
      if (state == STATE_PICTURE_HEADER) drop_acked <= 1'b0;   // new picture: re-arm
      drop_pic_ack <= drop_slice_hit && ~drop_acked;
      if (drop_slice_hit && ~drop_acked) begin
        drop_acked   <= 1'b1;
        drop_pic_rff <= drop_rff_lat;   // the DROPPED picture's rff (private preserved copy)
        // the DROPPED picture's own structure (its coding ext has parsed by the
        // first slice): field -> the cost/credit muxes debit 1 refresh per field.
        drop_pic_field <= (drop_ps_lat == 2'd1) || (drop_ps_lat == 2'd2);
      end
    end else drop_pic_ack <= 1'b0;

  /*
    We're at video end, tell motion compensation to emit the last frame.
   */

  always @(posedge clk)
    if (~rst) last_frame <= 1'b0;
    else if (clk_en && (state == STATE_SEQUENCE_END)) last_frame <= 1'b1; // end of this video bitstream
    else if (clk_en && ((state == STATE_SEQUENCE_HEADER) || (state == STATE_PICTURE_HEADER))) last_frame <= 1'b0; // start of new video bitstream
    else last_frame <= last_frame;

  /* dct_dc_size_luminance, dct_dc_size_chrominance and dct_dc_differential (par. 7.2.1) */

  always @(posedge clk)
    if (~rst) dct_dc_size <= 4'b0;
    else if (clk_en && (state == STATE_DCT_DC_LUMI_SIZE)) dct_dc_size <= dct_dc_size_luminance_value;     // table B-12 lookup
    else if (clk_en && (state == STATE_DCT_DC_CHROMI_SIZE)) dct_dc_size <= dct_dc_size_chrominance_value; // table B-13 lookup
    else dct_dc_size <= dct_dc_size;

  reg [10:0]dct_dc_pred_add;
  always @*
      case (dct_dc_size)
        4'd1:   dct_dc_pred_add = getbits[23];
        4'd2:   dct_dc_pred_add = getbits[23:22];
        4'd3:   dct_dc_pred_add = getbits[23:21];
        4'd4:   dct_dc_pred_add = getbits[23:20];
        4'd5:   dct_dc_pred_add = getbits[23:19];
        4'd6:   dct_dc_pred_add = getbits[23:18];
        4'd7:   dct_dc_pred_add = getbits[23:17];
        4'd8:   dct_dc_pred_add = getbits[23:16];
        4'd9:   dct_dc_pred_add = getbits[23:15];
        4'd10:  dct_dc_pred_add = getbits[23:14];
        4'd11:  dct_dc_pred_add = getbits[23:13];
        default dct_dc_pred_add = 11'd0; // error: maximum in table B-12 and B-13 is 11
      endcase

  reg [10:0]dct_dc_pred_sub;
  always @*
      case (dct_dc_size)
        4'd1:   dct_dc_pred_sub = 11'b1;
        4'd2:   dct_dc_pred_sub = 11'b11;
        4'd3:   dct_dc_pred_sub = 11'b111;
        4'd4:   dct_dc_pred_sub = 11'b1111;
        4'd5:   dct_dc_pred_sub = 11'b11111;
        4'd6:   dct_dc_pred_sub = 11'b111111;
        4'd7:   dct_dc_pred_sub = 11'b1111111;
        4'd8:   dct_dc_pred_sub = 11'b11111111;
        4'd9:   dct_dc_pred_sub = 11'b111111111;
        4'd10:  dct_dc_pred_sub = 11'b1111111111;
        4'd11:  dct_dc_pred_sub = 11'b11111111111;
        default dct_dc_pred_sub = 11'd0; // error: maximum in table B-12 and B-13 is 11
      endcase

  always @(posedge clk)
    if (~rst) dct_dc_pred <= 11'b0;
    else if (clk_en && (state == STATE_DCT_DC_LUMI_SIZE))                             dct_dc_pred <= dct_dc_pred_0; // Y block
    else if (clk_en && (state == STATE_DCT_DC_CHROMI_SIZE) && block_chromi1_code[12]) dct_dc_pred <= dct_dc_pred_1; // Cb block
    else if (clk_en && (state == STATE_DCT_DC_CHROMI_SIZE) && block_chromi2_code[12]) dct_dc_pred <= dct_dc_pred_2; // Cr block
    else if (clk_en && (state == STATE_DCT_DC_DIFF))
      begin
        if (dct_dc_size == 4'd0) dct_dc_pred <=  dct_dc_pred;
        else if (getbits[23] == 1'b0) dct_dc_pred <= dct_dc_pred + dct_dc_pred_add - dct_dc_pred_sub;
        else dct_dc_pred <= dct_dc_pred + dct_dc_pred_add;
      end
    else dct_dc_pred <= dct_dc_pred;

  // luminance (Y) dct dc predictor
  always @(posedge clk)
    if (~rst) dct_dc_pred_0 <= 11'b0;
    else if (clk_en && ((state == STATE_SLICE) ||  // at the start of a slice (par. 7.2.1)
                        ((state == STATE_BLOCK) && ~macroblock_intra) || // whenever a non-intra macroblock is decoded (par. 7.2.1.)
                        (state == STATE_MACROBLOCK_SKIP) )) // whenever a macroblock is skipped, i.e. when macroblock_address_increment > 1
                        dct_dc_pred_0 <= 11'b0; // the mpeg2 reference implementation (mpeg2decode) does not reset dct_dc_pred[i] to 11'd128 << intra_dc_precision; rather it adds 128 to the reconstructed output.
    else if (clk_en && (state == STATE_DCT_DC_DIFF_0) && block_lumi_code[12]) dct_dc_pred_0 <= dct_dc_pred;
    else dct_dc_pred_0 <= dct_dc_pred_0;

  // first chrominance (Cb) dct dc predictor
  always @(posedge clk)
    if (~rst) dct_dc_pred_1 <= 11'b0;
    else if (clk_en && ((state == STATE_SLICE) ||  // at the start of a slice (par. 7.2.1)
                        ((state == STATE_BLOCK) && ~macroblock_intra) || // whenever a non-intra macroblock is decoded (par. 7.2.1.)
                        (state == STATE_MACROBLOCK_SKIP) )) // whenever a macroblock is skipped, i.e. when macroblock_address_increment > 1
                        dct_dc_pred_1 <= 11'b0; // the mpeg2 reference implementation (mpeg2decode) does not reset dct_dc_pred[i] to 11'd128 << intra_dc_precision; rather it adds 128 to the reconstructed output.
    else if (clk_en && (state == STATE_DCT_DC_DIFF_0) && block_chromi1_code[12]) dct_dc_pred_1 <= dct_dc_pred;
    else dct_dc_pred_1 <= dct_dc_pred_1;

  // second chrominance (Cr) dct dc predictor
  always @(posedge clk)
    if (~rst) dct_dc_pred_2 <= 11'b0;
    else if (clk_en && ((state == STATE_SLICE) ||  // at the start of a slice (par. 7.2.1)
                        ((state == STATE_BLOCK) && ~macroblock_intra) || // whenever a non-intra macroblock is decoded (par. 7.2.1.)
                        (state == STATE_MACROBLOCK_SKIP) )) // whenever a macroblock is skipped, i.e. when macroblock_address_increment > 1
                        dct_dc_pred_2 <= 11'b0; // the mpeg2 reference implementation (mpeg2decode) does not reset dct_dc_pred[i] to 11'd128 << intra_dc_precision; rather it adds 128 to the reconstructed output.
    else if (clk_en && (state == STATE_DCT_DC_DIFF_0) && block_chromi2_code[12]) dct_dc_pred_2 <= dct_dc_pred;
    else dct_dc_pred_2 <= dct_dc_pred_2;


  /* dct coefficients */
  assign dct_coefficient_escape = (getbits[23:18] == 6'b000001); // one if dct coefficient escape in table B-14 or B-15

  /* dct coeeficients are vlc decoded - still unsigned - and clocked in dct_coeff_run_0 and dct_coeff_signed_level_0.
   * next clock, the sign bit is applied, and the run/level pair is clocked in dct_coeff_run and dct_coeff_signed_level .
   *
   * A non-coded block (STATE_NON_CODED_BLOCK) or a block of a skipped macroblock (STATE_EMIT_EMPTY_BLOCK) is coded as a single zero, 
   * which also is the end of block. run=0, level=0, signed_level=0, end=1, valid=1.
   */

  always @(posedge clk)
    if (~rst) dct_coeff_run_0 <= 5'd0;
    else if (clk_en && ((state == STATE_DCT_SUBS_B15) || (state == STATE_DCT_SUBS_B14) || (state == STATE_DCT_NON_INTRA_FIRST)) && dct_coefficient_escape) dct_coeff_run_0 <= getbits[17:12];
    else if (clk_en && (state == STATE_DCT_SUBS_B15)) dct_coeff_run_0 <= dct_coefficient_1_decoded[10:6];
    else if (clk_en && (state == STATE_DCT_SUBS_B14)) dct_coeff_run_0 <= dct_coefficient_0_decoded[10:6];
    else if (clk_en && (state == STATE_DCT_NON_INTRA_FIRST)) dct_coeff_run_0 <= dct_non_intra_first_coefficient_0_decoded[10:6];
    else if (clk_en && (state == STATE_DCT_DC_DIFF_0)) dct_coeff_run_0 <= 5'd0;  // first (=dc)  coefficient of intra block is never preceded by zeroes
    else if (clk_en && ((state == STATE_NON_CODED_BLOCK) || (state == STATE_EMIT_EMPTY_BLOCK))) dct_coeff_run_0 <= 5'd0; // non-coded block: all zeroes.
    else dct_coeff_run_0 <= dct_coeff_run_0;

  /* DVD-FORK FIX (mpeg1): remembers whether the first escape-level byte was 0x80
   * (negative double-byte: level = b - 256) or 0x00 (positive: level = +b). */
  reg dct_m1_neg;
  always @(posedge clk)
    if (~rst) dct_m1_neg <= 1'b0;
    else if (clk_en && (state == STATE_DCT_ESCAPE_B14)) dct_m1_neg <= (getbits[23:16] == 8'h80);
    else dct_m1_neg <= dct_m1_neg;

  always @(posedge clk)
    if (~rst) dct_coeff_signed_level_0 <= 12'd0;
    // DVD-FORK FIX (mpeg1): MPEG-1 escape level is a signed 8-bit byte (sign-extends into
    // the 12-bit level path); the 0x00/0x80 double-byte cases are completed in
    // STATE_DCT_ESCAPE_M1 below (this capture is then dead — valid_0 stays low).
    else if (clk_en && ((state == STATE_DCT_ESCAPE_B15) || (state == STATE_DCT_ESCAPE_B14))) dct_coeff_signed_level_0 <= mpeg1 ? {{4{getbits[23]}}, getbits[23:16]} : getbits[23:12];
    else if (clk_en && (state == STATE_DCT_ESCAPE_M1)) dct_coeff_signed_level_0 <= dct_m1_neg ? {4'b1111, getbits[23:16]} : {4'b0000, getbits[23:16]}; // DVD-FORK FIX (mpeg1): b-256 / +b (b = second byte)
    else if (clk_en && (state == STATE_DCT_SUBS_B15) && ~dct_coefficient_escape) dct_coeff_signed_level_0 <= dct_coefficient_1_decoded[5:0]; // still needs sign
    else if (clk_en && (state == STATE_DCT_SUBS_B14) && ~dct_coefficient_escape) dct_coeff_signed_level_0 <= dct_coefficient_0_decoded[5:0]; // still needs sign
    else if (clk_en && (state == STATE_DCT_NON_INTRA_FIRST) && ~dct_coefficient_escape) dct_coeff_signed_level_0 <= dct_non_intra_first_coefficient_0_decoded[5:0]; // still needs sign
    else if (clk_en && (state == STATE_DCT_DC_DIFF_0)) dct_coeff_signed_level_0 <= {dct_dc_pred[10], dct_dc_pred}; // sign extend dc (first) coefficient of intra block
    else if (clk_en && (state == STATE_NON_CODED_BLOCK) || (state == STATE_EMIT_EMPTY_BLOCK)) dct_coeff_signed_level_0 <= 12'd0; // non-coded block: all zeroes.
    else dct_coeff_signed_level_0 <= dct_coeff_signed_level_0;

  always @(posedge clk)
    if (~rst) dct_coeff_apply_signbit_0 <= 1'b0;
    else if (clk_en && ((state == STATE_DCT_DC_DIFF_0) || (state == STATE_DCT_ESCAPE_B15) || (state == STATE_DCT_ESCAPE_B14) || (state == STATE_DCT_ESCAPE_M1))) dct_coeff_apply_signbit_0 <= 1'b0; // DVD-FORK FIX (mpeg1): M1 levels are already signed
    else if (clk_en && ((state == STATE_DCT_SUBS_B14) || (state == STATE_DCT_SUBS_B15) || (state == STATE_DCT_NON_INTRA_FIRST))) dct_coeff_apply_signbit_0 <= ~dct_coefficient_escape;
    else if (clk_en && (state == STATE_NON_CODED_BLOCK) || (state == STATE_EMIT_EMPTY_BLOCK)) dct_coeff_apply_signbit_0 <= 1'b0; // non-coded block: all zeroes.
    else dct_coeff_apply_signbit_0 <= dct_coeff_apply_signbit_0;

  always @(posedge clk)
    if (~rst) dct_coeff_valid_0 <= 1'b0;
    // DVD-FORK FIX (mpeg1): a 0x00/0x80 first escape byte means the level completes in
    // STATE_DCT_ESCAPE_M1 — no coefficient is emitted from STATE_DCT_ESCAPE_B14 then.
    else if (clk_en && (state == STATE_DCT_ESCAPE_B14)) dct_coeff_valid_0 <= ~dct_escape_m1_ext;
    else if (clk_en && ((state == STATE_DCT_DC_DIFF_0) || (state == STATE_DCT_ESCAPE_B15) || (state == STATE_DCT_ESCAPE_M1) || (state == STATE_NON_CODED_BLOCK) || (state == STATE_EMIT_EMPTY_BLOCK))) dct_coeff_valid_0 <= 1'b1;
    else if (clk_en && ((state == STATE_DCT_SUBS_B14) || (state == STATE_DCT_SUBS_B15) || (state == STATE_DCT_NON_INTRA_FIRST))) dct_coeff_valid_0 <= ~dct_coefficient_escape;
    else if (clk_en) dct_coeff_valid_0 <= 1'b0; 
    else dct_coeff_valid_0 <= dct_coeff_valid_0;

  always @(posedge clk)
    if (~rst) dct_coeff_end_0 <= 1'b0;
    else if (clk_en) dct_coeff_end_0 <= ((state == STATE_DCT_SUBS_B14) && (getbits[23:22] == 2'b10)) || ((state == STATE_DCT_SUBS_B15) && (getbits[23:20] == 4'b0110)) || (state == STATE_NON_CODED_BLOCK) || (state == STATE_EMIT_EMPTY_BLOCK);
    else dct_coeff_end_0 <= dct_coeff_end_0;

  // Now we clock dct_coeff_run_0 into dct_coeff_run, dct_coeff_signed_level_0 into dct_coeff_signed_level, and apply sign bit, if needed.
  //
  always @(posedge clk)
    if (~rst) dct_coeff_run <= 5'd0;
    else if (clk_en) dct_coeff_run <= dct_coeff_run_0;
    else dct_coeff_run <= dct_coeff_run;

  always @(posedge clk)
    if (~rst) dct_coeff_signed_level <= 12'd0;
    else if (clk_en) dct_coeff_signed_level <= (dct_coeff_apply_signbit_0 && signbit) ? 12'd1 + ~dct_coeff_signed_level_0 : dct_coeff_signed_level_0; // 2's complement -> negative
    else dct_coeff_signed_level <= dct_coeff_signed_level;

  always @(posedge clk)
    if (~rst) dct_coeff_valid <= 1'b0;
    else if (clk_en) dct_coeff_valid <= dct_coeff_valid_0;
    else dct_coeff_valid <= dct_coeff_valid;

  always @(posedge clk)
    if (~rst) dct_coeff_end <= 1'b0;
    else if (clk_en) dct_coeff_end <= dct_coeff_end_0;
    else dct_coeff_end <= dct_coeff_end;

  /* coded block pattern */
  always @(posedge clk) // // par. 6.3.17.4
    if (~rst) coded_block_pattern <= 12'b0;
    else if (clk_en && (state == STATE_MOTION_PIPELINE_FLUSH))
      begin
        if (macroblock_intra) // default values
          case (chroma_format)
            CHROMA420: coded_block_pattern <= {12'b111111000000}; 
            CHROMA422: coded_block_pattern <= {12'b111111110000};
            CHROMA444: coded_block_pattern <= {12'b111111111111};
            default    coded_block_pattern <= {12'b000000000000}; // error
          endcase
        else
          coded_block_pattern <= 12'b000000000000;
      end
    else if (clk_en && (state == STATE_CODED_BLOCK_PATTERN)) coded_block_pattern <= {coded_block_pattern_value, 6'b0};
    else if (clk_en && (state == STATE_CODED_BLOCK_PATTERN_1)) coded_block_pattern <= {coded_block_pattern[11:6], getbits[23:22], 4'b0};
    else if (clk_en && (state == STATE_CODED_BLOCK_PATTERN_2)) coded_block_pattern <= {coded_block_pattern[11:6], getbits[23:18]};
    else if (clk_en && (state == STATE_NEXT_BLOCK)) coded_block_pattern <= (coded_block_pattern << 1);
    else if (clk_en && (state == STATE_DCT_ERROR)) coded_block_pattern <= 12'b000000000000; // error occurred; output remaining blocks as non-coded blocks
    else coded_block_pattern <= coded_block_pattern;

   /* block loop registers */
   /*
    * block_pattern_code and block_lumi_code are used in the loop which is
    * symbolically coded in par. 6.2.5 as:
    * for ( i = 0; i < block_count; i + + ) {
    *   block( i )
    *   }
    *
    * We set up two registers, block_pattern_code and block_lumi_code.
    * The "one" bits in block_pattern_code correspond to the blocks present
    * in the macroblock.
    * The "one" bits in block_lumi_code correspond to the luminance blocks
    * in the macroblock (the first four blocks).
    * Both block_pattern_code and block_lumi_code are shifted left one bit
    * after each block. Macroblock ends when block_pattern_code is zero.
    */

   always @(posedge clk)
     if (~rst) block_pattern_code <= 12'b0;
     else if (clk_en && (state == STATE_MOTION_PIPELINE_FLUSH)) 
       case (chroma_format)  // Table 6-20
         CHROMA420: block_pattern_code <= {12'b111111000000};
	 CHROMA422: block_pattern_code <= {12'b111111110000};
	 CHROMA444: block_pattern_code <= {12'b111111111111};
	 default    block_pattern_code <= {12'b000000000000}; // error
       endcase
     else if (clk_en && (state == STATE_NEXT_BLOCK)) block_pattern_code <= (block_pattern_code << 1);
     else block_pattern_code <= block_pattern_code;

   always @(posedge clk)
     if (~rst) block_lumi_code <= 6'b0;
     else if (clk_en && (state == STATE_BLOCK)) block_lumi_code <= 6'b011110;
     else if (clk_en && (state == STATE_NEXT_BLOCK)) block_lumi_code <= (block_lumi_code << 1);
     else block_lumi_code <= block_lumi_code;

   always @(posedge clk)
     if (~rst) block_chromi1_code <= 13'b0;
     else if (clk_en && (state == STATE_BLOCK)) block_chromi1_code <= 13'b0000010101010;
     else if (clk_en && (state == STATE_NEXT_BLOCK)) block_chromi1_code <= (block_chromi1_code << 1);
     else block_chromi1_code <= block_chromi1_code;

   always @(posedge clk)
     if (~rst) block_chromi2_code <= 13'b0;
     else if (clk_en && (state == STATE_BLOCK)) block_chromi2_code <= 13'b0000001010101;
     else if (clk_en && (state == STATE_NEXT_BLOCK)) block_chromi2_code <= (block_chromi2_code << 1);
     else block_chromi2_code <= block_chromi2_code;

`ifdef DEBUG
   always @(posedge clk)
     if (clk_en)
       case (state)
         STATE_NEXT_START_CODE:            #0 $display("%m\tSTATE_NEXT_START_CODE");
         STATE_START_CODE:                 #0 $display("%m\tSTATE_START_CODE");
         STATE_PICTURE_HEADER:             #0 $display("%m\tSTATE_PICTURE_HEADER");
         STATE_PICTURE_HEADER0:            #0 $display("%m\tSTATE_PICTURE_HEADER0");
         STATE_PICTURE_HEADER1:            #0 $display("%m\tSTATE_PICTURE_HEADER1");
         STATE_PICTURE_HEADER2:            #0 $display("%m\tSTATE_PICTURE_HEADER2");
         STATE_SEQUENCE_HEADER:            #0 $display("%m\tSTATE_SEQUENCE_HEADER");
         STATE_SEQUENCE_HEADER0:           #0 $display("%m\tSTATE_SEQUENCE_HEADER0");
         STATE_SEQUENCE_HEADER1:           #0 $display("%m\tSTATE_SEQUENCE_HEADER1");
         STATE_SEQUENCE_HEADER2:           #0 $display("%m\tSTATE_SEQUENCE_HEADER2");
         STATE_SEQUENCE_HEADER3:           #0 $display("%m\tSTATE_SEQUENCE_HEADER3");
         STATE_GROUP_HEADER:               #0 $display("%m\tSTATE_GROUP_HEADER");
         STATE_GROUP_HEADER0:              #0 $display("%m\tSTATE_GROUP_HEADER0");
         STATE_EXTENSION_START_CODE:       #0 $display("%m\tSTATE_EXTENSION_START_CODE");
         STATE_SEQUENCE_EXT:               #0 $display("%m\tSTATE_SEQUENCE_EXT");
         STATE_SEQUENCE_EXT0:              #0 $display("%m\tSTATE_SEQUENCE_EXT0");
         STATE_SEQUENCE_EXT1:              #0 $display("%m\tSTATE_SEQUENCE_EXT1");
         STATE_SEQUENCE_DISPLAY_EXT:       #0 $display("%m\tSTATE_SEQUENCE_DISPLAY_EXT");
         STATE_SEQUENCE_DISPLAY_EXT0:      #0 $display("%m\tSTATE_SEQUENCE_DISPLAY_EXT0");
         STATE_SEQUENCE_DISPLAY_EXT1:      #0 $display("%m\tSTATE_SEQUENCE_DISPLAY_EXT1");
         STATE_SEQUENCE_DISPLAY_EXT2:      #0 $display("%m\tSTATE_SEQUENCE_DISPLAY_EXT2");
         STATE_QUANT_MATRIX_EXT:           #0 $display("%m\tSTATE_QUANT_MATRIX_EXT");
         STATE_PICTURE_CODING_EXT:         #0 $display("%m\tSTATE_PICTURE_CODING_EXT");
         STATE_PICTURE_CODING_EXT0:        #0 $display("%m\tSTATE_PICTURE_CODING_EXT0");
         STATE_PICTURE_CODING_EXT1:        #0 $display("%m\tSTATE_PICTURE_CODING_EXT1");
         STATE_LD_INTRA_QUANT0:            #0 $display("%m\tSTATE_LD_INTRA_QUANT0");
         STATE_LD_INTRA_QUANT1:            #0 $display("%m\tSTATE_LD_INTRA_QUANT1");
         STATE_LD_NON_INTRA_QUANT0:        #0 $display("%m\tSTATE_LD_NON_INTRA_QUANT0");
         STATE_LD_NON_INTRA_QUANT1:        #0 $display("%m\tSTATE_LD_NON_INTRA_QUANT1");
         STATE_LD_CHROMA_INTRA_QUANT1:     #0 $display("%m\tSTATE_LD_CHROMA_INTRA_QUANT1");
         STATE_LD_CHROMA_NON_INTRA_QUANT1: #0 $display("%m\tSTATE_LD_CHROMA_NON_INTRA_QUANT1");
         STATE_SLICE:                      #0 $display("%m\tSTATE_SLICE");
         STATE_SLICE_EXTENSION:            #0 $display("%m\tSTATE_SLICE_EXTENSION");
         STATE_SLICE_EXTRA_INFORMATION:    #0 $display("%m\tSTATE_SLICE_EXTRA_INFORMATION");
         STATE_NEXT_MACROBLOCK:            #0 $display("%m\tSTATE_NEXT_MACROBLOCK");
         STATE_MACROBLOCK_SKIP:            #0 $display("%m\tSTATE_MACROBLOCK_SKIP");
         STATE_DELAY_EMPTY_BLOCK:          #0 $display("%m\tSTATE_DELAY_EMPTY_BLOCK");
         STATE_EMIT_EMPTY_BLOCK:           #0 $display("%m\tSTATE_EMIT_EMPTY_BLOCK");
         STATE_MACROBLOCK_TYPE:            #0 $display("%m\tSTATE_MACROBLOCK_TYPE");
         STATE_MOTION_TYPE:                #0 $display("%m\tSTATE_MOTION_TYPE");
         STATE_DCT_TYPE:                   #0 $display("%m\tSTATE_DCT_TYPE");
         STATE_MACROBLOCK_QUANT:           #0 $display("%m\tSTATE_MACROBLOCK_QUANT");
         STATE_NEXT_MOTION_VECTOR:         #0 $display("%m\tSTATE_NEXT_MOTION_VECTOR");
         STATE_MOTION_VERT_FLD_SEL:        #0 $display("%m\tSTATE_MOTION_VERT_FLD_SEL");
         STATE_MOTION_CODE:                #0 $display("%m\tSTATE_MOTION_CODE");
         STATE_MOTION_RESIDUAL:            #0 $display("%m\tSTATE_MOTION_RESIDUAL");
         STATE_MOTION_DMVECTOR:            #0 $display("%m\tSTATE_MOTION_DMVECTOR");
         STATE_MOTION_PREDICT:             #0 $display("%m\tSTATE_MOTION_PREDICT");
         STATE_MOTION_PIPELINE_FLUSH:      #0 $display("%m\tSTATE_MOTION_PIPELINE_FLUSH");
         STATE_MARKER_BIT_0:               #0 $display("%m\tSTATE_MARKER_BIT_0");
         STATE_CODED_BLOCK_PATTERN:        #0 $display("%m\tSTATE_CODED_BLOCK_PATTERN");
         STATE_CODED_BLOCK_PATTERN_1:      #0 $display("%m\tSTATE_CODED_BLOCK_PATTERN_1");
         STATE_CODED_BLOCK_PATTERN_2:      #0 $display("%m\tSTATE_CODED_BLOCK_PATTERN_2");
         STATE_BLOCK:                      #0 $display("%m\tSTATE_BLOCK");
         STATE_NEXT_BLOCK:                 #0 $display("%m\tSTATE_NEXT_BLOCK");
         STATE_DCT_DC_LUMI_SIZE:           #0 $display("%m\tSTATE_DCT_DC_LUMI_SIZE");
         STATE_DCT_DC_CHROMI_SIZE:         #0 $display("%m\tSTATE_DCT_DC_CHROMI_SIZE");
         STATE_DCT_DC_DIFF:                #0 $display("%m\tSTATE_DCT_DC_DIFF");
         STATE_DCT_DC_DIFF_0:              #0 $display("%m\tSTATE_DCT_DC_DIFF_0");
         STATE_DCT_SUBS_B15:               #0 $display("%m\tSTATE_DCT_SUBS_B15");
         STATE_DCT_ESCAPE_B15:             #0 $display("%m\tSTATE_DCT_ESCAPE_B15");
         STATE_DCT_SUBS_B14:               #0 $display("%m\tSTATE_DCT_SUBS_B14");
         STATE_DCT_ESCAPE_B14:             #0 $display("%m\tSTATE_DCT_ESCAPE_B14");
         STATE_DCT_NON_INTRA_FIRST:        #0 $display("%m\tSTATE_DCT_NON_INTRA_FIRST");
         STATE_NON_CODED_BLOCK:            #0 $display("%m\tSTATE_NON_CODED_BLOCK");
         STATE_DCT_ERROR:                  #0 $display("%m\tSTATE_DCT_ERROR");
         STATE_SEQUENCE_END:               #0 $display("%m\tSTATE_SEQUENCE_END");
         STATE_ERROR:                      #0 $display("%m\tSTATE_ERROR");
	 default                           begin
	                                     #0 $display("%m\tUnknown state");
					     $finish;
	                                   end
       endcase
     else
       begin
         #0 $display("%m\tnot clk_en");
       end

   always @(posedge clk)
     if (clk_en)
       case (state)
         STATE_SEQUENCE_HEADER2:
           begin
             $strobe ("%m\tmb_width: %d", mb_width);
             $strobe ("%m\tmb_height: %d", mb_height);
           end
	 
         STATE_LD_INTRA_QUANT1,
         STATE_LD_NON_INTRA_QUANT0,
         STATE_LD_NON_INTRA_QUANT1,
         STATE_LD_CHROMA_INTRA_QUANT1,
         STATE_LD_CHROMA_NON_INTRA_QUANT1:
           begin
             $strobe ("%m\tcnt: %d", cnt);
             $strobe ("%m\tquant_wr_data: %d", quant_wr_data);
             $strobe ("%m\tquant_wr_addr: %d", quant_wr_addr);
           end  
         STATE_SLICE:
           begin
             $strobe ("%m\tslice_vertical_position: %d", slice_vertical_position);
             $strobe ("%m\tquantiser_scale_code: %d", quantiser_scale_code);
             $strobe ("%m\tslice_extension_flag: %d", slice_extension_flag);
           end

         STATE_SLICE_EXTENSION:
           begin
             $strobe ("%m\tintra_slice: %d", intra_slice);
             $strobe ("%m\tslice_picture_id_enable: %d", slice_picture_id_enable);
             $strobe ("%m\tslice_picture_id: %d", slice_picture_id);
           end

         //STATE_SLICE_EXTRA_INFORMATION:
         STATE_NEXT_MACROBLOCK:
           begin
             $strobe ("%m\tmacroblock_addr_inc_value: %d", macroblock_addr_inc_value);
             $strobe ("%m\tmacroblock_address_increment: %d", macroblock_address_increment);
           end

         STATE_MACROBLOCK_SKIP:
           begin
             $strobe ("%m\tmacroblock_address: %d", macroblock_address);
             $strobe ("%m\tmacroblock_address_increment: %d", macroblock_address_increment);
             $strobe ("%m\tmotion_type: %d", motion_type);
             $strobe ("%m\tpmv_reset: %d", pmv_reset);
             $strobe ("%m\tdct_dc_pred_0: %d", dct_dc_pred_0);
             $strobe ("%m\tdct_dc_pred_1: %d", dct_dc_pred_1);
             $strobe ("%m\tdct_dc_pred_2: %d", dct_dc_pred_2);
           end

         STATE_EMIT_EMPTY_BLOCK:
           begin
             $strobe ("%m\tempty_blocks: %11b", empty_blocks);
	   end

         STATE_MACROBLOCK_TYPE:
           begin
             $strobe ("%m\tmacroblock_address: %d", macroblock_address);
             $strobe ("%m\tmacroblock_address_increment: %d", macroblock_address_increment);
             $strobe ("%m\tmacroblock_quant: %d", macroblock_quant);
             $strobe ("%m\tmacroblock_motion_forward: %d", macroblock_motion_forward);
             $strobe ("%m\tmacroblock_motion_backward: %d", macroblock_motion_backward);
             $strobe ("%m\tmacroblock_pattern: %d", macroblock_pattern);
             $strobe ("%m\tmacroblock_intra: %d", macroblock_intra);
             $strobe ("%m\tspatial_temporal_weight_code_flag: %d", spatial_temporal_weight_code_flag);
             $strobe ("%m\tmotion_type: %d", motion_type);
           end

         STATE_MOTION_TYPE:
           begin
             $strobe ("%m\tmotion_type: %d", motion_type);
           end

         STATE_DCT_TYPE:
           begin
             $strobe ("%m\tdct_type: %d", dct_type);
           end

         STATE_MACROBLOCK_QUANT:
           begin
             if (macroblock_quant) $strobe ("%m\tquantiser_scale_code: %d", quantiser_scale_code);
             $strobe ("%m\tmotion_vector_reg: %8b", motion_vector_reg);
           end

         STATE_NEXT_MOTION_VECTOR:    
           begin
	     case (motion_vector)
               MOTION_VECTOR_0_0_0: $strobe ("%m\tmotion_vector: MOTION_VECTOR_0_0_0");
               MOTION_VECTOR_0_0_1: $strobe ("%m\tmotion_vector: MOTION_VECTOR_0_0_1");
               MOTION_VECTOR_1_0_0: $strobe ("%m\tmotion_vector: MOTION_VECTOR_1_0_0");
               MOTION_VECTOR_1_0_1: $strobe ("%m\tmotion_vector: MOTION_VECTOR_1_0_1");
               MOTION_VECTOR_0_1_0: $strobe ("%m\tmotion_vector: MOTION_VECTOR_0_1_0");
               MOTION_VECTOR_0_1_1: $strobe ("%m\tmotion_vector: MOTION_VECTOR_0_1_1");
               MOTION_VECTOR_1_1_0: $strobe ("%m\tmotion_vector: MOTION_VECTOR_1_1_0");
               MOTION_VECTOR_1_1_1: $strobe ("%m\tmotion_vector: MOTION_VECTOR_1_1_1");
	     endcase
             $strobe ("%m\tmotion_vector_reg: %8b", motion_vector_reg);
           end

         STATE_MOTION_VERT_FLD_SEL:    
           begin
             $strobe ("%m\t\tmotion_vert_field_select_0_0: %d", motion_vert_field_select_0_0);
             $strobe ("%m\t\tmotion_vert_field_select_0_1: %d", motion_vert_field_select_0_1);
             $strobe ("%m\t\tmotion_vert_field_select_1_0: %d", motion_vert_field_select_1_0);
             $strobe ("%m\t\tmotion_vert_field_select_1_1: %d", motion_vert_field_select_1_1);
           end

         STATE_MOTION_CODE:
           begin
             $strobe ("%m\tr_size: %d", r_size);
             $strobe ("%m\tmotion_code: %d", motion_code);
             $strobe ("%m\tmotion_code_neg: %d", motion_code_neg);
           end

         STATE_MOTION_RESIDUAL:
           begin
             $strobe ("%m\tmotion_code_residual: %d", motion_code_residual);
           end

         STATE_MOTION_DMVECTOR:
           begin
             $strobe ("%m\tdmvector: %d", dmvector);
           end

         STATE_MOTION_PREDICT:
           begin
             $strobe ("%m\tmotion_vector_reg: %8b", motion_vector_reg);
           end


         //STATE_MARKER_BIT_0:
         STATE_CODED_BLOCK_PATTERN,
         STATE_CODED_BLOCK_PATTERN_1,
         STATE_CODED_BLOCK_PATTERN_2:
           begin
             $strobe ("%m\tchroma_format:  d%d", chroma_format);
             $strobe ("%m\tcoded_block_pattern:  b%b", coded_block_pattern);
             $strobe ("%m\tblock_pattern_code:   b%b", block_pattern_code);
             $strobe ("%m\tblock_lumi_code:     b%b", block_lumi_code);
             $strobe ("%m\tblock_chromi1_code:  b%b", block_chromi1_code);
             $strobe ("%m\tblock_chromi2_code:  b%b", block_chromi2_code);
           end

         STATE_BLOCK:
           begin
             #0 $display ("%m\tblock");
             // helper regs:
             $strobe ("%m\tmacroblock_intra: b%b", macroblock_intra);
             $strobe ("%m\tmacroblock_pattern: b%b", macroblock_pattern);
             $strobe ("%m\tcoded_block_pattern:  b%b", coded_block_pattern);
             // result:
             $strobe ("%m\tblock_pattern_code:   b%b", block_pattern_code);
             $strobe ("%m\tblock_lumi_code:     b%b", block_lumi_code);
             $strobe ("%m\tblock_chromi1_code:  b%b", block_chromi1_code);
             $strobe ("%m\tblock_chromi2_code:  b%b", block_chromi2_code);
           end

         STATE_NEXT_BLOCK:
           begin
             $strobe ("%m\tcoded_block_pattern:  b%b", coded_block_pattern);
             $strobe ("%m\tblock_pattern_code:   b%b", block_pattern_code);
             $strobe ("%m\tblock_lumi_code:     b%b", block_lumi_code);
             $strobe ("%m\tblock_chromi1_code:  b%b", block_chromi1_code);
             $strobe ("%m\tblock_chromi2_code:  b%b", block_chromi2_code);
           end

         STATE_DCT_DC_LUMI_SIZE:
           begin
             $strobe ("%m\tdct_dc_size_luminance_length: %d", dct_dc_size_luminance_length);
             $strobe ("%m\tdct_dc_size_luminance_value: %d", dct_dc_size_luminance_value);
             $strobe ("%m\tdct_dc_pred: %d (%b)", dct_dc_pred, dct_dc_pred);
           end

         STATE_DCT_DC_CHROMI_SIZE:
           begin
             $strobe ("%m\tdct_dc_size_chrominance_length: %d", dct_dc_size_chrominance_length);
             $strobe ("%m\tdct_dc_size_chrominance_value: %d", dct_dc_size_chrominance_value);
             $strobe ("%m\tdct_dc_pred: %d (%b)", dct_dc_pred, dct_dc_pred);
           end

         STATE_DCT_DC_DIFF:
           begin
             $strobe ("%m\tdct_dc_size: %d", dct_dc_size);
             $strobe ("%m\tdct_dc_pred: %d (%b)", dct_dc_pred, dct_dc_pred);
           end

         STATE_DCT_DC_DIFF_0:
           begin
             if (block_lumi_code[12])
               begin
                 $strobe ("%m\tdct_dc_pred_0: %d (%b) (Y)", dct_dc_pred_0, dct_dc_pred_0);
               end
             else if (block_chromi1_code[12])
               begin
                 $strobe ("%m\tdct_dc_pred_1: %d (%b) (Cb)", dct_dc_pred_1, dct_dc_pred_1);
               end
             else if (block_chromi2_code[12])
               begin
                 $strobe ("%m\tdct_dc_pred_2: %d (%b) (Cr)", dct_dc_pred_2, dct_dc_pred_2);
               end
           end

         STATE_DCT_SUBS_B15,
         STATE_DCT_SUBS_B14,
         STATE_DCT_NON_INTRA_FIRST,
         STATE_DCT_ESCAPE_B15,
         STATE_DCT_ESCAPE_B14:
           begin
             $strobe ("%m\tdct_coeff_run_0: %d", dct_coeff_run_0);
             $strobe ("%m\tdct_coeff_signed_level_0: %0d (%12b)", dct_coeff_signed_level_0, dct_coeff_signed_level_0);
             $strobe ("%m\tsignbit: %d", signbit);
             $strobe ("%m\tdct_coeff_apply_signbit_0: %d", dct_coeff_apply_signbit_0);
             $strobe ("%m\tdct_coeff_valid_0: %d", dct_coeff_valid_0);
             $strobe ("%m\tdct_coeff_end_0: %d", dct_coeff_end_0);

             $strobe ("%m\tdct_coeff_run: %d", dct_coeff_run);
             $strobe ("%m\tdct_coeff_signed_level: %0d (%12b)", dct_coeff_signed_level, dct_coeff_signed_level);
             $strobe ("%m\tdct_coeff_valid: %d", dct_coeff_valid);
             $strobe ("%m\tdct_coeff_end: %d", dct_coeff_end);
           end

         STATE_ERROR:
           begin
             $strobe ("%m\tError");
           end

       endcase

   /* motion vector pipeline status */
   always @(posedge clk)
     if (clk_en && (state == STATE_MOTION_PREDICT))
           begin
             $strobe ("%m\tr_size: %d", r_size);
             $strobe ("%m\tmotion_code: %d", motion_code);
             $strobe ("%m\tmotion_code_residual: %d", motion_code_residual);
             $strobe ("%m\t\tmotion_vector_valid_0: %d", motion_vector_valid_0);
             $strobe ("%m\t\tmotion_vector_0: %d", motion_vector_0);
             $strobe ("%m\t\tpmv_delta_0: %d", pmv_delta_0);
             $strobe ("%m\t\tpmv_0: %d", pmv_0);
             $strobe ("%m\t\tmotion_code_neg_0: %d", motion_code_neg_0);
             $strobe ("%m\t\tr_size_0: %d", r_size_0);
	   end 

   always @(posedge clk)
     if (clk_en && motion_vector_valid_0)
           begin
             $strobe ("%m\t\tmotion_vector_valid_1: %d", motion_vector_valid_1);
             $strobe ("%m\t\tmotion_vector_1: %d", motion_vector_1);
             $strobe ("%m\t\tpmv_1: %d", pmv_1);
             $strobe ("%m\t\tr_size_1: %d", r_size_1);
             $strobe ("%m\t\tshift_pmv: %d", shift_pmv);
	   end 

   always @(posedge clk)
     if (clk_en && motion_vector_valid_1)
           begin
             $strobe ("%m\t\tmotion_vector_valid_2: %d", motion_vector_valid_2);
             $strobe ("%m\t\tmotion_vector_2: %d", motion_vector_2);
             $strobe ("%m\t\tpmv_2: %d", pmv_2);
	   end 

   always @(posedge clk)
     if (clk_en && motion_vector_valid_2)
           begin
             $strobe ("%m\t\tmotion_vector_valid_3: %d", motion_vector_valid_3);
             $strobe ("%m\t\tmotion_vector_3: %d", motion_vector_3);
             $strobe ("%m\t\tpmv_3: %d", pmv_3);
             if (dmv)
               begin
                 $strobe ("%m\t\tdmvector_aux_a_3: %d", dmvector_aux_a_3);
                 $strobe ("%m\t\tdmvector_aux_b_3: %d", dmvector_aux_b_3);
               end
	   end 

   always @(posedge clk)
     if (clk_en && motion_vector_valid_3)
           begin
             $strobe ("%m\t\tmotion_vector_valid_4: %d", motion_vector_valid_4);
             $strobe ("%m\t\tmotion_vector_4: %d", motion_vector_4);
             $strobe ("%m\t\tpmv_4: %d", pmv_4);
             if (dmv)
               begin
                 $strobe ("%m\t\tdmvector_aux_a_4: %d", dmvector_aux_a_4);
                 $strobe ("%m\t\tdmvector_aux_b_4: %d", dmvector_aux_b_4);
                 $strobe ("%m\t\te_parity_ref_parity_pred_4: %d", e_parity_ref_parity_pred_4);
               end
	   end 

   always @(posedge clk)
     if (clk_en && motion_vector_valid_4)
           begin
             $strobe ("%m\t\tmotion_vector_valid_5: %d", motion_vector_valid_5);
             $strobe ("%m\t\tmotion_vector_5: %d", motion_vector_5);
             $strobe ("%m\t\tpmv_5: %d", pmv_5);
             if (dmv)
               begin
                 $strobe ("%m\t\tdmvector_aux_a_5: %d", dmvector_aux_a_5);
                 $strobe ("%m\t\tdmvector_aux_b_5: %d", dmvector_aux_b_5);
               end
	   end 

   always @(posedge clk)
     if (clk_en && motion_vector_valid_5)
       case (motion_vector_5)
         MOTION_VECTOR_0_0_1: $strobe("%m\t\tpmv: %0d,%0d", pmv_0_0_0, pmv_0_0_1);
         MOTION_VECTOR_0_1_1: $strobe("%m\t\tpmv: %0d,%0d", pmv_0_1_0, pmv_0_1_1);
         MOTION_VECTOR_1_0_1: $strobe("%m\t\tpmv: %0d,%0d", pmv_1_0_0, pmv_1_0_1);
         MOTION_VECTOR_1_1_1: $strobe("%m\t\tpmv: %0d,%0d", pmv_1_1_0, pmv_1_1_1);
       endcase

   always @(posedge clk)
     if (clk_en && motion_vector_valid_5 && dmv && (motion_vector_5 == MOTION_VECTOR_0_0_1))
       begin
         $strobe ("%m\t\tdmv_0_0: %d", dmv_0_0);
         $strobe ("%m\t\tdmv_0_1: %d", dmv_0_1);
         $strobe ("%m\t\tdmv_1_0: %d", dmv_1_0);
         $strobe ("%m\t\tdmv_1_1: %d", dmv_1_1);
       end

   always @(posedge clk)
     if (clk_en && pmv_reset)
       begin
         #0 $display ("%m\t\tresetting motion vectors. pmv_x_x_x <= 0");
       end

   always @(posedge clk)
     if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_0_0_0) && pmv_update0)
       begin
         #0 $display ("%m\t\tupdating motion vectors. pmv_1_0_0 <= pmv_0_0_0");
       end

   always @(posedge clk)
     if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_0_0_1) && pmv_update0)
       begin
         #0 $display ("%m\t\tupdating motion vectors. pmv_1_0_1 <= pmv_0_0_1");
       end

   always @(posedge clk)
     if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_0_1_0) && pmv_update1)
       begin
         #0 $display ("%m\t\tupdating motion vectors. pmv_1_1_0 <= pmv_0_1_0");
       end

   always @(posedge clk)
     if (clk_en && (motion_vector_valid_5) && (motion_vector_5 == MOTION_VECTOR_0_1_1) && pmv_update1)
       begin
         #0 $display ("%m\t\tupdating motion vectors. pmv_1_1_1 <= pmv_0_1_1");
       end

   always @(posedge clk)
     if (clk_en && ((state == STATE_MOTION_PREDICT) || pmv_reset || motion_vector_valid_5))
       begin
         $strobe ("%m\t\tpmv_0_0_0: %d", pmv_0_0_0);
         $strobe ("%m\t\tpmv_0_0_1: %d", pmv_0_0_1);
         $strobe ("%m\t\tpmv_1_0_0: %d", pmv_1_0_0);
         $strobe ("%m\t\tpmv_1_0_1: %d", pmv_1_0_1);
         $strobe ("%m\t\tpmv_0_1_0: %d", pmv_0_1_0);
         $strobe ("%m\t\tpmv_0_1_1: %d", pmv_0_1_1);
         $strobe ("%m\t\tpmv_1_1_0: %d", pmv_1_1_0);
         $strobe ("%m\t\tpmv_1_1_1: %d", pmv_1_1_1);
         $strobe ("%m\t\tmotion_vert_field_select_0_0: %d", motion_vert_field_select_0_0);
         $strobe ("%m\t\tmotion_vert_field_select_0_1: %d", motion_vert_field_select_0_1);
         $strobe ("%m\t\tmotion_vert_field_select_1_0: %d", motion_vert_field_select_1_0);
         $strobe ("%m\t\tmotion_vert_field_select_1_1: %d", motion_vert_field_select_1_1);
       end

   /* fifo status */
   always @(posedge clk)
     if (clk_en)
       begin
         #0 $display("%m\tgetbits: %h (%b)", getbits, getbits);
       end

   always @(posedge clk)
     if (clk_en)
       begin
         $strobe("%m\talign: %d advance %d", align, advance);
       end
`endif

endmodule

/*
   Extracts a register from the bitstream.
   when reset* is asserted, clear register 'fsm_reg'
   else, when in state 'fsm_state',
   clock 'width' bits at offset 'offset' in the video stream into the register 'fsm_reg'.

 */

module loadreg #(parameter offset=0, width=8, fsm_state = 8'hff) (
   input                  clk,
   input                  clk_en,
   input                  rst,
   input             [7:0]state,
   input            [23:0]getbits,
   output reg  [width-1:0]fsm_reg
   );
  always @(posedge clk)
    begin
      if (~rst) fsm_reg <= {32{1'b0}}; // gets truncated
      else if (clk_en && (state == fsm_state))
        begin
          fsm_reg <= getbits[23-offset:23-offset-width+1];
          `ifdef DEBUG
            $strobe ("%m\t%0d'd%0d (%0d'h%0h, %0d'b%0b)", width, fsm_reg, width, fsm_reg, width, fsm_reg);
          `endif
        end
      else fsm_reg <= fsm_reg;
    end
endmodule

/* not truncated */
