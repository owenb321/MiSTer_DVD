/*
 * disp_hstretch.sv — DVD-FORK (CRT anamorphic "Crop" / horizontal pan-scan)
 *
 * A small CLK-DOMAIN horizontal RESAMPLER inserted between resample_bilinear and the
 * pixel_queue, used only by the CRT/analog "Crop" display mode. resample_addrgen already reads
 * the CENTRE ~3/4 of the columns (hsrc_width pixels per line, e.g. 528); this stage resamples
 * them up to the full raster width (hdst_width, e.g. 720) with a TRUE 2-TAP LINEAR blend. The
 * mixer then displays the line 1:1 — so the whole dot-domain mixer/pixel_queue path is
 * UNTOUCHED (no risky FSM surgery in the HW-proven mixer). Net effect on the 4:3 CRT: 16:9 at
 * correct aspect, FULL vertical resolution (vertical untouched — Crop is horizontal only),
 * sides cropped, no bars.
 *
 * 2-TAP (2026-07-31): this stage used to DUPLICATE pixels (nearest-neighbour Bresenham), which
 * left a visible ~1.36x stair-step on near-vertical edges — the aliasing docs/crt_anamorphic.md
 * §8 flagged as an open follow-up. It is now an OUTPUT-DRIVEN phase walk, the horizontal twin
 * of dvd/disp_vscale.sv's vertical Letterbox blend:
 *
 *     out[j] = src[k]*(1-f) + src[k+1]*f      where   k + f = j*hsrc/hdst
 *
 * i.e. display pixel j samples the EXACT source position j*hsrc/hdst, blending the two
 * straddling source pixels. Per output the walk advances 256*hsrc/hdst source pixels in Q0.8.
 * That step is decomposed ONCE (it only changes at a sequence header / mode toggle) into
 *   qstep = floor(256*hsrc/hdst)      rstep = 256*hsrc - qstep*hdst
 * by an 8-step restoring divider, so the PIXEL PATH is a plain 13-bit add/compare plus a 9-bit
 * add — no per-pixel divide, no comparator tree, no DSP outside the blend itself.
 *
 * ★ LOAD-BEARING CONTRACT (dvd/crt_ov_map.sv inverts this walk — keep them in step):
 *   f8 = FLOOR(256*f), never rounded. Because floor(256*f) >= 128  <=>  f >= 1/2 exactly, the
 *   nearest tap this stage shows at column j is provably
 *       k + (f8 >= 128)  ==  floor((j*hsrc + hdst/2)/hdst)
 *   which crt_ov_map reproduces with a plain ROUNDING Bresenham — no divider, no approximation,
 *   and bench/dvd/crt_ov_map_tb.sv T1a co-sims the two column-for-column. Rounding f8 instead
 *   of flooring it would break that identity on a 1/512-wide sliver.
 *
 * RATIO CONTRACT: Crop is always an UPSCALE (hsrc_width < hdst_width), so qstep <= 255 and
 * f8 + qstep + carry <= 511 — AT MOST ONE source pixel is consumed per output. Throughput is
 * therefore <= 1 in / 1 out per clk_en, exactly as the old duplicating version.
 *
 * LINE GEOMETRY: exactly hdst_width outputs per line — the same count a Fit line emits (see
 * mpeg2video.v disp_hdst_w), retiring the old version's documented hdst-1 off-by-one. The
 * first output carries the source line's frame-top / COL_0 code (the parity marker the mixer
 * needs), the last carries ROW_X_COL_LAST (mixer.v's line end is purely code-driven), the rest
 * ROW_X_COL_X. At the right edge there is no src[k+1], so the high tap CLAMPS to src[k] — both
 * when the low tap was the line's COL_LAST and when the fifo head has already become the NEXT
 * line's COL_0 (which would otherwise blend across the line boundary).
 *
 * OSD CHANNEL: NEAREST-picked (f8 >= 128 ? b : a), not blended. The osd byte is a colour-lookup
 * INDEX (mpeg2video's mpeg2_osd -> osd_clt), so interpolating it is semantically wrong — and it
 * saves one of the four multipliers.
 *
 * FLOW CONTROL (the reason for the input FIFO): resample_bilinear writes a whole macroblock
 * (15-17 pixels) as an UNINTERRUPTIBLE burst — it only re-checks almost_full at the START of a
 * macroblock, so it cannot be back-pressured mid-burst. The incoming stream is therefore
 * buffered in a small fifo_sc whose prog_full (>= one-macroblock margin) is what actually
 * back-pressures the resample; the read side drains it at <= 1 pixel/clk. Unchanged from the
 * duplicating version — this stage still consumes exactly hsrc pixels per line.
 *   Behavioural note: a duplicate cycle used to be able to emit with the FIFO empty; now every
 *   non-clamped output needs head_valid. Total head demand per line is identical, so steady
 *   state is unchanged — a transient underrun now STALLS (correct data) rather than duplicating.
 *
 * TIMING: 3-stage blend pipeline (s1 taps+weight -> s2 (b-a) difference -> s3 multiply+round+
 * add). disp_vscale learned the hard way (docs/history.md §8) that a single
 * memory-read -> 4-channel-multiply -> output-register cycle is the clk_dec domain's worst path
 * and sets the Fmax that produces the HDMI chroma-fringe placement lottery; here the subtract is
 * split off the multiply and BOTH taps come from fabric registers (no M10K Tco), so this stage
 * is strictly shorter than disp_vscale's.
 *
 * When hcrop_en is low (Fit / Letterbox / non-CRT) the module is a PURE COMBINATIONAL wire
 * pass-through (FIFO idle) — bit-identical to the direct resample -> pixel_queue connection.
 *
 * Sim: full-chain resample_chain_tb (+vsmode=2 geometry/hfill, +vsmode=2 +hgrad=1 blend proof,
 * +vsmode=0 +hgrad=1 control) and crt_ov_map_tb T1a/T1b/T1c.
 */

`include "timescale.v"

module disp_hstretch (
  input             clk,
  input             clk_en,
  input             rst,             // synchronous, active low

  input             hcrop_en,        // 1 = Crop (resample active); 0 = pure pass-through
  input      [11:0] hsrc_width,      // cropped source line width (pixels the addrgen emitted)
  input      [11:0] hdst_width,      // raster active width to resample up to

  /* from resample_bilinear */
  input       [7:0] in_y,
  input       [7:0] in_u,
  input       [7:0] in_v,
  input       [7:0] in_osd,
  input       [2:0] in_pos,
  input             in_wr,
  output            in_almost_full,  // backpressure to resample

  /* to pixel_queue */
  output      [7:0] out_y,
  output      [7:0] out_u,
  output      [7:0] out_v,
  output      [7:0] out_osd,
  output      [2:0] out_pos,
  output            out_wr,
  input             out_almost_full
  );

`include "resample_codes.v"

  /* ---- input FIFO (absorbs the resample macroblock bursts) + FWFT reader ---- */
  wire        fifo_prog_full;
  wire        fifo_rvalid;
  wire [34:0] fifo_dout;               // {y, u, v, osd, pos}
  wire        fifo_rd_en;

  fifo_sc #(.addr_width(9'd6), .dta_width(9'd35), .prog_thresh(9'd32))   // 64 deep, 32 margin
  ibuf (
    .clk(clk), .rst(rst),
    .din({in_y, in_u, in_v, in_osd, in_pos}),
    .wr_en(hcrop_en & in_wr & clk_en),
    .full(), .wr_ack(), .overflow(), .prog_full(fifo_prog_full),
    .dout(fifo_dout), .rd_en(fifo_rd_en),
    .empty(), .valid(fifo_rvalid), .underflow(), .prog_empty()
    );

  /* first-word fall-through: `head`/`head_valid` present the next pixel with no read
   * latency, popped by `head_pop`. This avoids a read-latency bubble that otherwise
   * throttled the stretch (right side of each line underran on HW-tight clocks). */
  wire [34:0] head;
  wire        head_valid;
  reg         head_pop;
  fwft_reader #(.dta_width(9'd35)) fr (
    .rst(rst), .clk(clk), .clk_en(clk_en),
    .fifo_rd_en(fifo_rd_en), .fifo_valid(fifo_rvalid), .fifo_dout(fifo_dout),
    .valid(head_valid), .dout(head), .rd_en(head_pop)
    );

  wire  [7:0] h_y = head[34:27];
  wire  [7:0] h_u = head[26:19];
  wire  [7:0] h_v = head[18:11];
  wire  [7:0] h_o = head[10:3];
  wire  [2:0] h_pos = head[2:0];
  wire        h_col0 = (h_pos == ROW_0_COL_0) || (h_pos == ROW_1_COL_0) || (h_pos == ROW_X_COL_0);
  wire        h_last = (h_pos == ROW_X_COL_LAST);

  /* ---- quasi-static phase constants: qstep/rstep = 256*hsrc/hdst, computed once ----
   * 8-step restoring division of (256*hsrc) by hdst, seeded with rem = hsrc (valid because
   * hsrc < hdst, so the top 8 shifts of the 16-bit dividend contribute nothing). Re-run
   * whenever the geometry ports move; entirely off the pixel path. */
  reg  [11:0] cfg_src, cfg_dst;        // latched geometry the walk is consistent with
  reg   [7:0] qstep;                   // integer source pixels per output, Q0.8 high byte
  reg  [12:0] rstep;                   // fractional remainder, < hdst
  reg   [3:0] dv_cnt;                  // 8..0 ; 0 = idle/done
  reg  [12:0] dv_rem;
  reg   [7:0] dv_q;
  reg         phase_ready;

  wire        cfg_new = (cfg_src != hsrc_width) || (cfg_dst != hdst_width);
  wire        cfg_ok  = (hsrc_width != 12'd0) && (hsrc_width < hdst_width);
  wire [13:0] dv_sh   = {dv_rem, 1'b0};
  wire        dv_ge   = (dv_sh >= {2'b00, cfg_dst});
  wire [12:0] dv_nxt  = dv_ge ? (dv_sh[12:0] - {1'b0, cfg_dst}) : dv_sh[12:0];

  always @(posedge clk)
    if (~rst) begin
      cfg_src <= 12'd0; cfg_dst <= 12'd0;
      qstep   <= 8'd255; rstep <= 13'd0; dv_cnt <= 4'd0; dv_rem <= 13'd0; dv_q <= 8'd0;
      phase_ready <= 1'b0;
    end else if (clk_en) begin
      if (cfg_new) begin
        cfg_src <= hsrc_width; cfg_dst <= hdst_width;
        /* degenerate geometry (hsrc 0, or hsrc >= hdst = not an upscale): declare ready with
         * a 1:1 step so the walk never wedges — hcrop_en should not be on in that case. */
        phase_ready <= ~cfg_ok;
        if (cfg_ok) begin dv_rem <= {1'b0, hsrc_width}; dv_q <= 8'd0; dv_cnt <= 4'd8; end
        else        begin qstep  <= 8'd255; rstep <= 13'd0;           dv_cnt <= 4'd0; end
      end else if (dv_cnt != 4'd0) begin
        dv_rem <= dv_nxt;
        dv_q   <= {dv_q[6:0], dv_ge};
        dv_cnt <= dv_cnt - 4'd1;
        if (dv_cnt == 4'd1) begin
          qstep <= {dv_q[6:0], dv_ge};   // 187 for 528/720
          rstep <= dv_nxt;               // 528 for 528/720
          phase_ready <= 1'b1;
        end
      end
    end

  /* ---- the output-driven walk ---- */
  reg         primed;                  // a_* holds src[k] for the current line
  reg   [7:0] a_y, a_u, a_v, a_o;      // low tap src[k]
  reg         a_last;                  // src[k] was the line's COL_LAST
  reg   [2:0] ft_code;                 // the line's COL_0 code (frame-top parity marker)
  reg  [11:0] j;                       // output index, 0 .. hdst-1
  reg   [7:0] f8;                      // Q0.8 weight of the HIGH tap
  reg  [12:0] facc;                    // sub-Q0.8 Bresenham remainder, < hdst

  /* high tap: the fifo head, clamped to the low tap at the right edge of the source line */
  wire        b_clamp = a_last | (head_valid & h_col0);
  wire  [7:0] b_y = b_clamp ? a_y : h_y;
  wire  [7:0] b_u = b_clamp ? a_u : h_u;
  wire  [7:0] b_v = b_clamp ? a_v : h_v;
  wire  [7:0] b_o = b_clamp ? a_o : h_o;

  wire [12:0] facc_p = facc + rstep;
  wire        fcarry = (facc_p >= {1'b0, cfg_dst});
  wire  [8:0] f8_n   = {1'b0, f8} + {1'b0, qstep} + {8'd0, fcarry};
  wire        k_adv  = f8_n[8];        // <= 1 source pixel consumed per output (qstep <= 255)

  wire        j_last = (j == cfg_dst - 12'd1);
  wire        run    = hcrop_en & phase_ready;
  wire        emit   = run &  primed & (head_valid | a_last) & ~out_almost_full;
  wire        prime  = run & ~primed & head_valid;

  always @* head_pop = prime | (emit & ~j_last & k_adv & ~b_clamp);

  wire  [2:0] pos_n = (j == 12'd0) ? ft_code : j_last ? ROW_X_COL_LAST : ROW_X_COL_X;

  /* ---- 3-stage blend pipeline (see TIMING above) ---- */
  reg         s1_valid, s2_valid;
  reg   [7:0] s1_ay, s1_au, s1_av, s1_ao;
  reg   [7:0] s1_by, s1_bu, s1_bv, s1_bo;
  reg   [7:0] s1_f;
  reg   [2:0] s1_pos;
  reg   [7:0] s2_ay, s2_au, s2_av, s2_o, s2_f;
  reg signed [8:0] s2_dy, s2_du, s2_dv;
  reg   [2:0] s2_pos;

  /* out = a + ((b-a)*f + 128) >> 8, with the difference pre-computed in s2 */
  function [7:0] blend9;
    input [7:0] a; input signed [8:0] d; input [7:0] f;
    reg signed [17:0] p;
    begin
      p = d * $signed({1'b0, f}) + 18'sd128;
      blend9 = $signed({10'd0, a}) + (p >>> 8);
    end
  endfunction

  /* registered outputs (clean timing on the tight clk_dec) */
  reg  [7:0]  r_y, r_u, r_v, r_osd;
  reg  [2:0]  r_pos;
  reg         r_wr;

  always @(posedge clk)
    if (~rst) begin
      primed <= 1'b0; a_last <= 1'b0; ft_code <= ROW_X_COL_0;
      j <= 12'd0; f8 <= 8'd0; facc <= 13'd0;
      s1_valid <= 1'b0; s2_valid <= 1'b0; r_wr <= 1'b0;
      s1_pos <= ROW_X_COL_X; s2_pos <= ROW_X_COL_X;
    end else if (clk_en) begin
      s1_valid <= 1'b0;

      if (~run) begin
        primed <= 1'b0;                 // bypassed / phase not ready: idle, re-prime later
      end else if (~primed) begin
        /* prime: pop (discarding) until a line start appears, then latch src[0] as the low
         * tap. One bubble cycle per line; also the self-heal path after an hcrop_en toggle
         * or a source line longer than the walk expected. */
        if (head_valid && h_col0) begin
          a_y <= h_y; a_u <= h_u; a_v <= h_v; a_o <= h_o;
          a_last  <= h_last;
          ft_code <= h_pos;
          primed  <= 1'b1;
          j <= 12'd0; f8 <= 8'd0; facc <= 13'd0;
        end
      end else if (emit) begin
        s1_valid <= 1'b1;
        s1_ay <= a_y; s1_au <= a_u; s1_av <= a_v; s1_ao <= a_o;
        s1_by <= b_y; s1_bu <= b_u; s1_bv <= b_v; s1_bo <= b_o;
        s1_f  <= f8;  s1_pos <= pos_n;

        if (j_last) begin
          primed <= 1'b0;               // exactly hdst outputs; COL_LAST was just emitted
        end else begin
          j    <= j + 12'd1;
          f8   <= f8_n[7:0];
          facc <= fcarry ? (facc_p - {1'b0, cfg_dst}) : facc_p;
          if (k_adv && ~b_clamp) begin
            a_y <= h_y; a_u <= h_u; a_v <= h_v; a_o <= h_o;
            a_last <= h_last;
          end
        end
      end

      /* s1 -> s2: split the difference off the multiply's path; osd picks nearest */
      s2_valid <= s1_valid;
      s2_ay <= s1_ay; s2_dy <= $signed({1'b0, s1_by}) - $signed({1'b0, s1_ay});
      s2_au <= s1_au; s2_du <= $signed({1'b0, s1_bu}) - $signed({1'b0, s1_au});
      s2_av <= s1_av; s2_dv <= $signed({1'b0, s1_bv}) - $signed({1'b0, s1_av});
      s2_o  <= (s1_f >= 8'd128) ? s1_bo : s1_ao;
      s2_f  <= s1_f;
      s2_pos <= s1_pos;

      /* s2 -> out: multiply + round + add only */
      r_y   <= blend9(s2_ay, s2_dy, s2_f);
      r_u   <= blend9(s2_au, s2_du, s2_f);
      r_v   <= blend9(s2_av, s2_dv, s2_f);
      r_osd <= s2_o;
      r_pos <= s2_pos;
      r_wr  <= s2_valid;
    end

  /* ---- output mux: pure pass-through wires when not cropping (bit-identical) ---- */
  assign out_y          = hcrop_en ? r_y   : in_y;
  assign out_u          = hcrop_en ? r_u   : in_u;
  assign out_v          = hcrop_en ? r_v   : in_v;
  assign out_osd        = hcrop_en ? r_osd : in_osd;
  assign out_pos        = hcrop_en ? r_pos : in_pos;
  assign out_wr         = hcrop_en ? r_wr  : in_wr;
  assign in_almost_full = hcrop_en ? fifo_prog_full : out_almost_full;

endmodule
/* not truncated */
