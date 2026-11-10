/*
 * disp_vscale.sv — DVD-FORK (CRT anamorphic "Letterbox" — anti-aliased vertical downscale)
 *
 * A small CLK-DOMAIN vertical resampler inserted between resample_bilinear and disp_hstretch
 * (resample_bilinear -> disp_vscale -> disp_hstretch -> pixel_queue), used by the Analog
 * Aspect "Letterbox" display mode (emu's analog_letterbox: the interlaced raster, or an
 * explicit Letterbox on Progressive since feature/progressive-aspect). It downscales the source picture vertically by exactly 3/4
 * (480 -> 360 progressive, 240 -> 180 per field) with a TRUE 2-tap bilinear blend of the two
 * straddling SOURCE lines, so anamorphic 16:9 content shows at the right geometry WITHOUT the
 * banding of the old nearest-neighbour (line-drop) letterbox.
 *
 * WHY DOWNSTREAM (not the in-place resample_addrgen surgery): the alternative — threading a
 * SECOND luma-line fetch through resample_addrgen/resample_dta/resample_bilinear so the blend
 * has two lines — touches three fragile core modules AND adds ~25% display read bandwidth.
 * Here resample_addrgen instead emits FIT vertically (all 480 / 240 lines, NO extra read
 * bandwidth vs Fit) and this module blends adjacent STREAM lines using a one-line buffer. It
 * mirrors dvd/disp_hstretch.sv (the horizontal Crop stretcher) but on the vertical axis.
 *
 * FIELD PATH (480i): when the decoder is in NATIVE-FIELDS mode (`interlaced=1`, i.e. O[10:9]
 * Video Output = Interlaced; was Interlaced Out / Native Fields) resample_addrgen emits a whole field's lines
 * contiguously (all one parity), so "adjacent stream lines" are adjacent SAME-FIELD source
 * lines — blending them is parity-safe (no inter-field comb / twitter) for both film (rff 3:2)
 * and true-interlaced content. Each field is an independent resampling pass, re-armed on its
 * ROW_0_COL_0 (top) / ROW_1_COL_0 (bottom) frame-top code.
 *
 * ⚠ CORRECTION (2026-08-22): the paragraph above was written for the RETIRED O[14] whole-core
 * CRT mode and silently stopped applying to the DEFAULT analog path when the dual-raster rework
 * landed. There, `il_eff` is FORCED OFF while the analog raster is engaged (dvd/emu.sv), so the
 * addrgen takes the `deinterlace && ~interlaced` branch and emits a WOVEN progressive FRAME —
 * "adjacent stream lines" are then OPPOSITE parity, i.e. the two source fields. Consequences:
 *   - film (progressive_frame=1): harmless. Both "fields" of a weave frame are the same instant,
 *     so the blend is an ordinary vertical resample.
 *   - true-interlaced content: the blend genuinely CROSS-FADES two time instants. It is not a
 *     deinterlacer and not a correctness bug (it softens rather than combs), but it is real.
 * Only Letterbox (disp_vscale_en = analog_letterbox, i.e. Auto-on-16:9 or manual) reaches this;
 * Fit and Crop never blend vertically. Video Output = Interlaced restores the parity-safe
 * premise, because it puts the decoder back on the field path. See docs/analog_dual_raster.md.
 * ★ 2026-10 (feature/progressive-aspect): the woven-frame case is LIVE AGAIN — an explicit
 * Letterbox on Video Output = Progressive puts this module on the progressive FRAME path, the
 * same cross-fade trade-off as above for true-interlaced content (and Deinterlace = Bob/Blend,
 * when chosen, runs ahead of it in field_blend). Auto/Fit on Progressive never reach it.
 *
 * ★ FRAME-PATH POSITION CODES (the §11 latent defect, fixed 2026-10, docs/crt_anamorphic.md).
 * A FRAME scan from resample_addrgen tags line 0 ROW_0_COL_0 AND line 1 ROW_1_COL_0 (its
 * disp_y_sat walk 0 -> 1 -> 2); a FIELD scan tags only line 0, with its field's code. This
 * module used to take the frame's second code for a new scan: it re-armed the Bresenham at
 * source line 1 (359 output lines, source line 0 dropped) and tagged output line 1 ROW_X_COL_0,
 * which the mixer refuses at disp_v_offset+1 (mixer.v display_first_pixel) -- one black line
 * under the top bar. Now, as in dvd/field_blend.sv: a ROW_1_COL_0 that directly follows a
 * ROW_0_COL_0 line is the frame's line 1, not a scan start (in_prev_row0 on the input side,
 * so routing/mode/sideband are decided once per scan; h_prev_row0 on the head side, so the
 * Bresenham is armed once), and output line 1 of such a scan carries ROW_1_COL_0. A field
 * scan never pairs, so the field path is bit-identical (bench/dvd/run_vscale_frame.sh).
 *
 * BARS: unchanged. This module just emits the 360 / 180 CONTENT lines (carrying the scan's
 * original frame-top code on output line 0 so the mixer's parity placement is preserved); the
 * mixer's disp_v_offset (vertical_size/8) centres them with the black bars. Not re-invented here.
 *
 * PASS-THROUGH: when vscale_en is low (Fit / Crop / Auto on Progressive) the module is a PURE
 * COMBINATIONAL wire pass-through (FIFO + line buffer idle) — bit-identical to a direct
 * resample_bilinear -> disp_hstretch connection. Fit and Crop are therefore unaffected.
 *
 * ★ PAUSE FIELD STILL (2026-09-18, docs/field_parity.md "Pause shows one field"). The same
 * line buffer + 2-tap blend also serves a SECOND job: while paused on a true-interlaced
 * picture, resample_addrgen pins one source field and, for the opposite raster slot, emits
 * that field's H lines with one end duplicated (H+1). This module averages each of those
 * lines with the previous one (HALF mode: skip line 0, f = 1/2 on every later line) so the
 * off-parity slot carries the field interpolated to its true half-line position — a steady
 * field still on a CRT and under HDMI Bob, instead of the two fields of the held frame
 * alternating at 30 Hz.
 *   The mode is per SCAN, and the scan's mode is not visible in the pixel stream, so the
 * addrgen pushes one bit per frame-top scan (scan_start/scan_half) into a small queue here
 * and this module pops one per frame-top PIXEL it receives: the bit stays aligned with its
 * scan however many lines the resample pipeline holds between the two modules.
 *   Four per-scan modes, carried on each queued pixel (so a scan keeps its mode while it
 * drains): LETTERBOX (the original, vscale_en), HALF (the still), LETTERBOX-HALF (the still
 * under Letterbox: the same 3/4 walk with its phase advanced half a source line, so the
 * Bresenham remainder counts SIXTHS now — plain Letterbox still lands only on 0, 1/3, 2/3)
 * and PLAIN (the scan is simply passed through the buffered path — used for a scan that
 * arrives while the buffered path still holds an earlier one, so output order is kept).
 *   ROUTING is decided at each frame-top pixel: through the buffered path if Letterbox is on,
 * the scan is HALF, or the buffered path is not yet fully drained; otherwise the old
 * combinational pass-through. With Letterbox off and no still, the buffered path is idle and
 * the module is the same wire it always was.
 *
 * ★ THREE RATIOS (2026-11, Standard Convert, docs/standard_convert.md "Phase 3 plan"). A per-scan
 * `vscale_ratio` picks 0 = 3/4 (Letterbox, as before), 1 = 5/6 (PAL 576 -> NTSC 480, Fit and
 * Crop) or 2 = 5/8 (576 -> 360, Letterbox under conversion, ONE pass rather than 5/6 then 3/4).
 * The remainder counts SIXTIETHS of a source line, which holds every step (4/3 = 80/60,
 * 6/5 = 72/60, 8/5 = 96/60) and every phase below. The old sixths are r = 0, 10, ..., 50, and
 * the weight (r*273 + 32) >> 6 = round(256*r/60) gives exactly the old 0/43/85/128/171/213
 * there, so ratio 0 is bit-identical (bench/dvd/run_vscale_frame.sh's field/frame arms).
 * The ratio rides the input FIFO beside the mode, like the mode, so a ratio change lands on the
 * next scan and cannot tear one.
 *
 * ★ BOTTOM-FIELD PHASE (ratios 1 and 2). Output frame line y reads source frame position y*S
 * (S = source lines per output line). A bottom-field output line 2i+1 therefore lands on
 * bottom-field source line i*S + (S-1)/2: 1/10 of a field line at 5/6, 3/10 at 5/8. Starting
 * the bottom field at 0 bobs fine detail up and down by that much every field. A bottom field
 * is a scan whose frame-top is ROW_1_COL_0 (a frame scan's top is always ROW_0_COL_0, so the
 * frame path is never shifted). ⚠ Ratio 0 still starts its bottom field at 0, which is the
 * same error at 1/6: kept bit-identical here and fixed in its own change.
 *
 * ★ UPSCALE (2026-11-09, Standard Convert To PAL, docs/standard_convert.md "Phase 4 plan"). Ratio
 * 3 = 6/5 (NTSC 480 -> PAL 576, Fit and Crop) and ratio 4 = 9/10 (480 -> 432, Letterbox). 9/10's
 * step (10/9) is not a whole number of sixtieths, so the remainder now counts 180ths; the weight
 * (r*91 + 32) >> 6 is round(256*r/180) at every reachable remainder and equals the old sixtieths
 * formula at r = 3*r60, so ratios 0-2 are bit-identical.
 *   A downscale makes at most one output line per incoming line, produced while that line
 * arrives. 6/5 makes six from five: about one source pair in five owes a SECOND output line. A
 * second line buffer (buf2) keeps a copy of the incoming line, so once the line has been
 * consumed a REPLAY line reads the pair from both buffers with no input arriving (input is held
 * off, and resample back-pressured through the FIFO, for the ~W cycles it takes). Two edges:
 *   - a bottom field starts at -1/12 of a field line (output 2i+1 at i*5/6 - 1/12), which is
 *     clamped: output 0 is source line 0 unblended, emitted as line 0 arrives, and the walk
 *     carries on from 3/4 (r = 135).
 *   - the last outputs land at or past the last source line. A downscale never needs them; here
 *     they are TAIL replays of the last line alone, until the scan has N*6/5 lines. N comes from
 *     `src_lines` (the stream's frame height; a field scan is half, the pause still's HALF scan
 *     one more).
 *
 * ★ OTHER-PARITY FIELDS (2026-11-09, To PAL field-accurate video, "Phase 4b"). resample_addrgen
 * may read a field into the OTHER parity's slot (scan_xpar, queued like scan_half). Output line i
 * of a slot of parity op shows source frame position (2i + op)*S, and a source field of parity sp
 * has its line j at 2j + sp, so j = i*S + (op*S - sp)/2: 0 and (S-1)/2 natively, S/2 for a top
 * field in a bottom slot (5/12 at 6/5, 5/9 at 9/10) and -1/2 for a bottom field in a top slot
 * (clamped like the native -1/12: output 0 is line 0, then 1/3 or 11/18). 9/10 is bounded too
 * (N*9/10 lines, the tail replay) because the 5/9 start runs out of lines one output early.
 *
 * EXACT 3/4 (drift-free) via a Bresenham phase machine over the 4/3 source step: output line
 * i has source base k_i and fractional weight f_i in {0, 1/3, 2/3}, generated by
 *   k=0,r=0 ; each output: k+=1,r+=1 ; if r==3 { r=0; k+=1 }
 * so k = 0,1,2,4,5,6,8,... (every 4th source line is used only as the k+1 upper tap).
 * (Implemented since 2026-09-18 with the remainder in SIXTHS — r += 2 per output, carry at 6
 * — which lands on the same 0/2/4 = 0, 1/3, 2/3 for plain Letterbox; the pause still's
 * M_LBH mode starts at r = 3 to sample half a source line later.) Output
 * line i is produced while RECEIVING source line k_i+1 (its k_i line is buffered), blending
 *   out = src[k_i]*(1-f_i) + src[k_i+1]*f_i
 * = buffered_line*(1-f) + incoming_line*f, pixel by pixel at the same column. Total outputs =
 * 3/4 of the input line count; the last output (i=dst-1) needs at most src[src-1] (in range).
 *
 * FLOW CONTROL: resample_bilinear writes a whole macroblock (15-17 px) as an UNINTERRUPTIBLE
 * burst (re-checks almost_full only at MB start), so the incoming stream is absorbed by an
 * input fifo_sc (>= one-MB prog_full margin) + fwft_reader; the read side drains it, and since
 * this is a DOWNSCALE (fewer output than input lines) the input fills faster than the output
 * drains, so it back-pressures resample via prog_full (fine — Fit does too when the queue
 * fills). Sim: bench/dvd/resample_chain_tb.sv (+vsmode=1, progressive and +crt field, incl.
 * +linetag proving the 2-tap blend is real; +exact=1 scores the progressive band with no
 * tolerance) and bench/dvd/disp_vscale_frame_tb.sv (golden blend values + position codes,
 * frame and field scans, mid-scan Letterbox toggles).
 */

`include "timescale.v"

module disp_vscale (
  input             clk,
  input             clk_en,
  input             rst,             // synchronous, active low

  input             vscale_en,       // 1 = scale (blend active); 0 = pure pass-through
  input       [2:0] vscale_ratio,    // 0 = 3/4 (Letterbox), 1 = 5/6, 2 = 5/8, 3 = 6/5 up, 4 = 9/10 (Standard Convert)
  input      [11:0] src_lines,       // stream frame height (vertical_size): bounds an upscale scan
  input             scan_start,      // pause field still: resample_addrgen starts a frame-top scan
  input             scan_half,       //   ... and that scan is the interpolated (HALF) slot
  input             scan_xpar,       // To PAL field-accurate: that scan is a field of the OTHER parity

  /* from resample_bilinear */
  input       [7:0] in_y,
  input       [7:0] in_u,
  input       [7:0] in_v,
  input       [7:0] in_osd,
  input       [2:0] in_pos,
  input             in_wr,
  output            in_almost_full,  // backpressure to resample

  /* to disp_hstretch / pixel_queue */
  output      [7:0] out_y,
  output      [7:0] out_u,
  output      [7:0] out_v,
  output      [7:0] out_osd,
  output      [2:0] out_pos,
  output            out_wr,
  input             out_almost_full
  );

`include "resample_codes.v"

  /* Per-scan modes. M_LBH is Letterbox for the pause still's interpolated slot: the same
   * 4/3 step, its phase advanced half a source line (the addrgen hands it the pinned field
   * with one end duplicated, exactly as for M_HALF). */
  localparam [1:0] M_LB = 2'd0, M_HALF = 2'd1, M_PLAIN = 2'd2, M_LBH = 2'd3;

  /* ---- pause-field-still sideband: one bit per frame-top scan, in scan order ----
   * Depth 4: a scan needs every one of its ~240 lines through the resample pipeline before
   * the next can start, so no more than two frame-tops are ever between the modules. */
  reg   [3:0] sb_q;
  reg   [3:0] sbx_q;                   // scan_xpar, in step with sb_q
  reg   [2:0] sb_n;
  /* DVD-FORK FIX (progressive Letterbox, feature/progressive-aspect): a FRAME scan carries
   * TWO row codes -- ROW_0_COL_0 on line 0 AND ROW_1_COL_0 on line 1 (resample_addrgen's
   * disp_y_sat walk) -- and the second is NOT a frame top. A FIELD scan carries one, and a
   * bottom field's ROW_1_COL_0 never follows a ROW_0_COL_0 line, so the field path is
   * untouched. Same convention as dvd/field_blend.sv (in_prev_row0 / h_prev_row0). Taking
   * the second code for a new scan re-decided the scan's route and mode at line 1 (a
   * Letterbox change landing there tore the frame) and popped the sideband twice. */
  reg         in_prev_row0;
  wire        in_col0 = (in_pos == ROW_0_COL_0) || (in_pos == ROW_1_COL_0) || (in_pos == ROW_X_COL_0);
  wire        in_ft   = (in_pos == ROW_0_COL_0) || ((in_pos == ROW_1_COL_0) && ~in_prev_row0);
  wire        ft_arr  = in_wr & clk_en & in_ft;            // a frame-top pixel arrives
  always @(posedge clk)
    if (~rst) in_prev_row0 <= 1'b0;
    else if (in_wr && clk_en && in_col0) in_prev_row0 <= (in_pos == ROW_0_COL_0);
  wire        sb_half = (sb_n != 3'd0) & sb_q[0];          // the arriving scan is HALF
  wire        sb_xpar = (sb_n != 3'd0) & sbx_q[0];         // ... or reads the other parity
  wire  [3:0] sb_pop  = ft_arr && (sb_n != 3'd0) ? {1'b0, sb_q[3:1]} : sb_q;
  wire  [3:0] sbx_pop = ft_arr && (sb_n != 3'd0) ? {1'b0, sbx_q[3:1]} : sbx_q;
  wire  [2:0] sb_npop = ft_arr && (sb_n != 3'd0) ? sb_n - 3'd1 : sb_n;
  always @(posedge clk)
    if (~rst) begin sb_q <= 4'd0; sbx_q <= 4'd0; sb_n <= 3'd0; end
    else begin
      sb_q <= sb_pop;
      sbx_q <= sbx_pop;
      sb_n <= sb_npop;
      if (clk_en && scan_start && (sb_npop != 3'd4)) begin
        sb_q[sb_npop[1:0]] <= scan_half;
        sbx_q[sb_npop[1:0]] <= scan_xpar;
        sb_n <= sb_npop + 3'd1;
      end
    end

  /* ---- routing ----
   * path_busy: the buffered path still holds pixels (ibuf, fwft stages, blend pipeline).
   * Held for a few idle cycles after the last sign of activity, which covers the one-cycle
   * lags of fifo_sc's empty flag and the fwft read without modelling them exactly. */
  wire        fifo_empty;
  reg   [2:0] idle_cnt;
  wire        path_busy = (idle_cnt != 3'd7);
  /* scan route/mode, decided at the frame-top pixel; later pixels of the scan follow it */
  wire        ft_route = vscale_en | sb_half | path_busy;
  wire  [1:0] ft_mode  = sb_half ? (vscale_en ? M_LBH : M_HALF) : vscale_en ? M_LB : M_PLAIN;
  reg         scan_route;
  reg   [1:0] scan_mode_in;
  reg   [2:0] scan_ratio_in;
  reg         scan_xp_in;
  always @(posedge clk)
    if (~rst) begin scan_route <= 1'b0; scan_mode_in <= M_LB; scan_ratio_in <= 3'd0; scan_xp_in <= 1'b0; end
    else if (ft_arr) begin scan_route <= ft_route; scan_mode_in <= ft_mode; scan_ratio_in <= vscale_ratio; scan_xp_in <= sb_xpar; end
  wire        route_px = in_ft ? ft_route : scan_route;
  wire  [1:0] mode_px  = in_ft ? ft_mode  : scan_mode_in;
  wire  [2:0] ratio_px = in_ft ? vscale_ratio : scan_ratio_in;
  wire        xp_px    = in_ft ? sb_xpar : scan_xp_in;

  /* ---- input FIFO (absorbs the resample macroblock bursts) + FWFT reader ---- */
  wire        fifo_prog_full;
  wire        fifo_rvalid;
  wire [40:0] fifo_dout;               // {xpar, ratio, mode, y, u, v, osd, pos}
  wire        fifo_rd_en;
  wire        ibuf_wr = route_px & in_wr & clk_en;

  fifo_sc #(.addr_width(9'd7), .dta_width(9'd41), .prog_thresh(9'd64))   // 128 deep, 64 margin
  ibuf (
    .clk(clk), .rst(rst),
    .din({xp_px, ratio_px, mode_px, in_y, in_u, in_v, in_osd, in_pos}),
    .wr_en(ibuf_wr),
    .full(), .wr_ack(), .overflow(), .prog_full(fifo_prog_full),
    .dout(fifo_dout), .rd_en(fifo_rd_en),
    .empty(fifo_empty), .valid(fifo_rvalid), .underflow(), .prog_empty()
    );

  /* first-word fall-through: `head`/`head_valid` present the next pixel with no read
   * latency; popped by `head_pop`. Same pattern as disp_hstretch (avoids the read-latency
   * bubble that would otherwise starve the output). */
  wire [40:0] head;
  wire        head_valid;
  reg         head_pop;
  fwft_reader #(.dta_width(9'd41)) fr (
    .rst(rst), .clk(clk), .clk_en(clk_en),
    .fifo_rd_en(fifo_rd_en), .fifo_valid(fifo_rvalid), .fifo_dout(fifo_dout),
    .valid(head_valid), .dout(head), .rd_en(head_pop)
    );

  wire  [7:0] h_y   = head[34:27];
  wire  [7:0] h_u   = head[26:19];
  wire  [7:0] h_v   = head[18:11];
  wire  [7:0] h_osd = head[10:3];
  wire  [2:0] h_pos = head[2:0];
  wire  [1:0] h_mode = head[36:35];    // per-pixel copy of its scan's mode (set at routing)
  wire  [2:0] h_ratio = head[39:37];   // ... and of its ratio
  wire        h_xp    = head[40];      // ... and whether it reads the other parity
  wire        h_col0 = (h_pos == ROW_0_COL_0) || (h_pos == ROW_1_COL_0) || (h_pos == ROW_X_COL_0);
  reg         h_prev_row0;             // the last line start consumed was ROW_0_COL_0
  wire        h_ft   = (h_pos == ROW_0_COL_0) || ((h_pos == ROW_1_COL_0) && ~h_prev_row0);   // frame/field top => new scan
  wire        h_pair = (h_pos == ROW_1_COL_0) && h_prev_row0;   // a FRAME scan's line 1 (see in_ft)
  wire        h_last = (h_pos == ROW_X_COL_LAST);

  /* ---- one-source-line buffer (ping-pong two banks in one BRAM) ----
   * addr = {bank, col}, 32 bits {y,u,v,osd}. Write the line being received into wr_bank;
   * read the PREVIOUS line (rd_bank) for the blend. bank flips per source line, so read and
   * write never touch the same bank in the same line. Max width 720 (mb_width 45 * 16). */
  reg  [31:0] linebuf [0:2047];
  reg  [31:0] rd_data;                 // registered read (src[k] pixel = buffered prev line)

  /* ---- persistent per-scan / per-line state ---- */
  reg         seen_frametop;           // a scan has started (armed by the first frame-top)
  reg   [2:0] scan_ft_code;            // the scan's frame-top code (ROW_0_COL_0 / ROW_1_COL_0)
  reg  [11:0] sline;                   // source line index currently being received (0-based)
  reg         wr_bank, rd_bank;        // buffer banks: write incoming / read previous
  reg  [11:0] next_k;                  // Bresenham: source base line of the next output line
  reg   [7:0] next_r;                  // Bresenham remainder 0..179 (weight numerator over 180THS)
  reg  [11:0] emitted_cnt;             // output lines emitted so far this scan
  reg         line_emit;               // this source line produces an output line
  reg         line_first;              // that output line is output-line 0 of the scan
  reg   [7:0] line_f;                  // blend weight (Q0.8) held for the whole line
  reg  [10:0] col;                     // column of the pixel currently being processed
  reg   [1:0] scan_mode;               // mode of the scan being processed (latched at its frame-top)
  reg   [2:0] scan_ratio;              // ... and its ratio
  reg         line_pre;                // this line is an upscale bottom field's clamped output 0 (unblended)
  reg         scan_frame;              // this scan is a FRAME (its line 1 carried the paired ROW_1_COL_0)

  /* f from the Bresenham remainder, in SIXTHS of a source line (DVD-FORK pause field still,
   * 2026-09-18: was thirds). The plain Letterbox walk only ever lands on r = 0/2/4, whose
   * weights 0/85/171 are the thirds values it always used — bit-identical. M_LBH starts at
   * r = 3 (half a line) and so also visits 1/3/5. A wire, not a function: see the
   * verilog-function hazards recorded in CLAUDE.md. */
  /* (2026-11) sixtieths: (r*273 + 32) >> 6 = round(256*r/60) at every reachable remainder (all are
   * multiples of 6; only r = 47 would round down), and the old sixths table exactly. */
  /* (2026-11-09) 180ths: (r*91 + 32) >> 6 = round(256*r/180) at every reachable remainder, and
   * at r = 3*r60 it is the sixtieths formula (r60*273 + 32) >> 6 exactly. */
  wire [14:0] f_prod = {7'd0, next_r} * 15'd91 + 15'd32;
  wire  [7:0] f_nr_c = f_prod[13:6];
  /* the step per ratio (1 + frac/180 source lines; the upscale's is 0 + 150/180 = 5/6), and the
   * bottom field's starting phase (header). The upscale's -1/12 is the clamp below, not a phase. */
  wire  [7:0] step_frac  = (scan_ratio == 3'd1) ? 8'd36  : (scan_ratio == 3'd2) ? 8'd108 :
                           (scan_ratio == 3'd3) ? 8'd150 : (scan_ratio == 3'd4) ? 8'd20  : 8'd60;
  wire        step_int   = (scan_ratio != 3'd3);
  wire  [8:0] step_sum   = {1'b0, next_r} + {1'b0, step_frac};
  wire        step_cy    = (step_sum >= 9'd180);
  wire  [7:0] step_r_c   = step_cy ? (step_sum[7:0] - 8'd180) : step_sum[7:0];
  wire [11:0] step_k_c   = next_k + {11'd0, step_int} + {11'd0, step_cy};
  wire  [7:0] bot_phase  = (h_ratio == 3'd1) ? 8'd18 : (h_ratio == 3'd2) ? 8'd54 :
                           (h_ratio == 3'd4) ? 8'd10 : 8'd0;
  /* ---- To PAL bounds: N source lines and N*6/5 (6/5) or N*9/10 (9/10) output lines a scan ----
   * N*205 >> 10 = N/5 and N*205 >> 11 = N/10 for every N a converted stream has (240, 480). */
  wire        scan_up    = ((scan_ratio == 3'd3) | (scan_ratio == 3'd4)) & ((scan_mode == M_LB) | (scan_mode == M_LBH));
  wire        h_up       = (h_ratio == 3'd3) & ((h_mode == M_LB) | (h_mode == M_LBH));
  wire        h_bnd      = ((h_ratio == 3'd3) | (h_ratio == 3'd4)) & (h_mode == M_LB);
  wire [11:0] up_n       = scan_frame ? src_lines : {1'b0, src_lines[11:1]};
  wire [21:0] up_n205    = {10'd0, up_n} * 22'd205;
  wire [11:0] up_m_c     = (scan_ratio == 3'd4) ? (up_n - {1'b0, up_n205[21:11]}) : (up_n + up_n205[21:10]);
  wire [11:0] up_last_c  = up_n - 12'd1 + {11'd0, scan_mode == M_LBH};   // the HALF stream has one more line
  /* ★ TIMING (2026-11-09: 74.9 MHz against 86 with these combinational). Everything the walk
   * decides from is REGISTERED one cycle ahead: the bounds, the next step, the weight and the
   * three compares. Exact, not approximate: they are read only at a line start (col0), at a
   * line's last pixel, or at a replay's last pixel, and next_k/next_r/sline/emitted_cnt/scan_*
   * change only at a line start, a scan start or a replay start, each of which is a whole line
   * (>= one macroblock of pixels, or a replay of the same width) before the next read. */
  reg  [11:0] up_m, up_last;
  reg   [7:0] f_nr, step_r;
  reg  [11:0] step_k;
  reg         up_room, k_eq_sline, k_eq_prev, sline_last;
  always @(posedge clk) begin
    up_m       <= up_m_c;
    up_last    <= up_last_c;
    f_nr       <= f_nr_c;
    step_r     <= step_r_c;
    step_k     <= step_k_c;
    up_room    <= (emitted_cnt < up_m_c);
    k_eq_sline <= (next_k == sline);
    k_eq_prev  <= (next_k == sline - 12'd1);
    sline_last <= (sline == up_last_c);
  end

  /* combinational "effective" line/bank/column for the CURRENT head pixel. These are stable
   * from the S_READ cycle through the S_BLEND commit (head is not popped and the persistent
   * regs are not updated until commit), so they can drive the read address and be reused in
   * S_BLEND directly. */
  wire        e_rd_bank = h_col0 ? (h_ft ? 1'b1 : wr_bank) : rd_bank;
  wire        e_wr_bank = h_col0 ? (h_ft ? 1'b0 : ~wr_bank) : wr_bank;
  wire [10:0] e_col     = h_col0 ? 11'd0 : col;
  /* emit decision (only meaningful at a line start): a new non-frame-top line produces an
   * output iff the buffered previous line (sline) is the next output's base line k. */
  /* Per mode: LB = the Bresenham schedule; HALF = every line but the first (output k is
   * the average of lines k and k+1); PLAIN = every line including the first, unblended. */
  wire  [1:0] e_mode       = h_ft ? h_mode : scan_mode;
  wire        e_plain      = (e_mode == M_PLAIN);
  /* an upscale bottom field (not the pause still's HALF scan) emits line 0 itself: output 0
   * clamped to source line 0 */
  wire        e_upre       = h_ft ? ((h_up & (h_pos == ROW_1_COL_0) & (h_mode == M_LB) & ~h_xp) |
                                     (h_bnd & (h_pos == ROW_0_COL_0) & h_xp))
                                  : (h_col0 ? 1'b0 : line_pre);
  /* where the walk resumes after a clamped output 0 (-1/12 + 5/6, -1/2 + 5/6, -1/2 + 10/9), and
   * a top field's start in a bottom slot (5/12, 5/9) */
  wire  [7:0] e_upre_r     = ~h_xp ? 8'd135 : (h_ratio == 3'd4) ? 8'd110 : 8'd60;
  wire  [7:0] xp_bot_r     = (h_ratio == 3'd4) ? 8'd100 : 8'd75;
  wire        e_line_emit  = h_ft ? (e_plain | e_upre)
                           : (h_col0 ? (seen_frametop && (e_plain || (e_mode == M_HALF) ||
                                                          (k_eq_sline && (~scan_up || up_room))))
                                     : line_emit);
  wire        e_line_first = h_ft ? (e_plain | e_upre)
                           : (h_col0 ? (emitted_cnt == 12'd0) : line_first);
  /* output line 1 (meaningful at a non-frame-top line start that emits) */
  wire        e_line_second = ~h_ft & (emitted_cnt == 12'd1);
  wire  [7:0] e_f          = h_col0 ? ((e_mode == M_HALF) ? 8'd128 : f_nr) : line_f;

  /* ---- replay (upscale): a second output line from the pair just received, or a tail line ----
   * Due once the line has been consumed: the walk still sits on the buffered line (pair: k = the
   * line before the one just received), or on the last line of the scan (tail). Both read
   * linebuf for `a` and buf2 for `b`; a tail reads the bank the last line went into, so a = b. */
  reg         rp_active, rp_tail, rp_first, rp_second;
  reg  [10:0] rp_col, rp_wm1;
  reg   [7:0] rp_f;
  wire        rp_pair_due = scan_up & up_room & k_eq_prev;
  wire        rp_tail_due = scan_up & up_room & sline_last & k_eq_sline;
  wire        rp_due      = rp_pair_due | rp_tail_due;
  wire        rp_issue    = rp_active & ~out_almost_full;
  wire        rp_end      = rp_issue & (rp_col == rp_wm1);
  wire [10:0] bram_rd_addr = rp_active ? {rp_tail ? wr_bank : rd_bank, rp_col[9:0]}
                                       : {e_rd_bank, e_col[9:0]};
  /* buf2: a copy of the line being received (one bank: a replay only ever wants the newest line) */
  reg  [31:0] buf2 [0:1023];
  reg  [31:0] rd2_data, b_q;

  /* ---- 2-tap blend: out = a + f*(b-a)/256, a = buffered prev line, b = incoming ---- */
  /* DVD-FORK FIX (fringe/Fmax, 2026-07-09): a_q re-registers the BRAM read in fabric before
   * the blend. With rd_data alone (packed into the M10K's embedded output register), the
   * single cycle M10K-out -> 4-channel multiply-blend -> r_* was the WORST intra-clk_dec
   * path of the whole domain (11.0 ns of 12.3; STA: top 400 paths all here) and set the
   * 81.41/78.0 MHz Fmax that produces the chroma-fringe placement lottery. The extra stage
   * splits it: M10K -> a_q (short hop) and a_q -> blend -> r_* (mult+add only). Costs one
   * cycle of latency (out_almost_full skid margin is 32 slots at the pixel_queue — fine)
   * and is invisible downstream (out_wr strobes one cycle later). */
  reg  [31:0] a_q;
  always @(posedge clk)
    if (clk_en) a_q <= rd_data;
  wire  [7:0] a_y = a_q[31:24], a_u = a_q[23:16], a_v = a_q[15:8], a_o = a_q[7:0];
  function [7:0] blend8;
    input [7:0] a; input [7:0] b; input [7:0] f;
    reg signed [17:0] d, p;
    begin
      d = $signed({10'd0, b}) - $signed({10'd0, a});
      p = d * $signed({1'b0, f}) + 18'sd128;
      blend8 = $signed({10'd0, a}) + (p >>> 8);
    end
  endfunction
  /* output position: same column boundaries as the source line (vertical scale only), with
   * the scan frame-top code on output-line 0 (parity marker the mixer needs).
   * DVD-FORK FIX (progressive Letterbox): on a FRAME scan output line 1 carries ROW_1_COL_0,
   * as the source frame's line 1 did. It is the mixer's contract (mixer.v display_first_pixel
   * REFUSES a ROW_X_COL_0 line start at disp_v_offset+1), so a ROW_X there slips the rest of
   * the picture down a line and leaves a black line under the top bar. A field scan keeps
   * ROW_X_COL_0 on line 1, exactly as before. */
  wire  [2:0] blend_pos = (e_plain | e_upre) ? h_pos
                        : h_col0 ? (e_line_first ? scan_ft_code
                                    : (e_line_second && scan_frame) ? ROW_1_COL_0 : ROW_X_COL_0)
                        : h_last ? ROW_X_COL_LAST : ROW_X_COL_X;

  /* ---- 1 pixel / clk pipeline ------------------------------------------------------
   * A downscale must keep up with the raster during the content band (the pixel_queue can't
   * buffer a whole frame), so a 2-cycle-per-pixel machine (which drops below the ~0.42 px/clk
   * the mixer drains per content line) underruns. Instead: CONSUME one input pixel per clk
   * whenever the head is present and the queue is not almost-full, issuing the buffer read for
   * src[k] the same cycle; ONE cycle later the read data is ready and the blend is registered
   * out. Back-pressure is by GATING the consume on out_almost_full — the queue's prog_full has
   * enough margin to absorb the single in-flight pixel that drains after almost_full asserts
   * (the same skid the resample/hstretch stages rely on). No mid-pipe stall, no read hazard. */
  wire        consume = head_valid & ~out_almost_full & ~rp_active;
  always @* head_pop = consume;

  /* buffer read: issue every cycle from the combinational address (only the cycle after a
   * consume feeds a valid stage-2 pixel; otherwise stage-2 is invalid and the data is unused). */
  always @(posedge clk)
    if (clk_en) rd_data <= linebuf[bram_rd_addr];
  always @(posedge clk)
    if (clk_en) rd2_data <= buf2[rp_col[9:0]];
  always @(posedge clk)
    if (clk_en) b_q <= rd2_data;

  /* buffer write: store the incoming pixel into wr_bank at its column, on consume. */
  always @(posedge clk)
    if (clk_en && consume) linebuf[{e_wr_bank, e_col[9:0]}] <= {h_y, h_u, h_v, h_osd};
  always @(posedge clk)
    if (clk_en && consume) buf2[e_col[9:0]] <= {h_y, h_u, h_v, h_osd};

  /* stage 2: the pixel consumed last cycle, awaiting its src[k] read for the blend. */
  reg         s2_valid, s2_emit, s2_plain, s2_rep;
  reg   [7:0] s2_by, s2_bu, s2_bv, s2_bo;   // incoming pixel = src[k+1] (blend b)
  reg   [7:0] s2_f;
  reg   [2:0] s2_pos;

  /* stage 3 (DVD-FORK FIX, see a_q above): the same payload one cycle later, aligned with
   * the fabric-registered read data a_q. The blend now runs s3 x a_q -> r_*. */
  reg         s3_valid, s3_emit, s3_plain, s3_rep;
  reg   [7:0] s3_by, s3_bu, s3_bv, s3_bo;
  reg   [7:0] s3_f;
  reg   [2:0] s3_pos;

  /* registered outputs (clean timing on the tight clk_dec) */
  reg  [7:0]  r_y, r_u, r_v, r_osd;
  reg  [2:0]  r_pos;
  reg         r_wr;

  always @(posedge clk)
    if (~rst) begin
      seen_frametop <= 1'b0; scan_ft_code <= ROW_0_COL_0;
      sline <= 12'd0; wr_bank <= 1'b0; rd_bank <= 1'b1;
      next_k <= 12'd0; next_r <= 8'd0; emitted_cnt <= 12'd0;
      line_emit <= 1'b0; line_first <= 1'b0; line_f <= 8'd0; col <= 11'd0; line_pre <= 1'b0;
      scan_mode <= M_LB; scan_ratio <= 3'd0; h_prev_row0 <= 1'b0; scan_frame <= 1'b0;
      rp_active <= 1'b0; rp_tail <= 1'b0; rp_first <= 1'b0; rp_second <= 1'b0;
      rp_col <= 11'd0; rp_wm1 <= 11'd0; rp_f <= 8'd0;
      s2_valid <= 1'b0; s2_emit <= 1'b0; s2_plain <= 1'b0; s2_rep <= 1'b0; s2_f <= 8'd0; s2_pos <= ROW_X_COL_X;
      s2_by <= 8'd0; s2_bu <= 8'd0; s2_bv <= 8'd0; s2_bo <= 8'd0;
      s3_valid <= 1'b0; s3_emit <= 1'b0; s3_plain <= 1'b0; s3_rep <= 1'b0; s3_f <= 8'd0; s3_pos <= ROW_X_COL_X;
      s3_by <= 8'd0; s3_bu <= 8'd0; s3_bv <= 8'd0; s3_bo <= 8'd0;
      r_wr <= 1'b0;
    end else if (clk_en) begin
      /* -------- stage 1: consume one input pixel, latch it for the blend, advance state ---- */
      s2_valid <= consume | rp_issue;
      s2_rep   <= rp_issue;
      if (rp_issue) begin
        /* replay pixel: b arrives from buf2 (b_q, aligned with a_q); position from the line's rank */
        s2_emit <= 1'b1; s2_plain <= 1'b0; s2_f <= rp_f;
        s2_pos  <= (rp_col == 11'd0) ? (rp_first ? scan_ft_code : (rp_second && scan_frame) ? ROW_1_COL_0 : ROW_X_COL_0)
                 : (rp_col == rp_wm1) ? ROW_X_COL_LAST : ROW_X_COL_X;
        rp_col  <= rp_col + 11'd1;
      end
      /* start a replay as a line is consumed, or chain the next one as a replay ends. The walk
       * advances when the replay is decided, so the next decision sees it. */
      if ((consume && h_last) || rp_end) begin
        rp_active <= rp_due;
        if (rp_due) begin
          rp_tail <= ~rp_pair_due; rp_col <= 11'd0; rp_f <= f_nr;
          rp_first <= (emitted_cnt == 12'd0); rp_second <= (emitted_cnt == 12'd1);
          if (consume) rp_wm1 <= e_col;
          emitted_cnt <= emitted_cnt + 12'd1;
          next_r <= step_r; next_k <= step_k;
        end
      end
      if (consume) begin
        s2_by <= h_y; s2_bu <= h_u; s2_bv <= h_v; s2_bo <= h_osd;
        s2_emit <= e_line_emit; s2_f <= e_f; s2_pos <= blend_pos; s2_plain <= e_plain | e_upre;

        if (h_col0) begin
          col <= 11'd1;                     // next pixel column
          h_prev_row0 <= (h_pos == ROW_0_COL_0);
          if (h_ft) begin                   // ---- new scan (frame/field top) ----
            seen_frametop <= 1'b1; scan_ft_code <= h_pos; scan_mode <= h_mode; scan_ratio <= h_ratio;
            scan_frame <= 1'b0;
            sline <= 12'd0; wr_bank <= 1'b0; rd_bank <= 1'b1;
            /* the pause still's half line keeps its old meaning at every ratio */
            /* the upscale bottom field's clamped output 0 is emitted here; the walk resumes at
             * -1/12 + 5/6 = 3/4 (k = 0, r = 135) */
            next_k <= 12'd0; next_r <= (h_mode == M_LBH) ? 8'd90 : e_upre ? e_upre_r
                                     : (h_bnd & h_xp & (h_pos == ROW_1_COL_0)) ? xp_bot_r
                                     : (h_pos == ROW_1_COL_0) ? bot_phase : 8'd0;
            emitted_cnt <= ((h_mode == M_PLAIN) | e_upre) ? 12'd1 : 12'd0;
            line_emit <= e_line_emit; line_first <= e_line_first; line_f <= 8'd0; line_pre <= e_upre;
          end else begin                    // ---- new line within the scan ----
            if (h_pair) scan_frame <= 1'b1;
            line_emit  <= e_line_emit;
            line_first <= e_line_first;
            line_f     <= e_f;
            line_pre   <= 1'b0;
            if (e_line_emit) begin
              emitted_cnt <= emitted_cnt + 12'd1;
              /* step = step_int + step_frac/180 source lines (every ratio's step is under 2) */
              next_r <= step_r; next_k <= step_k;
            end
            sline   <= sline + 12'd1;
            wr_bank <= ~wr_bank;
            rd_bank <= wr_bank;
          end
        end else begin                      // ---- mid-line pixel ----
          col <= col + 11'd1;
        end
      end

      /* -------- stage 2 -> 3: carry the consumed pixel alongside the a_q read register ---- */
      s3_valid <= s2_valid; s3_emit <= s2_emit; s3_plain <= s2_plain; s3_rep <= s2_rep;
      s3_by <= s2_by; s3_bu <= s2_bu; s3_bv <= s2_bv; s3_bo <= s2_bo;
      s3_f  <= s2_f;  s3_pos <= s2_pos;

      /* -------- stage 3: blend src[k] (a_q) with src[k+1] (latched) and emit -------------- */
      r_y   <= s3_plain ? s3_by : blend8(a_y, s3_rep ? b_q[31:24] : s3_by, s3_f);
      r_u   <= s3_plain ? s3_bu : blend8(a_u, s3_rep ? b_q[23:16] : s3_bu, s3_f);
      r_v   <= s3_plain ? s3_bv : blend8(a_v, s3_rep ? b_q[15:8]  : s3_bv, s3_f);
      r_osd <= s3_plain ? s3_bo : blend8(a_o, s3_rep ? b_q[7:0]   : s3_bo, s3_f);
      r_pos <= s3_pos;
      r_wr  <= s3_valid & s3_emit;
    end

  /* idle detector for the routing decision (see path_busy) */
  always @(posedge clk)
    if (~rst) idle_cnt <= 3'd7;
    else if (ibuf_wr | ~fifo_empty | fifo_rvalid | head_valid | s2_valid | s3_valid | r_wr | rp_active) idle_cnt <= 3'd0;
    else if (idle_cnt != 3'd7) idle_cnt <= idle_cnt + 3'd1;

  /* ---- output mux ----
   * The buffered path drives the output while it holds anything; a pixel only passes
   * straight through when its scan was routed around an IDLE buffered path, so the two
   * sources never both write in one cycle and output order is preserved. With Letterbox
   * off and no still this is the old pure wire pass-through (bit-identical Fit/Crop). */
  wire        bypass_wr     = in_wr & ~route_px;
  assign out_y          = path_busy ? r_y   : in_y;
  assign out_u          = path_busy ? r_u   : in_u;
  assign out_v          = path_busy ? r_v   : in_v;
  assign out_osd        = path_busy ? r_osd : in_osd;
  assign out_pos        = path_busy ? r_pos : in_pos;
  assign out_wr         = path_busy ? r_wr  : bypass_wr;
  assign in_almost_full = (scan_route | path_busy) ? fifo_prog_full : out_almost_full;

endmodule
/* not truncated */
