/*
 * field_blend.sv -- DVD-FORK (non-adaptive field blend on the Progressive raster;
 *                   docs/field_blend.md)
 *
 * A clk_dec-domain post-filter on the display pixel stream, between the resample
 * (addrgen + dta + bilinear) and disp_vscale:
 *     resample -> field_blend -> disp_vscale -> disp_hstretch -> pixel_queue
 * Same port set and skeleton as disp_vscale (input fifo_sc + fwft_reader, a 1 px/clk
 * pipeline, a per-scan sideband from the addrgen, a combinational wire while idle).
 * The plumbing is the shelved Stage A deinterlacer's (feature/deinterlace@a017ec4,
 * dvd/deint_comb.sv); the kernel is not.
 *
 * WHAT IT DOES. On Video Output = Progressive the addrgen shows a true-interlaced
 * picture as one WOVEN frame, whose two fields are instants 1/59.94 s apart, so
 * motion combs. For a scan the addrgen marks (cur_ilace, see resample_addrgen.v),
 * every output line y, every channel, is
 *     out = (a + 2b + d + 2) >> 2        a = line y-1, b = line y, d = line y+1
 * For an interior line a and d belong to the OTHER field, so the result is exactly
 * half of each field: comb becomes a soft ghost, and vertical detail is lost.
 * ★ There is NO detector, NO anchor field and NO per-refresh state. That is the
 * point: Stage A rebuilt one field and ALTERNATED which one per refresh, so a
 * falsely flagged edge was sharp on one refresh and soft on the next -- a 30 Hz
 * shimmer. Here a held picture is byte-identical on every re-scan.
 *
 * EDGES MIRROR, which keeps the 50/50 field balance of an interior line:
 *   top    (output line 0): a := d -- selected here (p2_first).
 *   bottom (output line H-1): d := a -- supplied by the ADDRGEN, which emits a marked
 *          scan as H+1 lines whose last line is line H-2 again. Output line y goes out
 *          while input line y+1 is received (the stream has no end-of-scan marker), so
 *          that extra line IS the bottom line's d and this module needs no bottom case.
 *
 * MEMORY. Two line delays in series, each written ONE COLUMN BEHIND its read so a
 * read and a write never share an address in a cycle:
 *     dbuf 1024 x 32 {y,u,v,osd} = line y   (b)
 *     nbuf 1024 x 24 {y,u,v}     = line y-1 (a), fed from dbuf's read
 * The live input is line y+1 (d). M10K outputs are re-registered in fabric before the
 * add (the disp_vscale a_q lesson).
 *
 * SIDEBAND. A scan's mode is not in the pixel stream, so the addrgen pushes one bit
 * per frame-top scan (scan_start / scan_blend) into a 4-deep queue, popped once per
 * frame-top PIXEL received and stamped on every pixel of the scan in the input FIFO
 * word. PLAIN: a scan arriving while the buffered path still holds an earlier one
 * goes through the buffered path unmodified, so output order is kept across a
 * video<->film switch or a seek.
 * ⚠ A FRAME scan carries TWO row codes (ROW_0_COL_0 on line 0, ROW_1_COL_0 on line
 * 1); the second is NOT a frame top (in_prev_row0 / h_prev_row0).
 *
 * POSITION CODES are the contract with the mixer: the scan's own frame-top code on
 * output line 0, ROW_1_COL_0 on output line 1 (the mixer places line 1 by it,
 * mixer.v), ROW_X_COL_0 on later line starts, ROW_X_COL_LAST on line ends.
 *
 * OSD is never blended (a palette INDEX). With blend_en low the addrgen marks no
 * scan, the buffered path never fills, and the module is the wire it replaces.
 *
 * DVD-FORK (PROGRESSIVE BOB, docs/field_blend.md "Bob"). A second kernel on the same
 * line buffers, selected per scan by the sideband (scan_bob, with scan_blend also set,
 * because a bob scan is the same H+1-line filtered scan). It keeps ONE field of the
 * woven frame -- the top field is the even lines -- and rebuilds each line of the other
 * field as the average of the kept lines above and below it:
 *     kept line  (y[0] == keep_bot):  out = b
 *     other line                   :  out = (a + d + 1) >> 1
 * The addrgen chooses the kept field per scan (the first field on the pickup scan, the
 * second on every re-scan). The edges fall out of the mirroring above: keeping BOTTOM,
 * output line 0 is (d + d + 1) >> 1 = line 1; keeping TOP with H even, the bottom line
 * is (H-2 + H-2 + 1) >> 1 = line H-2, a repeat of the nearest kept line.
 */

`include "timescale.v"

module field_blend (
  input             clk,
  input             clk_en,
  input             rst,               // synchronous, active low

  input             scan_start,        // addrgen: a frame-top scan begins
  input             scan_blend,        //   ... and is a filtered scan (H+1 lines in)
  input             scan_bob,          //   ... with the BOB kernel (else the blend)
  input             scan_bob_bot,      //   ... bob keeps the BOTTOM field (else the TOP)

  /* from resample_bilinear */
  input       [7:0] in_y,
  input       [7:0] in_u,
  input       [7:0] in_v,
  input       [7:0] in_osd,
  input       [2:0] in_pos,
  input             in_wr,
  output            in_almost_full,    // backpressure to resample

  /* to disp_vscale */
  output      [7:0] out_y,
  output      [7:0] out_u,
  output      [7:0] out_v,
  output      [7:0] out_osd,
  output      [2:0] out_pos,
  output            out_wr,
  input             out_almost_full,

  /* instrument (level, for dvd_telem): the scan under way is a blend scan */
  output reg        blend_act,
  output reg        bob_act            // ... and it is a bob scan
  );

`include "resample_codes.v"

  /* ---- per-scan sideband, in scan order. Depth 4: a scan needs every one of its
   * lines through the resample pipeline before the next can start. ---- */
  reg   [2:0] sb_q [0:3];                                     // {bob_bot, bob, filtered}
  reg   [2:0] sb_n;
  reg         in_prev_row0;
  wire        in_col0 = (in_pos == ROW_0_COL_0) || (in_pos == ROW_1_COL_0) || (in_pos == ROW_X_COL_0);
  wire        in_ft   = (in_pos == ROW_0_COL_0) || ((in_pos == ROW_1_COL_0) && ~in_prev_row0);
  wire        ft_arr  = in_wr & clk_en & in_ft;             // a frame-top pixel arrives
  always @(posedge clk)
    if (~rst) in_prev_row0 <= 1'b0;
    else if (in_wr && clk_en && in_col0) in_prev_row0 <= (in_pos == ROW_0_COL_0);
  wire        sb_blend = (sb_n != 3'd0) & sb_q[0][0];       // the arriving scan is FILTERED
  wire  [1:0] sb_kern  = (sb_n != 3'd0) ? sb_q[0][2:1] : 2'd0;  // {bob_bot, bob}
  wire        sb_pop   = ft_arr && (sb_n != 3'd0);
  wire  [2:0] sb_npop  = sb_pop ? sb_n - 3'd1 : sb_n;
  always @(posedge clk)
    if (~rst) begin
      sb_n <= 3'd0;
      sb_q[0] <= 3'd0; sb_q[1] <= 3'd0; sb_q[2] <= 3'd0; sb_q[3] <= 3'd0;
    end else begin
      if (sb_pop) begin
        sb_q[0] <= sb_q[1]; sb_q[1] <= sb_q[2]; sb_q[2] <= sb_q[3]; sb_q[3] <= 3'd0;
      end
      sb_n <= sb_npop;
      if (clk_en && scan_start && (sb_npop != 3'd4)) begin
        sb_q[sb_npop[1:0]] <= {scan_bob_bot & scan_bob, scan_bob & scan_blend, scan_blend};
        sb_n <= sb_npop + 3'd1;
      end
    end

  /* ---- routing, decided at the frame-top pixel; later pixels follow it ----
   * path_busy: the buffered path still holds pixels. Held a few idle cycles after
   * the last sign of activity (covers fifo_sc's empty-flag lag and the fwft read). */
  wire        fifo_empty;
  reg   [2:0] idle_cnt;
  wire        path_busy = (idle_cnt != 3'd7);
  wire        ft_route  = sb_blend | path_busy;
  reg         scan_route;
  reg         scan_mode_in;
  reg   [1:0] scan_kern_in;
  always @(posedge clk)
    if (~rst) begin scan_route <= 1'b0; scan_mode_in <= 1'b0; scan_kern_in <= 2'd0; end
    else if (ft_arr) begin scan_route <= ft_route; scan_mode_in <= sb_blend; scan_kern_in <= sb_kern; end
  wire        route_px = in_ft ? ft_route : scan_route;
  wire        mode_px  = in_ft ? sb_blend : scan_mode_in;
  wire  [1:0] kern_px  = in_ft ? sb_kern  : scan_kern_in;

  /* ---- input FIFO (absorbs the resample macroblock bursts) + FWFT reader ---- */
  wire        fifo_prog_full;
  wire        fifo_rvalid;
  wire [37:0] fifo_dout;               // {bob_bot, bob, filtered, y, u, v, osd, pos}
  wire        fifo_rd_en;
  wire        ibuf_wr = route_px & in_wr & clk_en;

  fifo_sc #(.addr_width(9'd7), .dta_width(9'd38), .prog_thresh(9'd64))   // 128 deep, 64 margin
  ibuf (
    .clk(clk), .rst(rst),
    .din({kern_px, mode_px, in_y, in_u, in_v, in_osd, in_pos}),
    .wr_en(ibuf_wr),
    .full(), .wr_ack(), .overflow(), .prog_full(fifo_prog_full),
    .dout(fifo_dout), .rd_en(fifo_rd_en),
    .empty(fifo_empty), .valid(fifo_rvalid), .underflow(), .prog_empty()
    );

  wire [37:0] head;
  wire        head_valid;
  reg         head_pop;
  fwft_reader #(.dta_width(9'd38)) fr (
    .rst(rst), .clk(clk), .clk_en(clk_en),
    .fifo_rd_en(fifo_rd_en), .fifo_valid(fifo_rvalid), .fifo_dout(fifo_dout),
    .valid(head_valid), .dout(head), .rd_en(head_pop)
    );

  wire        h_blend = head[35];      // per-pixel copy of its scan's mode (set at routing): filtered
  wire        h_bob   = head[36];      //   ... with the bob kernel
  wire        h_bbot  = head[37];      //   ... keeping the BOTTOM field
  wire  [7:0] h_y   = head[34:27];
  wire  [7:0] h_u   = head[26:19];
  wire  [7:0] h_v   = head[18:11];
  wire  [7:0] h_osd = head[10:3];
  wire  [2:0] h_pos = head[2:0];
  wire        h_col0 = (h_pos == ROW_0_COL_0) || (h_pos == ROW_1_COL_0) || (h_pos == ROW_X_COL_0);
  reg         h_prev_row0;
  wire        h_ft   = (h_pos == ROW_0_COL_0) || ((h_pos == ROW_1_COL_0) && ~h_prev_row0);
  wire        h_last = (h_pos == ROW_X_COL_LAST);

  /* ---- per-scan / per-line state ---- */
  reg   [2:0] scan_ft_code;            // the scan's frame-top code, re-emitted on output line 0
  reg  [11:0] sline;                   // INPUT line index of the line being received (0-based)
  reg   [9:0] col;                     // column of the pixel about to be consumed

  /* effective values for the CURRENT head pixel (stable until it is consumed) */
  wire [11:0] e_sline  = h_ft ? 12'd0 : (h_col0 ? sline + 12'd1 : sline);
  wire  [9:0] e_col    = h_col0 ? 10'd0 : col;
  wire        e_emit   = h_blend ? (e_sline != 12'd0) : 1'b1;
  wire        e_first  = (e_sline == 12'd1);              // output line 0: no line above, a := d
  wire  [2:0] e_ft     = h_ft ? h_pos : scan_ft_code;
  wire  [2:0] e_pos    = ~h_blend ? h_pos
                       : h_col0   ? ((e_sline == 12'd1) ? e_ft : (e_sline == 12'd2) ? ROW_1_COL_0 : ROW_X_COL_0)
                       : h_last   ? ROW_X_COL_LAST : ROW_X_COL_X;

  /* ---- consume: 1 px/clk whenever the head is present and the queue is not
   * almost full (the same contract as disp_vscale / disp_hstretch). ---- */
  wire        consume = head_valid & ~out_almost_full;
  always @* head_pop = consume;

  /* ---- the two line delays ----
   * Reads are issued every cycle from the combinational address; each write lands
   * one cycle later at the consumed pixel's own column, read the cycle before. */
  reg  [31:0] dbuf [0:1023];
  reg  [23:0] nbuf [0:1023];
  reg  [31:0] dbuf_rd;
  reg  [23:0] nbuf_rd;
  always @(posedge clk)
    if (clk_en) dbuf_rd <= dbuf[e_col];
  always @(posedge clk)
    if (clk_en) nbuf_rd <= nbuf[e_col];

  /* stage 1: the pixel consumed last cycle (its reads are landing now) */
  reg         p1_valid, p1_emit, p1_blend, p1_first;
  reg         p1_bob, p1_keep;           // bob scan; this OUTPUT line belongs to the kept field
  reg   [9:0] p1_col;
  reg  [31:0] p1_d;                    // {y,u,v,osd} of the live input line (d)
  reg   [2:0] p1_pos;

  always @(posedge clk)
    if (clk_en && p1_valid) dbuf[p1_col] <= p1_d;
  always @(posedge clk)
    if (clk_en && p1_valid) nbuf[p1_col] <= dbuf_rd[31:8];

  /* stage 2: fabric re-register of the M10K outputs, the pixel alongside */
  reg         p2_valid, p2_emit, p2_blend, p2_first;
  reg         p2_bob, p2_keep;
  reg  [31:0] p2_d;
  reg   [2:0] p2_pos;
  reg  [31:0] b2;                      // line y   {y,u,v,osd}
  reg  [23:0] a2;                      // line y-1 {y,u,v}

  /* the kernel, combinational on stage-2 registers; mirror at the top edge */
  wire  [7:0] a_y = p2_first ? p2_d[31:24] : a2[23:16];
  wire  [7:0] a_u = p2_first ? p2_d[23:16] : a2[15:8];
  wire  [7:0] a_v = p2_first ? p2_d[15:8]  : a2[7:0];
  wire  [9:0] k_y = {2'd0, a_y} + {1'd0, b2[31:24], 1'b0} + {2'd0, p2_d[31:24]} + 10'd2;
  wire  [9:0] k_u = {2'd0, a_u} + {1'd0, b2[23:16], 1'b0} + {2'd0, p2_d[23:16]} + 10'd2;
  wire  [9:0] k_v = {2'd0, a_v} + {1'd0, b2[15:8],  1'b0} + {2'd0, p2_d[15:8]}  + 10'd2;
  /* the bob kernel's rebuilt line: the kept field's lines above (a) and below (d) */
  wire  [8:0] m_y = {1'd0, a_y} + {1'd0, p2_d[31:24]} + 9'd1;
  wire  [8:0] m_u = {1'd0, a_u} + {1'd0, p2_d[23:16]} + 9'd1;
  wire  [8:0] m_v = {1'd0, a_v} + {1'd0, p2_d[15:8]}  + 9'd1;
  wire  [7:0] f_y = ~p2_bob ? k_y[9:2] : p2_keep ? b2[31:24] : m_y[8:1];
  wire  [7:0] f_u = ~p2_bob ? k_u[9:2] : p2_keep ? b2[23:16] : m_u[8:1];
  wire  [7:0] f_v = ~p2_bob ? k_v[9:2] : p2_keep ? b2[15:8]  : m_v[8:1];

  /* registered outputs */
  reg   [7:0] r_y, r_u, r_v, r_osd;
  reg   [2:0] r_pos;
  reg         r_wr;

  always @(posedge clk)
    if (~rst) begin
      scan_ft_code <= ROW_0_COL_0; sline <= 12'd0; col <= 10'd0; h_prev_row0 <= 1'b0;
      p1_valid <= 1'b0; p1_emit <= 1'b0; p1_blend <= 1'b0; p1_first <= 1'b0;
      p1_bob <= 1'b0; p1_keep <= 1'b0; p2_bob <= 1'b0; p2_keep <= 1'b0; bob_act <= 1'b0;
      p1_col <= 10'd0; p1_d <= 32'd0; p1_pos <= ROW_X_COL_X;
      p2_valid <= 1'b0; p2_emit <= 1'b0; p2_blend <= 1'b0; p2_first <= 1'b0;
      p2_d <= 32'd0; p2_pos <= ROW_X_COL_X; b2 <= 32'd0; a2 <= 24'd0;
      r_y <= 8'd0; r_u <= 8'd0; r_v <= 8'd0; r_osd <= 8'd0; r_pos <= ROW_X_COL_X; r_wr <= 1'b0;
      blend_act <= 1'b0;
    end else if (clk_en) begin
      /* -------- stage 1: consume, latch, advance the counters -------- */
      p1_valid <= consume;
      if (consume) begin
        p1_d <= {h_y, h_u, h_v, h_osd}; p1_pos <= e_pos; p1_col <= e_col;
        p1_emit <= e_emit; p1_blend <= h_blend; p1_first <= e_first;
        /* output line y = e_sline - 1, so y[0] = ~e_sline[0]; the top field is even */
        p1_bob  <= h_bob;  p1_keep <= (~e_sline[0] == h_bbot);
        if (h_col0) begin
          col <= 10'd1;
          h_prev_row0 <= (h_pos == ROW_0_COL_0);
          if (h_ft) begin scan_ft_code <= h_pos; sline <= 12'd0; end
          else      sline <= sline + 12'd1;
        end else col <= col + 10'd1;
      end

      /* -------- stage 2: M10K outputs land in fabric registers -------- */
      p2_valid <= p1_valid; p2_emit <= p1_emit; p2_blend <= p1_blend; p2_first <= p1_first;
      p2_bob <= p1_bob; p2_keep <= p1_keep;
      p2_d <= p1_d; p2_pos <= p1_pos;
      b2 <= dbuf_rd; a2 <= nbuf_rd;

      /* -------- stage 3: output register; the enable is applied HERE, not in the
       * add's cone (docs/hw_budget_and_lessons.md §5) -------- */
      r_wr <= p2_valid & p2_emit;
      if (p2_valid) begin
        r_y   <= p2_blend ? f_y       : p2_d[31:24];
        r_u   <= p2_blend ? f_u       : p2_d[23:16];
        r_v   <= p2_blend ? f_v       : p2_d[15:8];
        r_osd <= p2_blend ? b2[7:0]   : p2_d[7:0];              // never blended
        r_pos <= p2_pos;
      end

      if (ft_arr) begin blend_act <= sb_blend & ~sb_kern[0]; bob_act <= sb_kern[0]; end
    end

  /* idle detector for the routing decision (see path_busy) */
  always @(posedge clk)
    if (~rst) idle_cnt <= 3'd7;
    else if (ibuf_wr | ~fifo_empty | fifo_rvalid | head_valid | p1_valid | p2_valid | r_wr)
      idle_cnt <= 3'd0;
    else if (idle_cnt != 3'd7) idle_cnt <= idle_cnt + 3'd1;

  /* ---- output mux: the buffered path owns the output while it holds anything;
   * a pixel passes straight through only when its scan was routed around an IDLE
   * buffered path, so the two never both write in one cycle and order is kept. ---- */
  wire        bypass_wr     = in_wr & ~route_px;
  assign out_y          = path_busy ? r_y   : in_y;
  assign out_u          = path_busy ? r_u   : in_u;
  assign out_v          = path_busy ? r_v   : in_v;
  assign out_osd        = path_busy ? r_osd : in_osd;
  assign out_pos        = path_busy ? r_pos : in_pos;
  assign out_wr         = path_busy ? r_wr  : bypass_wr;
  assign in_almost_full = (scan_route | path_busy) ? fifo_prog_full : out_almost_full;

endmodule
