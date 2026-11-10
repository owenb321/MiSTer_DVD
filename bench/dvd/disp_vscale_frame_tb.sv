`timescale 1ns/1ps
//
// disp_vscale_frame_tb.sv -- disp_vscale on the PROGRESSIVE FRAME path
// (feature/progressive-aspect, docs/crt_anamorphic.md §11 + §13).
//
// Explicit Letterbox now reaches the progressive raster, where resample_addrgen emits a
// FRAME scan: line 0 tagged ROW_0_COL_0 AND line 1 tagged ROW_1_COL_0
// (resample_addrgen.v disp_y_sat walk 0 -> 1 -> 2). Before this branch disp_vscale took
// the second code for a new scan. The consumer's contract is the mixer's
// (rtl/mpeg2/mixer.v display_first_pixel): a scan's line 0 starts on its frame-top code,
// its line 1 on ROW_1_COL_0 when that line lands on disp_v_offset+1 (a ROW_X_COL_0 there
// is REFUSED and slips a line = a black line under the top bar), every later line on
// ROW_X_COL_0. So this bench scores, pixel by pixel with !==:
//   - the 3/4 blend VALUES (a golden Bresenham over the source lines the bench drove),
//   - the output LINE COUNT (360 from 480, 432 from 576), and
//   - the POSITION CODES, including output line 1 = ROW_1_COL_0 on a frame scan.
//
// +case=
//   frame_lb   Letterbox on frame scans (the new path). Must emit H*3/4 lines tagged
//              ROW_0, ROW_1, ROW_X... Pre-fix: 359 lines, line 0 tagged ROW_1, line 1 ROW_X.
//   field_lb   Letterbox on alternating TOP/BOTTOM field scans (the Interlaced path, which
//              must be UNCHANGED): line 0 tagged with the field's own code, line 1 ROW_X.
//   frame_fit  vscale_en = 0 on frame scans: the output is the input, untouched.
//   toggle     Letterbox switched exactly between a frame's line 0 and line 1, both ways.
//              A scan keeps the mode it started with; the change lands on the NEXT scan.
//              (Fit -> Letterbox is the direction that tears without the input-side fix:
//              line 1 would be routed into the buffered path as a new 359-line scan.)
//   frame_r / field_r   (2026-11, Standard Convert) +ratio=1 (5/6) or 2 (5/8) on frame scans,
//              or on alternating TOP/BOTTOM field scans with the bottom field's phase.
//              (2026-11-09, To PAL) +ratio=3 (6/5 UP, 480 -> 576) or 4 (9/10, 480 -> 432). The upscale
//              must emit EXACTLY H*6/5 lines: some source pairs give two (a replay from the second
//              line buffer), a bottom field's first output is clamped to line 0, and the last ones
//              are the last line alone.
//   field_x    (2026-11-09, To PAL field-accurate video) +ratio=3 or 4 field scans in all four
//              (slot, xpar) combinations: a field of the OTHER parity drawn at its true position,
//              S/2 into a bottom slot, -1/2 (clamped) into a top slot. Exact line counts.
//   rtoggle    the ratio switched between a frame's line 0 and line 1: the scan keeps its own.
//   ★ The golden is a CLOSED FORM, not a copy of the DUT's walk: output line i reads source
//   position i*step + phase (180ths since 2026-11-09), so k = pos/180 and f = round(256*(pos%180)/180). +lines
//   also asserts each scan's output line count from outside the model.
// +h=N       source lines per scan (frame 480 default; field 240 default)
// +bp=1      random back-pressure on out_almost_full
// +dump=F    write every output pixel to F ("y u v osd pos" per line), for the
//            branch-vs-main bit-identity diff of the field path.
//
// Build (bench/dvd/run_vscale_frame.sh does this):
//   iverilog -g2012 -I rtl/mpeg2 -o .sim/vsf/sim rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v \
//     rtl/mpeg2/xfifo_sc.v dvd/disp_vscale.sv bench/dvd/disp_vscale_frame_tb.sv
//
module disp_vscale_frame_tb;
`include "resample_codes.v"

  localparam integer W     = 32;          // pixels per line (two macroblocks)
  localparam integer MAXO  = 400000;      // expected-pixel capacity

  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg rst = 1'b0;                          // active low

  reg        vscale_en = 1'b0;
  reg  [2:0] vscale_ratio = 3'd0;
  reg [11:0] src_lines = 12'd480;
  reg        sxp = 1'b0;                   // +case=field_x: the scan reads the other parity (To PAL video)
  reg        scan_start = 1'b0;
  reg  [7:0] in_y = 8'd0, in_u = 8'd0, in_v = 8'd0, in_osd = 8'd0;
  reg  [2:0] in_pos = ROW_X_COL_X;
  reg        in_wr = 1'b0;
  wire       in_almost_full;
  wire [7:0] out_y, out_u, out_v, out_osd;
  wire [2:0] out_pos;
  wire       out_wr;
  reg        out_almost_full = 1'b0;

  disp_vscale dut (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .vscale_en(vscale_en), .vscale_ratio(vscale_ratio), .src_lines(src_lines), .scan_start(scan_start), .scan_half(1'b0), .scan_xpar(sxp),
    .in_y(in_y), .in_u(in_u), .in_v(in_v), .in_osd(in_osd), .in_pos(in_pos),
    .in_wr(in_wr), .in_almost_full(in_almost_full),
    .out_y(out_y), .out_u(out_u), .out_v(out_v), .out_osd(out_osd), .out_pos(out_pos),
    .out_wr(out_wr), .out_almost_full(out_almost_full)
  );

  // ---- source pixel values: every line distinct, so a blend names its two lines ----
  // `sid` makes scans distinct too (a pixel from the wrong scan cannot pass).
  function automatic [7:0] py(input integer sid, input integer l, input integer c);
    py = (l * 5 + c * 3 + sid * 17) & 8'hFF; endfunction
  function automatic [7:0] pu(input integer sid, input integer l, input integer c);
    pu = (l * 11 + 7 + sid * 29) & 8'hFF;    endfunction
  function automatic [7:0] pv(input integer sid, input integer l, input integer c);
    pv = (c * 9 + l + sid * 3) & 8'hFF;      endfunction
  function automatic [7:0] po(input integer sid, input integer l, input integer c);
    po = (l * 3 + c + sid) & 8'hFF;          endfunction
  // disp_vscale's specified 2-tap blend: a + ((b-a)*f + 128) >>> 8
  function automatic [7:0] bl(input [7:0] a, input [7:0] b, input integer f);
    integer d, p;
    begin d = b - a; p = d * f + 128; bl = a + (p >>> 8); end
  endfunction
  // A FRAME scan tags line 0 ROW_0_COL_0 and line 1 ROW_1_COL_0; a FIELD scan tags only
  // line 0, with its own field's code.
  function automatic [2:0] in_code(input integer l, input integer c, input [2:0] ft, input integer frame);
    in_code = (c == W - 1) ? ROW_X_COL_LAST :
              (c != 0)     ? ROW_X_COL_X    :
              (l == 0)     ? ft             :
              (l == 1 && frame != 0) ? ROW_1_COL_0 : ROW_X_COL_0;
  endfunction

  // ---- expected output stream ----
  reg [7:0] ey [0:MAXO-1], eu [0:MAXO-1], ev [0:MAXO-1], eo [0:MAXO-1];
  reg [2:0] ep [0:MAXO-1];
  integer   en = 0;                         // expected pixels queued
  integer   gn = 0;                         // output pixels received
  integer   errs = 0;

  // expect a pass-through scan (Fit, or a buffered PLAIN scan): output == input
  task automatic expect_plain(input integer sid, input integer H, input [2:0] ft, input integer frame);
    integer l, c;
    for (l = 0; l < H; l = l + 1)
      for (c = 0; c < W; c = c + 1) begin
        ey[en] = py(sid, l, c); eu[en] = pu(sid, l, c); ev[en] = pv(sid, l, c); eo[en] = po(sid, l, c);
        ep[en] = in_code(l, c, ft, frame); en = en + 1;
      end
  endtask

  // expect a Letterbox scan: the exact 3/4 Bresenham (remainder in sixths, +2 per output)
  task automatic expect_lb(input integer sid, input integer H, input [2:0] ft, input integer frame);
    integer k, r, i, c, f;
    begin
      k = 0; r = 0; i = 0;
      while (k + 1 <= H - 1) begin
        f = (r == 0) ? 0 : (r == 2) ? 85 : 171;
        for (c = 0; c < W; c = c + 1) begin
          ey[en] = bl(py(sid, k, c), py(sid, k + 1, c), f);
          eu[en] = bl(pu(sid, k, c), pu(sid, k + 1, c), f);
          ev[en] = bl(pv(sid, k, c), pv(sid, k + 1, c), f);
          eo[en] = bl(po(sid, k, c), po(sid, k + 1, c), f);
          ep[en] = (c == W - 1) ? ROW_X_COL_LAST : (c != 0) ? ROW_X_COL_X :
                   (i == 0) ? ft : (i == 1 && frame) ? ROW_1_COL_0 : ROW_X_COL_0;
          en = en + 1;
        end
        i = i + 1;
        if (r >= 4) begin r = r - 4; k = k + 2; end else begin r = r + 2; k = k + 1; end
      end
    end
  endtask

  // expect a scaled scan by the closed form: output line i reads source position i*step + phase,
  // in 180ths of a source line. step = 240/216/288/150/200 for ratio 0/1/2/3/4. phase = 0, except a
  // bottom field: 18 (ratio 1), 54 (2), -15 (3), 10 (4). A downscale emits while k+1 is a real line;
  // the upscale emits exactly H*6/5 lines, a negative position clamped to line 0 and a position at or
  // past the last line clamped to it. Returns the number of output lines.
  integer last_lines;
  task automatic expect_cf(input integer sid, input integer H, input [2:0] ft, input integer frame,
                           input integer ratio);
    expect_cfx(sid, H, ft, frame, ratio, 0);
  endtask
  // xp: the scan is a field of the other parity (+case=field_x). Source frame position of output
  // line i in a slot of parity op is (2i + op)*S; a field of parity sp has line j at 2j + sp.
  task automatic expect_cfx(input integer sid, input integer H, input [2:0] ft, input integer frame,
                            input integer ratio, input integer xp);
    integer i, c, pos, k, k1, f, step, ph, n_up;
    begin
      step = (ratio == 1) ? 216 : (ratio == 2) ? 288 : (ratio == 3) ? 150 : (ratio == 4) ? 200 : 240;
      if (xp != 0)
        ph = (ft == ROW_1_COL_0) ? ((ratio == 3) ? 75 : 100) : -90;
      else
        ph = (ft != ROW_1_COL_0) ? 0 : (ratio == 1) ? 18 : (ratio == 2) ? 54 : (ratio == 3) ? -15 :
             (ratio == 4) ? 10 : 0;
      n_up = (ratio == 3) ? H + H / 5 : H - H / 10;
      i = 0;
      while ((ratio >= 3) ? (i < n_up) : (((i * step + ph) / 180) + 1 <= H - 1)) begin
        pos = i * step + ph;
        if (pos < 0) begin k = 0; k1 = 0; f = 0; end
        else begin
          k = pos / 180; k1 = k + 1;
          if (k1 > H - 1) begin k = H - 1; k1 = H - 1; end
          f = (256 * (pos % 180) + 90) / 180;      // round(256*r/180), independently of the DUT's formula
        end
        for (c = 0; c < W; c = c + 1) begin
          ey[en] = bl(py(sid, k, c), py(sid, k1, c), f);
          eu[en] = bl(pu(sid, k, c), pu(sid, k1, c), f);
          ev[en] = bl(pv(sid, k, c), pv(sid, k1, c), f);
          eo[en] = bl(po(sid, k, c), po(sid, k1, c), f);
          ep[en] = (c == W - 1) ? ROW_X_COL_LAST : (c != 0) ? ROW_X_COL_X :
                   (i == 0) ? ft : (i == 1 && frame) ? ROW_1_COL_0 : ROW_X_COL_0;
          en = en + 1;
        end
        i = i + 1;
      end
      last_lines = i;
    end
  endtask

  // ---- driver ----
  integer bp = 0;
  integer tog_line = -1, tog_val = 0;       // toggle vscale_en before line `tog_line` of the scan
  integer rtog_line = -1, rtog_val = 0;     // ... and the ratio, the same way
  task automatic drive_scan(input integer sid, input integer H, input [2:0] ft, input integer frame);
    drive_scanx(sid, H, ft, frame, 0);
  endtask
  task automatic drive_scanx(input integer sid, input integer H, input [2:0] ft, input integer frame,
                             input integer xp);
    integer l, c;
    begin
      @(posedge clk); scan_start <= 1'b1; sxp <= (xp != 0);
      @(posedge clk); scan_start <= 1'b0; sxp <= 1'b0;
      for (l = 0; l < H; l = l + 1) begin
        if (l == tog_line) vscale_en <= tog_val[0];
        if (l == rtog_line) vscale_ratio <= rtog_val[2:0];
        for (c = 0; c < W; c = c + 1) begin
          while (in_almost_full) begin in_wr <= 1'b0; @(posedge clk); end
          in_y <= py(sid, l, c); in_u <= pu(sid, l, c); in_v <= pv(sid, l, c); in_osd <= po(sid, l, c);
          in_pos <= in_code(l, c, ft, frame); in_wr <= 1'b1;
          @(posedge clk);
        end
      end
      in_wr <= 1'b0;
      repeat (20 + ($urandom % 40)) @(posedge clk);
    end
  endtask

  always @(posedge clk) if (bp != 0) out_almost_full <= (($urandom % 4) == 0);

  // ---- checker ----
  integer dumpf = 0;
  always @(posedge clk) if (rst && out_wr) begin
    if (dumpf != 0) $fwrite(dumpf, "%02x %02x %02x %02x %0d\n", out_y, out_u, out_v, out_osd, out_pos);
    if (gn >= en) begin
      if (errs < 10) $display("  EXTRA output pixel #%0d pos=%0d (only %0d expected)", gn, out_pos, en);
      errs = errs + 1;
    end else if (out_y !== ey[gn] || out_u !== eu[gn] || out_v !== ev[gn] ||
                 out_osd !== eo[gn] || out_pos !== ep[gn]) begin
      if (errs < 10)
        $display("  MISMATCH px #%0d (line %0d col %0d): got y%02x u%02x v%02x o%02x pos%0d  want y%02x u%02x v%02x o%02x pos%0d",
                 gn, gn / W, gn % W, out_y, out_u, out_v, out_osd, out_pos,
                 ey[gn], eu[gn], ev[gn], eo[gn], ep[gn]);
      errs = errs + 1;
    end
    gn = gn + 1;
  end

  // ---- scenarios ----
  reg [8*16-1:0] tcase;
  reg [8*256-1:0] dumpname;
  integer H, s, R, want_lines, lines_bad;
  initial begin
    if (!$value$plusargs("case=%s", tcase)) tcase = "frame_lb";
    void'($value$plusargs("bp=%d", bp));
    if ($value$plusargs("dump=%s", dumpname)) dumpf = $fopen(dumpname, "w");
    repeat (5) @(posedge clk); rst = 1'b1; repeat (5) @(posedge clk);

    if (tcase == "frame_lb") begin
      if (!$value$plusargs("h=%d", H)) H = 480;
      vscale_en = 1'b1;
      for (s = 0; s < 3; s = s + 1) begin expect_lb(s, H, ROW_0_COL_0, 1); drive_scan(s, H, ROW_0_COL_0, 1); end
    end else if (tcase == "field_lb") begin
      if (!$value$plusargs("h=%d", H)) H = 240;
      vscale_en = 1'b1;
      for (s = 0; s < 4; s = s + 1) begin
        expect_lb(s, H, s[0] ? ROW_1_COL_0 : ROW_0_COL_0, 0);
        drive_scan(s, H, s[0] ? ROW_1_COL_0 : ROW_0_COL_0, 0);
      end
    end else if (tcase == "frame_fit") begin
      if (!$value$plusargs("h=%d", H)) H = 480;
      vscale_en = 1'b0;
      for (s = 0; s < 3; s = s + 1) begin expect_plain(s, H, ROW_0_COL_0, 1); drive_scan(s, H, ROW_0_COL_0, 1); end
    end else if (tcase == "toggle") begin
      if (!$value$plusargs("h=%d", H)) H = 480;
      vscale_en = 1'b0;
      expect_plain(0, H, ROW_0_COL_0, 1); drive_scan(0, H, ROW_0_COL_0, 1);           // Fit
      tog_line = 1; tog_val = 1;                                                    // Fit -> LB at line 1
      expect_plain(1, H, ROW_0_COL_0, 1); drive_scan(1, H, ROW_0_COL_0, 1);           //   keeps Fit
      tog_line = -1;
      expect_lb(2, H, ROW_0_COL_0, 1);    drive_scan(2, H, ROW_0_COL_0, 1);           // LB from here
      tog_line = 1; tog_val = 0;                                                    // LB -> Fit at line 1
      expect_lb(3, H, ROW_0_COL_0, 1);    drive_scan(3, H, ROW_0_COL_0, 1);           //   keeps LB
      tog_line = -1;
      expect_plain(4, H, ROW_0_COL_0, 1); drive_scan(4, H, ROW_0_COL_0, 1);           // Fit again
    end else if (tcase == "frame_r" || tcase == "field_r") begin
      if (!$value$plusargs("ratio=%d", R)) R = 1;
      if (!$value$plusargs("h=%d", H)) H = (tcase == "frame_r") ? ((R >= 3) ? 480 : 576) : ((R >= 3) ? 240 : 288);
      if (!$value$plusargs("lines=%d", want_lines)) want_lines = -1;
      vscale_en = 1'b1; vscale_ratio = R[2:0]; lines_bad = 0;
      src_lines = (tcase == "frame_r") ? H : 2 * H;      // the stream's FRAME height
      for (s = 0; s < 4; s = s + 1) begin
        if (tcase == "frame_r") begin
          expect_cf(s, H, ROW_0_COL_0, 1, R); drive_scan(s, H, ROW_0_COL_0, 1);
        end else begin
          expect_cf(s, H, s[0] ? ROW_1_COL_0 : ROW_0_COL_0, 0, R);
          drive_scan(s, H, s[0] ? ROW_1_COL_0 : ROW_0_COL_0, 0);
        end
        if (want_lines >= 0 && last_lines != want_lines) begin
          $display("  LINE COUNT scan %0d: model %0d, want %0d", s, last_lines, want_lines); lines_bad = 1;
        end
      end
      if (lines_bad) errs = errs + 1;
    end else if (tcase == "field_x") begin
      if (!$value$plusargs("ratio=%d", R)) R = 3;
      if (!$value$plusargs("h=%d", H)) H = 240;
      vscale_en = 1'b1; vscale_ratio = R[2:0]; src_lines = 2 * H; lines_bad = 0;
      want_lines = (R == 3) ? H + H / 5 : H - H / 10;
      // T native, B xpar, T xpar, B native, T xpar, B xpar: every combination, and back to back
      for (s = 0; s < 6; s = s + 1) begin : fx
        integer xp;
        xp = (s == 1 || s == 2 || s == 4 || s == 5);
        expect_cfx(s, H, s[0] ? ROW_1_COL_0 : ROW_0_COL_0, 0, R, xp);
        drive_scanx(s, H, s[0] ? ROW_1_COL_0 : ROW_0_COL_0, 0, xp);
        if (last_lines != want_lines) begin
          $display("  LINE COUNT scan %0d: model %0d, want %0d", s, last_lines, want_lines); lines_bad = 1;
        end
      end
      if (lines_bad) errs = errs + 1;
    end else if (tcase == "rtoggle") begin
      if (!$value$plusargs("h=%d", H)) H = 576;
      vscale_en = 1'b1; vscale_ratio = 3'd1;
      expect_cf(0, H, ROW_0_COL_0, 1, 1); drive_scan(0, H, ROW_0_COL_0, 1);      // 5/6
      rtog_line = 1; rtog_val = 2;                                                // 5/6 -> 5/8 at line 1
      expect_cf(1, H, ROW_0_COL_0, 1, 1); drive_scan(1, H, ROW_0_COL_0, 1);      //   keeps 5/6
      rtog_line = -1;
      expect_cf(2, H, ROW_0_COL_0, 1, 2); drive_scan(2, H, ROW_0_COL_0, 1);      // 5/8 from here
      rtog_line = 1; rtog_val = 0;                                                // 5/8 -> 3/4 at line 1
      expect_cf(3, H, ROW_0_COL_0, 1, 2); drive_scan(3, H, ROW_0_COL_0, 1);      //   keeps 5/8
      rtog_line = -1;
      expect_cf(4, H, ROW_0_COL_0, 1, 0); drive_scan(4, H, ROW_0_COL_0, 1);      // 3/4
    end else begin
      $display("unknown +case=%0s", tcase); $fatal(1);
    end

    // drain
    for (s = 0; s < 200000 && gn < en; s = s + 1) @(posedge clk);
    repeat (200) @(posedge clk);
    if (dumpf != 0) $fclose(dumpf);
    $display("case=%0s H=%0d bp=%0d: %0d/%0d pixels (%0d lines of %0d expected), %0d errors",
             tcase, H, bp, gn, en, gn / W, en / W, errs);
    if (gn !== en || errs != 0) begin $display("RESULT: FAIL"); $fatal(1); end
    $display("RESULT: PASS");
    $finish;
  end
endmodule
