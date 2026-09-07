// =============================================================================
// av_sync_tb.sv — the clk_sys mirror of the free-running STC (dvd/av_sync.sv).
// =============================================================================
// The clock lives in clk_dec (dvd/disp_sched.sv, bench disp_sched_tb); this
// module only mirrors it. So the checks are about the mirror being faithful:
//   [1] every mirror crossing lands: stc/stc_anchored track the sent values
//   [2] a re-anchor delta arrives as one pulse with the sent value and is counted
//   [3] drift = dispatched audio PTS - stc and buf_lag = parse PTS - stc are
//       plain modular 33-bit differences, sign-correct either side of zero
//   [4] the pipe reset does NOT touch the clock (only the core reset does)
// Build: iverilog -g2012 -o bench/dvd/av_sync_sim dvd/av_sync.sv bench/dvd/av_sync_tb.sv
// =============================================================================
`timescale 1ns/1ps
module av_sync_tb;
  reg clk = 0; always #18.5 clk = ~clk;      // ~27 MHz
  reg rst_n = 0;
  reg  [34:0] mirror_data = 0; reg mirror_valid = 0;
  wire        disp_anchored;
  reg signed [33:0] delta_data = 0; reg delta_valid = 0;
  reg  [32:0] vid_pts = 0; reg vid_pts_valid = 0;
  reg  [32:0] dispatch_pts = 0; reg dispatch_pts_valid = 0;
  wire [32:0] stc; wire stc_anchored, anchor_pulse;
  wire signed [33:0] anchor_delta; wire signed [31:0] drift, buf_lag; wire [15:0] reanchor_count;

  av_sync dut (.clk(clk), .rst_n(rst_n),
    .mirror_data(mirror_data), .mirror_valid(mirror_valid), .disp_anchored(disp_anchored),
    .delta_data(delta_data), .delta_valid(delta_valid),
    .vid_pts(vid_pts), .vid_pts_valid(vid_pts_valid),
    .dispatch_pts(dispatch_pts), .dispatch_pts_valid(dispatch_pts_valid),
    .stc(stc), .stc_anchored(stc_anchored), .anchor_pulse(anchor_pulse), .anchor_delta(anchor_delta),
    .drift(drift), .buf_lag(buf_lag), .reanchor_count(reanchor_count));

  integer errors = 0, pulses = 0, i;
  always @(posedge clk) if (anchor_pulse) pulses = pulses + 1;

  task automatic send(input [32:0] v, input a, input d);
    begin mirror_data <= {d, a, v}; mirror_valid <= 1; @(posedge clk); mirror_valid <= 0; @(posedge clk); end
  endtask

  initial begin
    #100 rst_n = 1; repeat (3) @(posedge clk);
    // [1] mirror tracks
    for (i = 0; i < 5; i = i + 1) begin
      send(33'd100000 + i * 300, 1'b1, 1'b1); @(posedge clk);
      if (stc !== 33'd100000 + i * 300 || stc_anchored !== 1'b1) begin
        $display("FAIL [1] mirror %0d: stc=%0d anchored=%0d", i, stc, stc_anchored); errors = errors + 1; end
    end
    send(33'd7, 1'b0, 1'b0); @(posedge clk);
    if (stc !== 33'd7 || stc_anchored !== 1'b0) begin $display("FAIL [1] unanchored mirror"); errors = errors + 1; end
    // ★ disp_anchored is a SEPARATE flag, not a copy of stc_anchored: the clock can be
    // anchored on the parse front (stc_anchored) while still not on the DISPLAY's
    // timeline. Audio's one-shot playback phase waits for the second one; mirroring
    // the wrong bit here would silently restore the 1.6 s lead of 2026-09-07.
    send(33'd500000, 1'b1, 1'b0); @(posedge clk);
    if (stc_anchored !== 1'b1 || disp_anchored !== 1'b0) begin
      $display("FAIL [1] provisional-only: stc_anchored=%0d disp_anchored=%0d (want 1/0)", stc_anchored, disp_anchored);
      errors = errors + 1; end
    send(33'd500100, 1'b1, 1'b1); @(posedge clk);
    if (disp_anchored !== 1'b1) begin $display("FAIL [1] disp_anchored did not mirror"); errors = errors + 1; end
    // [2] delta pulse
    delta_data <= -34'sd450000; delta_valid <= 1; @(posedge clk); delta_valid <= 0; repeat (2) @(posedge clk);
    if (pulses !== 1 || anchor_delta !== -34'sd450000 || reanchor_count !== 16'd1) begin
      $display("FAIL [2] delta: pulses=%0d delta=%0d count=%0d", pulses, anchor_delta, reanchor_count); errors = errors + 1; end
    // [3] telemetry differences, both signs, modular across the 33-bit wrap
    send(33'd1000000, 1'b1, 1'b1);
    dispatch_pts <= 33'd1009000; dispatch_pts_valid <= 1; vid_pts <= 33'd991000; vid_pts_valid <= 1; @(posedge clk);
    dispatch_pts_valid <= 0; vid_pts_valid <= 0; repeat (2) @(posedge clk);
    if (drift !== 32'sd9000 || buf_lag !== -32'sd9000) begin $display("FAIL [3] drift=%0d buf_lag=%0d", drift, buf_lag); errors = errors + 1; end
    send(33'h1_FFFF_FF00, 1'b1, 1'b1);                              // near the top of the 33-bit range
    dispatch_pts <= 33'd100; dispatch_pts_valid <= 1; @(posedge clk); dispatch_pts_valid <= 0; repeat (2) @(posedge clk);
    if (drift !== 32'sd356) begin $display("FAIL [3] wrap: drift=%0d (expected 356)", drift); errors = errors + 1; end
    // [4] only the core reset clears the clock (there is no pipe reset input at all --
    //     the port list is the guarantee); re-check it holds without traffic
    repeat (50) @(posedge clk);
    if (stc !== 33'h1_FFFF_FF00 || !stc_anchored) begin $display("FAIL [4] clock did not hold"); errors = errors + 1; end
    rst_n = 0; repeat (2) @(posedge clk); rst_n = 1; @(posedge clk);
    if (stc !== 0 || stc_anchored || reanchor_count !== 0) begin $display("FAIL [4] core reset did not clear"); errors = errors + 1; end
    if (errors == 0) $display("PASS: av_sync (mirror)"); else begin $display("FAIL: av_sync_tb %0d error(s)", errors); $fatal(1); end
    $finish;
  end
endmodule
