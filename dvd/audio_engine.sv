//============================================================================
//  audio_engine.sv -- the shared microcoded audio engine (dvd/dts/dts_top.sv) as the
//  AC-3 decoder: the parse (docs/ac3_engine.md "W1") and, since logic reclaim F, the
//  IMDCT too (docs/imdct_engine.md: imdct_512's arithmetic as a term program, bit for
//  bit), its PCM read by pcm_out out of the engine's ring.
//
//  It replaces ac3_front (sync_crc, bsi_parse, audblk_parse, exponent_decode,
//  bit_allocation, mantissa_dequant, bit_reader, bit_fifo) with the engine running
//  dvd/dts/ac3.uasm, whose coefficients, LFE slot and side information are bit-exact
//  against ac3_front's on every gate stream (bench/dvd/run_ac3.sh). Downstream
//  pcm_out drains each block from the ring.
//
//  INPUT: one frame at a time -- a descriptor (fr_len: its byte length) and then
//  exactly that many bytes (dvd_audio_decode's dispatcher, one audio_ring frame;
//  ac3_reframer makes each one AC-3 syncframe). A frame the program refuses (no
//  sync, an out-of-scope field, a bad exponent or grouped code) is drained and the
//  engine waits for the next: no halt and no self-heal reset, unlike ac3_front.
//
//  THE IMDCT HANDSHAKE. The engine raises imdct_req with the block's coefficients in
//  its X buffer and waits for imdct_go: the PREVIOUS block's PCM drained by pcm_out
//  (pcm_done), because the transform overwrites the PCM slots. It then transforms the
//  block itself and pulses imdct_fin (-> imdct_done, pcm_out's start). The block's
//  acmod and mix levels are LATCHED at the go and held until the next one, because the
//  engine runs ahead -- it parses block k+1 while pcm_out still drains block k -- and
//  lvl_q, which pcm_out applies during the drain, is combinational in them.
//  ⚠ The PCM slots are in the engine's ring, which DTS and MP2 use too: a change of
//  program also waits for pcm_free, so a DTS RESET never clears a block mid-drain.
//
//  DTS (docs/dts_decoder.md P3): the same engine runs dvd/dts/dts.uasm when codec_req
//  is 0, and MP2 (docs/mp2_engine.md M3) dvd/dts/mp2.uasm when it is 2: both leave
//  stereo pairs on dts_l/dts_r/dts_valid, and MP2's sampling frequency on mp2_fs. A change of program waits until the engine is idle at FRAME (no frame in
//  flight, no IMDCT pending), then holds it in reset for a few cycles with the new
//  codec: codec_busy is high from the request until then, and the caller must not
//  present a descriptor meanwhile (the old program would take it). DTS's stereo PCM
//  leaves on dts_l/dts_r/dts_valid with dts_ready back-pressure (the engine's MIXSYN
//  waits); its codebook port (cb_*) is answered from DDR3 by dvd/dts/dts_cb_mem.sv.
//
//  rst is synchronous, active-high (as ac3_front's).
//============================================================================

`timescale 1ns/1ps
`default_nettype none

module audio_engine (
    input  wire         clk,
    input  wire         rst,
    input  wire   [1:0] codec_req,           // 1 AC-3, 0 DTS, 2 MP2: the program to run
    output logic        codec_busy,          // a change of program is pending: hold
                                             // the descriptor

    // one frame: a descriptor, then fr_len bytes
    input  wire  [15:0] fr_len,
    input  wire         fr_valid,
    output logic        fr_ready,
    input  wire   [7:0] in_byte,
    input  wire         in_valid,
    output logic        in_ready,

    // a block's PCM for pcm_out (as ac3_front's)
    output logic        imdct_done,          // pulse: pcm_mem holds a block
    input  wire  [10:0] pcm_rd_addr,         // {ch[2:0], idx[7:0]}
    output logic signed [31:0] pcm_rd_data,
    output logic [15:0] lvl_q,
    output logic  [2:0] pcm_acmod,           // the drained block's acmod (pcm_out's mono)
    input  wire         pcm_done,            // pcm_out has drained the block

    // DTS: stereo s16 pairs, and the codebook port
    output logic [15:0] dts_l,
    output logic [15:0] dts_r,
    output logic        dts_valid,
    output logic  [1:0] mp2_fs,              // MP2: the stream's rate (0 44.1, 1 48, 2 32 kHz)
    output logic        mp2_fs_ok,           // a header has reported mp2_fs since reset
    output logic [15:0] n_ignored,           // CNT 0: DTS downmixes ignored, MP2 frames
                                             // longer than their header
    input  wire         dts_ready,
    output logic        cb_req,
    output logic        cb_sel,
    output logic [11:0] cb_addr,
    input  wire         cb_valid,
    input  wire  [63:0] cb_data,

    // status
    output logic        synced,              // a frame decoded since reset
    output logic        frame_ok,            // pulse: a frame decoded to its end
    output logic        refused,             // pulse: a frame refused
    output logic  [4:0] err_code,            // that refusal's code (ac3.uasm E_*)
    output logic [15:0] n_frames,
    output logic [15:0] n_refused,
    output logic [31:0] err_seen,
    output logic [15:0] n_overrun
);

    // ---- the engine ----
    logic        e_rst_n;
    logic        imdct_req, im_fin, im_go;
    logic  [4:0] blk_blksw;
    logic  [7:0] blk_dynrng;
    logic  [2:0] blk_acmod;
    logic        blk_lfeon;
    logic  [1:0] blk_cmix, blk_surmix;
    logic [15:0] e_frames, e_refused, e_ovr;
    logic  [4:0] e_last_err;
    logic        vop_start, vop_done, e_fend, e_ref;
    logic  [4:0] e_rcode;
    logic  [5:0] vop_op;
    // the program: a change waits for the engine to idle at FRAME, then resets it
    logic  [1:0] eng_codec;
    logic  [2:0] sw_cnt;
    logic        e_fr_ready;
    logic        pcm_free;                   // pcm_out has drained the ring's PCM slots
    wire         idle_at_frame = e_fr_ready && !imdct_req && pcm_free;
    always_ff @(posedge clk) begin
        if (rst) begin
            eng_codec <= 2'd1; sw_cnt <= 3'd0;
        end else if (sw_cnt != 3'd0) sw_cnt <= sw_cnt - 3'd1;
        else if (codec_req != eng_codec && idle_at_frame) begin
            eng_codec <= codec_req; sw_cnt <= 3'd7;
        end
    end
    assign codec_busy = (codec_req != eng_codec) || (sw_cnt != 3'd0);
    always_comb e_rst_n = !rst && (sw_cnt == 3'd0);
    // a descriptor reaches the engine only when it runs the program it is for
    wire e_fr_valid = fr_valid && !codec_busy;
    assign fr_ready = e_fr_ready && !codec_busy;

    dts_top u_eng (
        .clk, .rst_n(e_rst_n), .codec(eng_codec), .mp2_fs, .mp2_fs_ok,
        .fr_len, .fr_valid(e_fr_valid), .fr_ready(e_fr_ready), .in_byte, .in_valid, .in_ready,
        .cb_req, .cb_sel, .cb_addr, .cb_valid, .cb_data,
        .pcm_l(dts_l), .pcm_r(dts_r), .pcm_valid(dts_valid), .pcm_ready(dts_ready),
        .frames(e_frames), .refused(e_refused), .last_err(e_last_err), .err_seen(err_seen),
        .overrun_bits(e_ovr), .lenient_codes(), .dmix_ignored(n_ignored),
        .frame_end(e_fend), .refuse(e_ref), .refuse_code(e_rcode),
        .imdct_req, .imdct_go(im_go), .imdct_fin(im_fin),
        .pcm_ra({pcm_rd_addr[8], pcm_rd_addr[7:0]}), .pcm_q(pcm_rd_data),
        .coef_ra(11'd0), .coef_q(),
        .blk_blksw, .blk_dynrng, .blk_acmod, .blk_lfeon, .blk_cmix, .blk_surmix,
        .vop_start, .vop_op, .vop_done,
        .tr_valid(), .tr_pc(), .tr_kind(), .tr_addr(), .tr_val());

    assign n_frames  = e_frames;
    assign n_refused = e_refused;
    assign n_overrun = e_ovr;

    // ---- the IMDCT handshake ----
    logic  [2:0] i_acmod;
    logic  [1:0] i_cmix, i_surmix;
    always_comb im_go = imdct_req && pcm_free;
    always_ff @(posedge clk) begin
        if (rst) begin
            pcm_free <= 1'b1;
            i_acmod <= 3'd2; i_cmix <= 2'd0; i_surmix <= 2'd0;
        end else begin
            if (im_go) begin                     // the transform starts this edge
                pcm_free <= 1'b0;
                i_acmod <= blk_acmod; i_cmix <= blk_cmix; i_surmix <= blk_surmix;
            end
            if (pcm_done) pcm_free <= 1'b1;
        end
    end
    assign imdct_done = im_fin;
    assign pcm_acmod  = i_acmod;

    // ---- lvl_q: the per-frame output level (moved from imdct_512 unchanged) ----
    // pcm_out multiplies by this so the s16 output lands on liba52's reference level for
    // every acmod: Q2.14, round(2^32 / (131072 + clev + slev)), clev and slev the
    // EFFECTIVE mix levels (zero for a role the acmod lacks; a mono surround pre-scaled
    // by LEVEL_3DB). The full derivation is in git history of dvd/ac3/imdct_512.sv
    // ("DVD-FORK FIX (2026-09-07): per-frame OUTPUT LEVEL scalar"). dts_vec derives the
    // same clev / slev for its fold from the op's arguments.
    wire        has_c    = (i_acmod == 3'd3) || (i_acmod == 3'd5) || (i_acmod == 3'd7);
    wire        has_surr = i_acmod[2];
    wire        surr_mono = (i_acmod == 3'd4) || (i_acmod == 3'd5);
    logic [17:0] clev, slev;
    always_comb begin
        case (i_cmix)                          // 0.707 / 0.595 / 0.5 / reserved -> 0.595
            2'd0: clev = 18'd92682;
            2'd2: clev = 18'd65536;
            default: clev = 18'd77933;
        endcase
        if (!has_c) clev = 18'd0;
        case (i_surmix)                        // 0.707 / 0.5 / 0 (reserved -> 0)
            2'd0: slev = surr_mono ? 18'd65536 : 18'd92682;
            2'd1: slev = surr_mono ? 18'd46341 : 18'd65536;
            default: slev = 18'd0;
        endcase
        if (!has_surr) slev = 18'd0;
    end
    wire [18:0] lvl_den = 19'd131072 + {2'b00, clev[16:0]} + {2'b00, slev[16:0]};
    always_comb begin
        case (lvl_den)
            19'd131072: lvl_q = 16'd32768;   // 2.000000  (no downmix: acmod 1,2)
            19'd177413: lvl_q = 16'd24209;   // 1.477592
            19'd196608: lvl_q = 16'd21845;   // 1.333333
            19'd209005: lvl_q = 16'd20550;   // 1.254248
            19'd223754: lvl_q = 16'd19195;   // 1.171572
            19'd242949: lvl_q = 16'd17678;   // 1.079008
            19'd255346: lvl_q = 16'd16820;   // 1.026623
            19'd262144: lvl_q = 16'd16384;   // 1.000000
            19'd270095: lvl_q = 16'd15902;   // 0.970562
            19'd274541: lvl_q = 16'd15644;   // 0.954845
            19'd289290: lvl_q = 16'd14847;   // 0.906163
            19'd301687: lvl_q = 16'd14237;   // 0.868927
            19'd316436: lvl_q = 16'd13573;   // 0.828427  (3/2 at clev=slev=.707)
            default:    lvl_q = 16'd16384;   // unreachable: the conservative 1.0
        endcase
    end

    // ---- status ----
    always_ff @(posedge clk) begin
        if (rst) begin
            synced <= 1'b0; frame_ok <= 1'b0; refused <= 1'b0; err_code <= 5'd0;
        end else begin
            frame_ok <= e_fend;
            refused  <= e_ref;
            if (e_ref) err_code <= e_rcode;
            if (e_fend) synced <= 1'b1;
        end
    end

endmodule
