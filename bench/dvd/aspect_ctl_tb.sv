// ============================================================================
// bench/dvd/aspect_ctl_tb.sv -- the Aspect button
// ============================================================================
// The load-bearing arm is [A4]: a mashed button must produce ONE settled
// change, not one per press. Every VIDEO_ARX/ARY change makes the framework
// re-init the scaler and pop a resolution notice, and emu.sv warns twice that
// a flapping value means video never stabilises -- so "counts transitions on
// the published output" is the property under test, not "the value is right".
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module aspect_ctl_tb;
    localparam CLK_HZ = 100_000;      // 10 us/tick -> SETTLE_MS is 25000 ticks
    localparam SETTLE_MS = 250;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg       aspct_edge = 0, analog_live = 0;
    reg [1:0] osd_ar = 2'd0, osd_aa = 2'd0;
    wire [1:0] ar_sel, aa_sel, evt_val;
    wire      evt, evt_analog;

    aspect_ctl #(.CLK_HZ(CLK_HZ), .SETTLE_MS(SETTLE_MS)) dut (
        .clk(clk), .rst_n(rst_n),
        .aspct_edge(aspct_edge), .analog_live(analog_live),
        .osd_ar(osd_ar), .osd_aa(osd_aa),
        .ar_sel(ar_sel), .aa_sel(aa_sel),
        .evt(evt), .evt_analog(evt_analog), .evt_val(evt_val)
    );

    integer errors = 0;

    // count PUBLISHED transitions -- this is the scaler-re-init proxy
    integer ar_changes = 0, aa_changes = 0, evts = 0;
    reg [1:0] ar_last, aa_last;
    always @(posedge clk) begin
        if (ar_sel !== ar_last) begin ar_changes = ar_changes + 1; ar_last = ar_sel; end
        if (aa_sel !== aa_last) begin aa_changes = aa_changes + 1; aa_last = aa_sel; end
        if (evt) evts = evts + 1;
    end

    task press; begin @(negedge clk); aspct_edge=1; @(negedge clk); aspct_edge=0; @(posedge clk); end endtask
    task settle_wait; begin repeat (SETTLE_MS * (CLK_HZ/1000) + 200) @(posedge clk); end endtask
    task zero; begin ar_changes=0; aa_changes=0; evts=0; end endtask

    task chki(input [70*8-1:0] lbl, input integer got, input integer want);
        begin
            if (got !== want) begin errors=errors+1;
                $display("  FAIL %0s: got %0d want %0d", lbl, got, want);
            end else $display("  ok   %0s", lbl);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); rst_n = 1;
        ar_last = ar_sel; aa_last = aa_sel;
        repeat (4) @(posedge clk);

        // ---- [A1] HDMI path: cycles Aspect Ratio, 3 values ---------------
        $display("== A1: not analog -> cycles Aspect Ratio (Auto/4:3/16:9)");
        analog_live = 0;
        press; settle_wait; chki("A1a -> 4:3", ar_sel, 1);
        press; settle_wait; chki("A1b -> 16:9", ar_sel, 2);
        press; settle_wait; chki("A1c wraps to Auto (3 values, not 4)", ar_sel, 0);

        // ---- [A2] analog path: cycles Analog Aspect, 4 values ------------
        $display("== A2: analog live -> cycles Analog Aspect (4 values)");
        analog_live = 1;
        press; settle_wait; chki("A2a -> Fit",       aa_sel, 1);
        press; settle_wait; chki("A2b -> Letterbox", aa_sel, 2);
        press; settle_wait; chki("A2c -> Crop",      aa_sel, 3);
        press; settle_wait; chki("A2d wraps to Auto", aa_sel, 0);
        chki("A2e Aspect Ratio untouched while analog", ar_sel, 0);

        // ---- [A3] the HUD is told which control moved, and to what -------
        $display("== A3: evt names the control and the destination");
        analog_live = 0; zero;
        press;
        chki("A3a one evt", evts, 1);
        chki("A3b evt_analog=0 on the HDMI path", evt_analog, 0);
        chki("A3c evt_val = the value it moves to", evt_val, 1);
        settle_wait;

        // ---- [A4] THE ONE THAT MATTERS: mashing = ONE settled change -----
        // Ten presses inside the settle window must move the published value
        // exactly once. One scaler re-init per press is the regression.
        $display("== A4: ten rapid presses = ONE published change");
        analog_live = 0; osd_ar = 2'd0; settle_wait; zero;
        repeat (10) begin press; repeat (50) @(posedge clk); end
        chki("A4a HUD saw all ten presses", evts, 10);
        chki("A4b published value has NOT moved yet", ar_changes, 0);
        settle_wait;
        chki("A4c exactly ONE published change", ar_changes, 1);

        // ---- [A5] the OSD reclaims its control ---------------------------
        // Otherwise the button and the OSD fight and the OSD appears dead.
        $display("== A5: an OSD change takes the control back");
        analog_live = 0; press; settle_wait;
        @(negedge clk); osd_ar = 2'd2;          // user picks 16:9 in the OSD
        repeat (4) @(posedge clk);
        chki("A5a OSD wins immediately", ar_sel, 2);
        settle_wait;
        chki("A5b and keeps it", ar_sel, 2);

        // ---- [A6] untouched controls pass the OSD straight through -------
        $display("== A6: before any press, the OSD passes through unchanged");
        chki("A6a analog aspect still the OSD's", aa_sel, osd_aa);

        // ---- [A7] the press that CLAIMS ownership must not snap the picture
        // Taking ownership gates the output immediately, but the published
        // register still holds whatever it last published (0 = Auto after
        // reset). If it is not seeded from the OSD on the claiming press, the
        // picture jumps the instant the button is touched -- a scaler re-init
        // BEFORE the settle window, which is the very thing settling prevents.
        // A5 leaves osd_ar = 16:9 with the OSD owning it, which is exactly the
        // state that exposes this (the earlier arms all start from Auto=0,
        // where seeding is a no-op and the bug is invisible).
        $display("== A7: claiming ownership must not move the picture");
        analog_live = 0;
        chki("A7a OSD owns 16:9 to start", ar_sel, 2);
        press;
        repeat (20) @(posedge clk);
        chki("A7b still 16:9 during the settle window", ar_sel, 2);
        settle_wait;
        chki("A7c then wraps to Auto", ar_sel, 0);

        if (errors == 0) $display("ASPECT_CTL_TB: ALL TESTS PASSED");
        else             $display("ASPECT_CTL_TB: FAILED (%0d errors)", errors);
        $finish;
    end
endmodule

`default_nettype wire
