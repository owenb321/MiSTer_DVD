// ============================================================================
// bench/dvd/stop_ctl_tb.sv -- two-stage Stop + screensaver
// ============================================================================
// CLK_HZ is overridden to 1000 so a 5-minute timeout is 300k cycles, not 8.1
// billion. The RATIO under test is unchanged -- limit is in seconds either way.
//
// The load-bearing arm is [S7]: the screensaver must not disturb playback
// state. It is a display-layer verdict only, because clearing media_seen (the
// obvious implementation) would flip VIDEO_ARX/ARY and make Main re-init the
// scaler mid-film.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module stop_ctl_tb;
    localparam CLK_HZ = 1000;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg stop_edge = 0, play_edge = 0, any_input = 0, start_streaming = 0;
    reg media_seen = 1, paused = 0, resume_evt = 0;
    reg [1:0] saver_sel = 2'd0;

    wire stopped, restart, saver_on;

    stop_ctl #(.CLK_HZ(CLK_HZ)) dut (
        .clk(clk), .rst_n(rst_n),
        .stop_edge(stop_edge), .play_edge(play_edge), .any_input(any_input),
        .start_streaming(start_streaming), .media_seen(media_seen),
        .paused(paused), .resume_evt(resume_evt), .saver_sel(saver_sel),
        .stopped(stopped), .restart(restart), .saver_on(saver_on)
    );

    integer errors = 0;
    integer restarts = 0;
    always @(posedge clk) if (restart) restarts = restarts + 1;

    // ⚠ NOT a generic `task pulse(output reg sig)`. A Verilog task's output
    // argument is copied back to the caller's signal only when the task
    // RETURNS, so the DUT would see the final value (0) and never a pulse --
    // the first draft of this bench did exactly that and reported the RTL
    // broken while the stimulus was never reaching it. One task per signal.
    // Stimulus is driven from the NEGEDGE so it cannot race the posedge DUT.
    task p_stop;    begin @(negedge clk); stop_edge=1;       @(negedge clk); stop_edge=0;       @(posedge clk); end endtask
    task p_play;    begin @(negedge clk); play_edge=1;       @(negedge clk); play_edge=0;       @(posedge clk); end endtask
    task p_any;     begin @(negedge clk); any_input=1;       @(negedge clk); any_input=0;       @(posedge clk); end endtask
    task p_mount;   begin @(negedge clk); start_streaming=1; @(negedge clk); start_streaming=0; @(posedge clk); end endtask
    task p_resume;  begin @(negedge clk); resume_evt=1;      @(negedge clk); resume_evt=0;      @(posedge clk); end endtask

    task chk(input [70*8-1:0] lbl, input got, input want);
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("  FAIL %0s: got %b want %b", lbl, got, want);
            end else $display("  ok   %0s", lbl);
        end
    endtask

    task chki(input [70*8-1:0] lbl, input integer got, input integer want);
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("  FAIL %0s: got %0d want %0d", lbl, got, want);
            end else $display("  ok   %0s", lbl);
        end
    endtask

    // wait n simulated seconds (plus a little slack for the prescaler edge)
    task wait_s(input integer n);
        begin repeat (n * CLK_HZ + CLK_HZ/2) @(posedge clk); end
    endtask

    initial begin
        repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);

        // ---- [S1] stage 1: stop holds, PLAY resumes in place --------------
        $display("== S1: stage 1 = stop, PLAY resumes in place");
        p_stop;
        chk("S1a stopped", stopped, 1'b1);
        restarts = 0;
        p_play;
        chk("S1b resumed", stopped, 1'b0);
        chki("S1c NO restart (position kept)", restarts, 0);

        // ---- [S2] stage 2: stop twice, PLAY restarts from First Play ------
        $display("== S2: stage 2 = stop twice -> PLAY restarts from FP");
        p_stop;
        p_stop;
        chk("S2a still stopped", stopped, 1'b1);
        restarts = 0;
        p_play;
        chk("S2b resumed", stopped, 1'b0);
        chki("S2c restart pulsed ONCE", restarts, 1);

        // ---- [S3] a chapter/VM resume never asks for First Play ----------
        // It names its own destination, so restarting the disc would be wrong.
        $display("== S3: resume_evt clears a stage-2 stop without restarting");
        p_stop; p_stop;
        restarts = 0;
        p_resume;
        chk("S3a resumed", stopped, 1'b0);
        chki("S3b NO restart", restarts, 0);

        // ---- [S4] a fresh mount clears everything ------------------------
        $display("== S4: mount clears stop state");
        p_stop; p_stop;
        restarts = 0;
        p_mount;
        chk("S4a not stopped", stopped, 1'b0);
        p_play;
        chki("S4b mount forgot stage 2 (no restart)", restarts, 0);

        // ---- [S5] screensaver: default (sel 0) arms at 5 min -------------
        // The index-0 trap, asserted rather than trusted: a natural-reading
        // Off,2min,5min,10min list would leave the DEFAULT disabled.
        $display("== S5: default sel=0 arms at 5 min, not never");
        saver_sel = 2'd0; paused = 1;
        wait_s(299);
        chk("S5a quiet at 299 s", saver_on, 1'b0);
        wait_s(2);
        chk("S5b armed by 301 s", saver_on, 1'b1);

        // ---- [S6] any input dismisses it ---------------------------------
        $display("== S6: any input dismisses, and the count restarts");
        p_any;
        chk("S6a dismissed", saver_on, 1'b0);
        wait_s(299);
        chk("S6b count restarted (quiet at 299 s)", saver_on, 1'b0);
        wait_s(2);
        chk("S6c re-arms", saver_on, 1'b1);

        // ---- [S7] THE ONE THAT MATTERS: no playback state is disturbed ---
        $display("== S7: screensaver disturbs NO playback state");
        chk("S7a media_seen untouched", media_seen, 1'b1);
        chk("S7b still paused", paused, 1'b1);
        chk("S7c not stopped by the saver", stopped, 1'b0);
        p_any;

        // ---- [S8] Off never arms -----------------------------------------
        $display("== S8: Off never arms");
        saver_sel = 2'd1;
        wait_s(601);
        chk("S8a Off stays quiet past 10 min", saver_on, 1'b0);

        // ---- [S9] the other two timeouts ---------------------------------
        $display("== S9: 2 min and 10 min");
        saver_sel = 2'd2; p_any;
        wait_s(119); chk("S9a 2min quiet at 119 s", saver_on, 1'b0);
        wait_s(2);   chk("S9b 2min armed",          saver_on, 1'b1);
        saver_sel = 2'd3; p_any;
        wait_s(599); chk("S9c 10min quiet at 599 s", saver_on, 1'b0);
        wait_s(2);   chk("S9d 10min armed",          saver_on, 1'b1);

        // ---- [S10] arms on STOP too, not just pause ----------------------
        $display("== S10: a stopped disc also screensaves");
        saver_sel = 2'd2; paused = 0; p_any;
        wait_s(121);
        chk("S10a playing does NOT screensave", saver_on, 1'b0);
        p_stop;
        wait_s(121);
        chk("S10b stopped DOES screensave", saver_on, 1'b1);

        // ---- [S11] an empty slot never screensaves -----------------------
        $display("== S11: nothing loaded -> the idle screen is already up");
        p_any; media_seen = 0; paused = 1;
        wait_s(121);
        chk("S11a no media -> no saver", saver_on, 1'b0);

        if (errors == 0) $display("STOP_CTL_TB: ALL TESTS PASSED");
        else             $display("STOP_CTL_TB: FAILED (%0d errors)", errors);
        $finish;
    end
endmodule

`default_nettype wire
