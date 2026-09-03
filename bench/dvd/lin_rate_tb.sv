// lin_rate_tb.sv -- unit test for dvd/lin_rate.sv.
//
// Two things under test: the blocks-per-10 s rate a flat .mpg/.VOB needs for
// D-Pad Seek (issue #39), and the elapsed/total/preview clock every linear mode
// needs for the HUD.
//
// ★ The stimulus is a STREAM MODEL, not a poke of internal state: a driver
// advances lin_blk one block at a time and emits a vid_pts sample every picture
// interval, at whatever rate the test asks for. So the tests measure what the
// module would do on a real file, including the picture-quantisation the design
// has to divide its way around -- a test that wrote pts0/blk0 directly would
// have hidden exactly the error the divider exists to remove.
//
//   iverilog -g2012 -o /tmp/lr_sim dvd/lin_rate.sv bench/dvd/lin_rate_tb.sv
//   vvp /tmp/lr_sim
`timescale 1ns/1ps
`default_nettype none

module lin_rate_tb;
    reg clk = 1'b0;
    always #18.5 clk = ~clk;            // ~27 MHz

    reg         rst_n = 1'b0;
    reg         en = 1'b1, raw_mode = 1'b0;
    reg         mount = 1'b0, flush = 1'b0, sec_tick = 1'b0;
    reg  [32:0] vid_pts = 33'd0;
    reg         vid_pts_valid = 1'b0;
    reg  [31:0] lin_blk = 32'd0;
    reg  [31:0] total_blk = 32'd1_000_000;
    reg  [31:0] prev_rbn = 32'd0;
    reg         prev_req = 1'b0;

    wire [23:0] blk10;
    wire        blk10_ok;
    wire [31:0] cur_time, total_time, prev_time;
    wire        prev_ok, time_ok;

    lin_rate dut (
        .clk(clk), .rst_n(rst_n), .en(en), .raw_mode(raw_mode),
        .mount(mount), .flush(flush), .sec_tick(sec_tick),
        .vid_pts(vid_pts), .vid_pts_valid(vid_pts_valid),
        .lin_blk(lin_blk), .total_blk(total_blk),
        .prev_rbn(prev_rbn), .prev_req(prev_req),
        .blk10(blk10), .blk10_ok(blk10_ok),
        .cur_time(cur_time), .total_time(total_time), .prev_time(prev_time),
        .prev_ok(prev_ok), .time_ok(time_ok)
    );

    integer errors = 0;
    task automatic chk(input cond, input [255:0] msg);
        if (!cond) begin $display("  FAIL: %0s", msg); errors = errors + 1; end
    endtask

    task automatic tick(input integer n);
        integer k; begin for (k = 0; k < n; k = k + 1) @(posedge clk); end
    endtask

    // ---- stream model -------------------------------------------------------
    // Play `pics` pictures at `bps10` blocks per 10 s: each picture is PIC_TICKS
    // of PTS and carries its share of the blocks. lin_blk advances one block per
    // clock so the fetch front looks like a real reader's.
    localparam PIC_TICKS = 3003;        // one NTSC frame at 90 kHz
    task automatic play(input integer pics, input integer bps10);
        integer p, b, want, k;
        begin
            for (p = 0; p < pics; p = p + 1) begin
                // blocks this picture is worth = bps10 * PIC_TICKS / 900000
                want = (bps10 * PIC_TICKS) / 900000;
                for (b = 0; b < want; b = b + 1) begin
                    @(posedge clk); lin_blk = lin_blk + 32'd1;
                end
                vid_pts = vid_pts + PIC_TICKS;
                @(posedge clk); vid_pts_valid = 1'b1;
                @(posedge clk); vid_pts_valid = 1'b0;
                // let the engine finish any job it just queued
                tick(120);
            end
        end
    endtask

    task automatic pulse_sec;
        begin @(posedge clk); sec_tick = 1'b1; @(posedge clk); sec_tick = 1'b0;
              tick(400); end
    endtask

    // |a-b| within pct% of b, reported with the numbers so a near-miss is
    // debuggable from the log rather than just "FAIL".
    task automatic chk_near(input integer a, input integer b, input integer pct,
                            input [255:0] msg);
        integer d, lim;
        begin
            d   = (a > b) ? (a - b) : (b - a);
            lim = (b * pct) / 100;
            if (d > lim) begin
                $display("  FAIL: %0s (got %0d, want %0d +/-%0d%%)", msg, a, b, pct);
                errors = errors + 1;
            end
        end
    endtask

    // ---- independent golden for the clock ----------------------------------
    // The MEASURED rate is not exactly the rate played (picture quantisation,
    // and the EMA is deliberately slow), so asserting a fixed timecode would be
    // testing the measurement, not the clock. Compute the expected seconds in
    // the TB from the rate the DUT actually settled on, and compare the BCD
    // exactly -- that gates the divider and the digit conversion on their own.
    function automatic [31:0] bcd_of(input integer secs);
        integer t, h, mt, mo, st;
        begin
            t = (secs > 35999) ? 35999 : secs;
            h  = t / 3600;  t = t - h  * 3600;
            mt = t / 600;   t = t - mt * 600;
            mo = t / 60;    t = t - mo * 60;
            st = t / 10;    t = t - st * 10;
            bcd_of = {4'd0, h[3:0], mt[3:0], mo[3:0], st[3:0], t[3:0], 8'h00};
        end
    endfunction

    task automatic chk_time(input [31:0] got, input integer blk, input integer rate,
                            input [255:0] msg);
        integer want_s;
        reg [31:0] want;
        begin
            want_s = (blk * 10) / rate;
            want   = bcd_of(want_s);
            if (got[31:8] !== want[31:8]) begin
                $display("  FAIL: %0s (got %06h, want %06h for %0d blk @ %0d/10s)",
                         msg, got[31:8], want[31:8], blk, rate);
                errors = errors + 1;
            end
        end
    endtask

    integer arm_val, ref_val, step_val, rate_now;

    initial begin
        rst_n = 0; tick(4); rst_n = 1; tick(4);

        // ---- T1: raw CD bypasses the measurement entirely ------------------
        // Not "861 eventually" -- 861 with no PTS ever presented, because the
        // bypass is what makes this module a no-op on the VCD path.
        $display("TEST 1: raw CD bypass");
        raw_mode = 1'b1; tick(4);
        chk(blk10 == 24'd861, "raw: 861 with no PTS");
        chk(blk10_ok == 1'b1, "raw: valid immediately");
        en = 1'b0; tick(2);
        chk(blk10_ok == 1'b0, "raw: invalid when !en");
        en = 1'b1; raw_mode = 1'b0; tick(4);
        chk(blk10_ok == 1'b0, "flat: starts with no estimate");

        // ---- T2: arms on the short window ----------------------------------
        // 3000 blocks/10 s = 614 KB/s ~ 4.9 Mbit/s, an ordinary DVD-ish rate.
        $display("TEST 2: arm on the 0.5 s window");
        play(20, 3000);
        chk(blk10_ok, "arm: valid after ~0.5 s");
        arm_val = blk10;
        chk_near(arm_val, 3000, 5, "arm: within 5% of 3000");

        // ---- T3: refines on the long window --------------------------------
        $display("TEST 3: refine on the 8 s window");
        play(300, 3000);
        ref_val = blk10;
        chk_near(ref_val, 3000, 2, "refine: within 2% of 3000");

        // ---- T4: follows a rate change without overshooting ----------------
        // The EMA must walk toward the new rate and stop there; an overshoot
        // would mean a jump longer than the user asked for.
        $display("TEST 4: rate step 3000 -> 6000");
        step_val = blk10;
        play(900, 6000);
        chk(blk10 > step_val, "step: moved toward new rate");
        chk(blk10 <= 24'd6300, "step: never overshoots the new rate");
        play(1500, 6000);
        chk_near(blk10, 6000, 5, "step: converges on 6000");

        // ---- T5: a PTS discontinuity is not a rate -------------------------
        $display("TEST 5: PTS discontinuity rejected");
        ref_val = blk10;
        vid_pts = vid_pts + 33'd54_000_000;         // +10 min in one sample
        @(posedge clk); vid_pts_valid = 1'b1;
        @(posedge clk); vid_pts_valid = 1'b0; tick(200);
        chk(blk10 == ref_val[23:0], "disc: estimate untouched");
        play(300, 6000);
        chk_near(blk10, 6000, 5, "disc: still tracking");

        // ---- T6: a seek must NOT cost the estimate -------------------------
        // This is the tap-jump-tap property: a D-pad jump pulses load_flush, and
        // if that cleared the estimate the next tap within the window would be
        // refused -- the stale-table trap in a new hat.
        $display("TEST 6: flush restarts the window, keeps the estimate");
        ref_val = blk10;
        lin_blk = lin_blk - 32'd50_000;             // seek backwards
        vid_pts = vid_pts - 33'd1_000_000;
        @(posedge clk); flush = 1'b1; @(posedge clk); flush = 1'b0; tick(200);
        chk(blk10_ok, "flush: still valid");
        chk(blk10 == ref_val[23:0], "flush: estimate unchanged");

        // ---- T7: a new file is a new rate ----------------------------------
        $display("TEST 7: mount clears");
        @(posedge clk); mount = 1'b1; @(posedge clk); mount = 1'b0; tick(200);
        chk(!blk10_ok, "mount: estimate dropped");
        chk(blk10 == 24'd0, "mount: rate zeroed");
        chk(!time_ok, "mount: clock invalid");

        // ---- T8: the clock, on a flat file ---------------------------------
        // 3000 blocks/10 s, playhead 1_117_500 blocks => 3725 s = 1:02:05.
        // total 2_160_000 blocks => 7200 s = 2:00:00.
        $display("TEST 8: elapsed / total clock");
        play(40, 3000);
        play(400, 3000);
        chk_near(blk10, 3000, 2, "clock: rate settled first");
        rate_now = blk10;
        lin_blk = 32'd1_117_500; total_blk = 32'd2_160_000; tick(4);
        pulse_sec;
        chk(time_ok, "clock: valid");
        chk_time(cur_time,   1_117_500, rate_now, "clock: elapsed");
        chk_time(total_time, 2_160_000, rate_now, "clock: total");
        chk(cur_time[7:0] == 8'h00, "clock: frame byte clear");

        // ---- T9: the clock on a raw CD uses the exact geometry -------------
        $display("TEST 9: raw CD clock");
        raw_mode = 1'b1; lin_blk = 32'd8610; total_blk = 32'd86_100; tick(4);
        pulse_sec;
        chk(cur_time[31:8]   == 24'h00_01_40, "raw clock: 8610 blk = 1:40");
        chk(total_time[31:8] == 24'h00_16_40, "raw clock: total 16:40");

        // ---- T10: the readout saturates instead of wrapping ----------------
        $display("TEST 10: SEC_CAP clamp");
        lin_blk = 32'd90_000_000; tick(4);
        pulse_sec;
        chk(cur_time[31:8] == 24'h09_59_59, "cap: clamps at 9:59:59");

        // ---- T11: an implausible RATE is not evidence ----------------------
        // Distinct from the DBLK_MAX window guard: these rates produce windows
        // that are perfectly well formed and simply describe a file that cannot
        // exist. 100_000 blk/10 s is ~20 MB/s; 50 is ~10 KB/s. Both must leave
        // the honest estimate standing rather than replace it.
        $display("TEST 11: out-of-range measurement rejected");
        raw_mode = 1'b0; lin_blk = 32'd0; vid_pts = 33'd0;
        @(posedge clk); mount = 1'b1; @(posedge clk); mount = 1'b0; tick(50);
        play(40, 3000);                              // arm honestly
        ref_val = blk10;
        chk(blk10_ok, "range: armed");
        play(300, 100_000);                          // above BLK10_MAX
        chk(blk10 == ref_val[23:0], "range: too-fast rate ignored");
        play(300, 50);                               // below BLK10_MIN
        chk(blk10 == ref_val[23:0], "range: too-slow rate ignored");

        // ---- T12: the seek-preview job -------------------------------------
        // The preview resolves an arbitrary target, which is what makes the HUD
        // clock track the seek bar's cursor instead of sitting frozen.
        // Exercised in raw mode so the rate is the exact CD constant and the
        // timecodes below are absolute, not derived from a measurement.
        $display("TEST 12: preview job");
        raw_mode = 1'b1; lin_blk = 32'd0; total_blk = 32'd1_000_000; tick(10);
        chk(!prev_ok, "preview: idle when !prev_req");
        prev_rbn = 32'd8_610; prev_req = 1'b1; tick(400);
        chk(prev_ok, "preview: resolved");
        chk(prev_time[31:8] == 24'h00_01_40, "preview: 8610 blk = 1:40");
        prev_rbn = 32'd51_660; tick(400);            // 600 s = 0:10:00
        chk(prev_time[31:8] == 24'h00_10_00, "preview: follows target");
        prev_req = 1'b0; tick(10);
        chk(!prev_ok, "preview: drops at gesture end");

        // ---- T13: one window may only nudge the estimate -------------------
        // The EMA is what keeps a VBR file's per-window swing out of the seek
        // length. Without it a single unrepresentative window would redefine
        // the rate outright, so pin the step: one refine window (240 pictures
        // at 3003 ticks = 720_720 >= WIN_REF, so exactly one closes) must move
        // the estimate a QUARTER of the way to the new rate, not all of it.
        $display("TEST 13: one window moves the estimate a quarter");
        raw_mode = 1'b0; lin_blk = 32'd0; vid_pts = 33'd0;
        @(posedge clk); mount = 1'b1; @(posedge clk); mount = 1'b0; tick(50);
        play(40, 3000); play(700, 3000);             // settle honestly at ~3000
        ref_val = blk10;
        play(250, 6000);                             // exactly one refine window
        step_val = blk10;
        chk(step_val > ref_val, "ema: moved toward the new rate");
        chk((step_val - ref_val) < ((6000 - ref_val) / 2),
            "ema: <half the gap in 1 win");

        if (errors == 0) $display("\nlin_rate_tb: ALL TESTS PASSED");
        else begin
            $display("\nlin_rate_tb: %0d FAILURE(S)", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin #900_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
`default_nettype wire
