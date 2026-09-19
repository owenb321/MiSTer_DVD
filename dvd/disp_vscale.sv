/*
 * disp_vscale.sv — DVD-FORK (CRT anamorphic "Letterbox" — anti-aliased vertical downscale)
 *
 * A small CLK-DOMAIN vertical resampler inserted between resample_bilinear and disp_hstretch
 * (resample_bilinear -> disp_vscale -> disp_hstretch -> pixel_queue), used only by the CRT
 * "Letterbox" display mode. It downscales the source picture vertically by exactly 3/4
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
 *
 * BARS: unchanged. This module just emits the 360 / 180 CONTENT lines (carrying the scan's
 * original frame-top code on output line 0 so the mixer's parity placement is preserved); the
 * mixer's disp_v_offset (vertical_size/8) centres them with the black bars. Not re-invented here.
 *
 * PASS-THROUGH: when vscale_en is low (Fit / Crop / non-CRT) the module is a PURE
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
 * +linetag proving the 2-tap blend is real).
 */

`include "timescale.v"

module disp_vscale (
  input             clk,
  input             clk_en,
  input             rst,             // synchronous, active low

  input             vscale_en,       // 1 = Letterbox (blend active); 0 = pure pass-through
  input             scan_start,      // pause field still: resample_addrgen starts a frame-top scan
  input             scan_half,       //   ... and that scan is the interpolated (HALF) slot

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
  reg   [2:0] sb_n;
  wire        in_ft   = (in_pos == ROW_0_COL_0) || (in_pos == ROW_1_COL_0);
  wire        ft_arr  = in_wr & clk_en & in_ft;            // a frame-top pixel arrives
  wire        sb_half = (sb_n != 3'd0) & sb_q[0];          // the arriving scan is HALF
  wire  [3:0] sb_pop  = ft_arr && (sb_n != 3'd0) ? {1'b0, sb_q[3:1]} : sb_q;
  wire  [2:0] sb_npop = ft_arr && (sb_n != 3'd0) ? sb_n - 3'd1 : sb_n;
  always @(posedge clk)
    if (~rst) begin sb_q <= 4'd0; sb_n <= 3'd0; end
    else begin
      sb_q <= sb_pop;
      sb_n <= sb_npop;
      if (clk_en && scan_start && (sb_npop != 3'd4)) begin
        sb_q[sb_npop[1:0]] <= scan_half;
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
  always @(posedge clk)
    if (~rst) begin scan_route <= 1'b0; scan_mode_in <= M_LB; end
    else if (ft_arr) begin scan_route <= ft_route; scan_mode_in <= ft_mode; end
  wire        route_px = in_ft ? ft_route : scan_route;
  wire  [1:0] mode_px  = in_ft ? ft_mode  : scan_mode_in;

  /* ---- input FIFO (absorbs the resample macroblock bursts) + FWFT reader ---- */
  wire        fifo_prog_full;
  wire        fifo_rvalid;
  wire [36:0] fifo_dout;               // {mode, y, u, v, osd, pos}
  wire        fifo_rd_en;
  wire        ibuf_wr = route_px & in_wr & clk_en;

  fifo_sc #(.addr_width(9'd7), .dta_width(9'd37), .prog_thresh(9'd64))   // 128 deep, 64 margin
  ibuf (
    .clk(clk), .rst(rst),
    .din({mode_px, in_y, in_u, in_v, in_osd, in_pos}),
    .wr_en(ibuf_wr),
    .full(), .wr_ack(), .overflow(), .prog_full(fifo_prog_full),
    .dout(fifo_dout), .rd_en(fifo_rd_en),
    .empty(fifo_empty), .valid(fifo_rvalid), .underflow(), .prog_empty()
    );

  /* first-word fall-through: `head`/`head_valid` present the next pixel with no read
   * latency; popped by `head_pop`. Same pattern as disp_hstretch (avoids the read-latency
   * bubble that would otherwise starve the output). */
  wire [36:0] head;
  wire        head_valid;
  reg         head_pop;
  fwft_reader #(.dta_width(9'd37)) fr (
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
  wire        h_col0 = (h_pos == ROW_0_COL_0) || (h_pos == ROW_1_COL_0) || (h_pos == ROW_X_COL_0);
  wire        h_ft   = (h_pos == ROW_0_COL_0) || (h_pos == ROW_1_COL_0);   // frame/field top => new scan
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
  reg   [2:0] next_r;                  // Bresenham remainder 0..5 (weight numerator over SIXTHS)
  reg  [11:0] emitted_cnt;             // output lines emitted so far this scan
  reg         line_emit;               // this source line produces an output line
  reg         line_first;              // that output line is output-line 0 of the scan
  reg   [7:0] line_f;                  // blend weight (Q0.8) held for the whole line
  reg  [10:0] col;                     // column of the pixel currently being processed
  reg   [1:0] scan_mode;               // mode of the scan being processed (latched at its frame-top)

  /* f from the Bresenham remainder, in SIXTHS of a source line (DVD-FORK pause field still,
   * 2026-09-18: was thirds). The plain Letterbox walk only ever lands on r = 0/2/4, whose
   * weights 0/85/171 are the thirds values it always used — bit-identical. M_LBH starts at
   * r = 3 (half a line) and so also visits 1/3/5. A wire, not a function: see the
   * verilog-function hazards recorded in CLAUDE.md. */
  wire  [7:0] f_nr = (next_r == 3'd0) ? 8'd0   : (next_r == 3'd1) ? 8'd43  :
                     (next_r == 3'd2) ? 8'd85  : (next_r == 3'd3) ? 8'd128 :
                     (next_r == 3'd4) ? 8'd171 : 8'd213;

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
  wire        e_line_emit  = h_ft ? e_plain
                           : (h_col0 ? (seen_frametop && (e_plain || (e_mode == M_HALF) || (next_k == sline)))
                                     : line_emit);
  wire        e_line_first = h_ft ? e_plain
                           : (h_col0 ? (emitted_cnt == 12'd0) : line_first);
  wire  [7:0] e_f          = h_col0 ? ((e_mode == M_HALF) ? 8'd128 : f_nr) : line_f;

  wire [10:0] bram_rd_addr = {e_rd_bank, e_col[9:0]};

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
   * the scan frame-top code on output-line 0 (parity marker the mixer needs). */
  wire  [2:0] blend_pos = e_plain ? h_pos
                        : h_col0 ? (e_line_first ? scan_ft_code : ROW_X_COL_0)
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
  wire        consume = head_valid & ~out_almost_full;
  always @* head_pop = consume;

  /* buffer read: issue every cycle from the combinational address (only the cycle after a
   * consume feeds a valid stage-2 pixel; otherwise stage-2 is invalid and the data is unused). */
  always @(posedge clk)
    if (clk_en) rd_data <= linebuf[bram_rd_addr];

  /* buffer write: store the incoming pixel into wr_bank at its column, on consume. */
  always @(posedge clk)
    if (clk_en && consume) linebuf[{e_wr_bank, e_col[9:0]}] <= {h_y, h_u, h_v, h_osd};

  /* stage 2: the pixel consumed last cycle, awaiting its src[k] read for the blend. */
  reg         s2_valid, s2_emit, s2_plain;
  reg   [7:0] s2_by, s2_bu, s2_bv, s2_bo;   // incoming pixel = src[k+1] (blend b)
  reg   [7:0] s2_f;
  reg   [2:0] s2_pos;

  /* stage 3 (DVD-FORK FIX, see a_q above): the same payload one cycle later, aligned with
   * the fabric-registered read data a_q. The blend now runs s3 x a_q -> r_*. */
  reg         s3_valid, s3_emit, s3_plain;
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
      next_k <= 12'd0; next_r <= 3'd0; emitted_cnt <= 12'd0;
      line_emit <= 1'b0; line_first <= 1'b0; line_f <= 8'd0; col <= 11'd0;
      scan_mode <= M_LB;
      s2_valid <= 1'b0; s2_emit <= 1'b0; s2_plain <= 1'b0; s2_f <= 8'd0; s2_pos <= ROW_X_COL_X;
      s2_by <= 8'd0; s2_bu <= 8'd0; s2_bv <= 8'd0; s2_bo <= 8'd0;
      s3_valid <= 1'b0; s3_emit <= 1'b0; s3_plain <= 1'b0; s3_f <= 8'd0; s3_pos <= ROW_X_COL_X;
      s3_by <= 8'd0; s3_bu <= 8'd0; s3_bv <= 8'd0; s3_bo <= 8'd0;
      r_wr <= 1'b0;
    end else if (clk_en) begin
      /* -------- stage 1: consume one input pixel, latch it for the blend, advance state ---- */
      s2_valid <= consume;
      if (consume) begin
        s2_by <= h_y; s2_bu <= h_u; s2_bv <= h_v; s2_bo <= h_osd;
        s2_emit <= e_line_emit; s2_f <= e_f; s2_pos <= blend_pos; s2_plain <= e_plain;

        if (h_col0) begin
          col <= 11'd1;                     // next pixel column
          if (h_ft) begin                   // ---- new scan (frame/field top) ----
            seen_frametop <= 1'b1; scan_ft_code <= h_pos; scan_mode <= h_mode;
            sline <= 12'd0; wr_bank <= 1'b0; rd_bank <= 1'b1;
            next_k <= 12'd0; next_r <= (h_mode == M_LBH) ? 3'd3 : 3'd0;
            emitted_cnt <= (h_mode == M_PLAIN) ? 12'd1 : 12'd0;
            line_emit <= e_line_emit; line_first <= e_line_first; line_f <= 8'd0;
          end else begin                    // ---- new line within the scan ----
            line_emit  <= e_line_emit;
            line_first <= e_line_first;
            line_f     <= e_f;
            if (e_line_emit) begin
              emitted_cnt <= emitted_cnt + 12'd1;
              /* step = 1 + 2/6 source lines (the exact 4/3 of the 3/4 downscale) */
              if (next_r >= 3'd4) begin next_r <= next_r - 3'd4; next_k <= next_k + 12'd2; end
              else                begin next_r <= next_r + 3'd2; next_k <= next_k + 12'd1; end
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
      s3_valid <= s2_valid; s3_emit <= s2_emit; s3_plain <= s2_plain;
      s3_by <= s2_by; s3_bu <= s2_bu; s3_bv <= s2_bv; s3_bo <= s2_bo;
      s3_f  <= s2_f;  s3_pos <= s2_pos;

      /* -------- stage 3: blend src[k] (a_q) with src[k+1] (latched) and emit -------------- */
      r_y   <= s3_plain ? s3_by : blend8(a_y, s3_by, s3_f);
      r_u   <= s3_plain ? s3_bu : blend8(a_u, s3_bu, s3_f);
      r_v   <= s3_plain ? s3_bv : blend8(a_v, s3_bv, s3_f);
      r_osd <= s3_plain ? s3_bo : blend8(a_o, s3_bo, s3_f);
      r_pos <= s3_pos;
      r_wr  <= s3_valid & s3_emit;
    end

  /* idle detector for the routing decision (see path_busy) */
  always @(posedge clk)
    if (~rst) idle_cnt <= 3'd7;
    else if (ibuf_wr | ~fifo_empty | fifo_rvalid | head_valid | s2_valid | s3_valid | r_wr) idle_cnt <= 3'd0;
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
