// seek_time_tb.sv -- unit test for dvd/seek_time.sv (the seek-preview clock).
//
// The HUD clock sat frozen at the position you left while the seek bar's cursor
// travelled. seek_time answers "what time will this land on?" from three
// sources; this drives all three over a synthetic but realistic cell table
// streamed in through the same taps the reader uses.
//
// ★ Expected timecodes are computed BY HAND from the table, not from a model
// that mirrors the RTL's own arithmetic -- an interpolation golden written the
// same way as the DUT would agree with it by construction.
//
//   iverilog -g2012 -o /tmp/st_sim dvd/seek_time.sv bench/dvd/seek_time_tb.sv
//   vvp /tmp/st_sim
`timescale 1ns/1ps
`default_nettype none

module seek_time_tb;
    reg clk = 1'b0;
    always #18.5 clk = ~clk;

    reg         rst_n = 1'b0;
    reg         pm_we = 0;    reg [6:0] pm_waddr = 0;  reg [7:0]  pm_wdata = 0;
    reg         cellf_we = 0; reg [6:0] cellf_idx = 0; reg [31:0] cellf_rbn = 0;
    reg  [15:0] cellf_secs = 0;
    reg  [15:0] title_secs = 0;
    reg  [31:0] title_first = 0, title_last = 0;

    reg         dpad_pend = 0, dpad_dir = 0;
    reg  [6:0]  dpad_min = 0;   reg [2:0] dpad_sec = 0;
    reg         chap_prev = 0;  reg [7:0] chap_pgm = 0;
    reg         bar_active = 0; reg [31:0] bar_tgt = 0;
    reg  [31:0] live_time = 32'h00_00_00_00;

    wire [16:0] prev_secs;
    wire        prev_ok;
    // Same as lin_rate_tb: assert the BCD a viewer reads, through the real
    // shared converter, not the seconds behind it.
    wire [31:0] prev_time, u1, u2, u3;
    secs_bcd bcd_i (
        .clk(clk), .rst_n(rst_n),
        .secs0(prev_secs), .secs1(17'd0), .secs2(17'd0), .secs3(17'd0),
        .bcd0(prev_time), .bcd1(u1), .bcd2(u2), .bcd3(u3)
    );

    seek_time dut (
        .clk(clk), .rst_n(rst_n),
        .pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata),
        .cellf_we(cellf_we), .cellf_idx(cellf_idx), .cellf_rbn(cellf_rbn),
        .cellf_secs(cellf_secs), .title_secs(title_secs),
        .title_first_rbn(title_first), .title_last_rbn(title_last),
        .dpad_pend(dpad_pend), .dpad_dir(dpad_dir),
        .dpad_min(dpad_min), .dpad_sec(dpad_sec),
        .chap_prev(chap_prev), .chap_pgm(chap_pgm),
        .bar_active(bar_active), .bar_tgt_rbn(bar_tgt),
        .live_time(live_time),
        .prev_secs(prev_secs), .prev_ok(prev_ok)
    );

    integer errors = 0;
    task automatic chk(input cond, input [255:0] msg);
        if (!cond) begin $display("  FAIL: %0s", msg); errors = errors + 1; end
    endtask
    task automatic chk_t(input [23:0] want, input [255:0] msg);
        if (prev_time[31:8] !== want) begin
            $display("  FAIL: %0s (got %06h want %06h)", msg, prev_time[31:8], want);
            errors = errors + 1;
        end
    endtask
    // ⚠ Stimulus is driven away from the clock edge: blocking assignments made
    // immediately after a posedge race the DUT's sampling of that same edge, and
    // the failure is scheduling-dependent (it stayed hidden in lin_rate_tb until
    // an unrelated width change reordered things). Same trap dpad_seek_tb hit --
    // see CLAUDE.md. Every wait settles on the negedge.
    task automatic tick(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(posedge clk);
            @(negedge clk);
        end
    endtask

    // ---- the synthetic title -----------------------------------------------
    // 8 cells x 900 s = 2:00:00, first_sector 1000 + i*150000. Chapters every
    // other cell. Deliberately NOT a round number of sectors per second, so an
    // interpolation that quietly rounded to cell granularity would show up.
    localparam integer NC   = 8;
    localparam integer STEP = 150000;
    localparam integer BASE = 1000;
    localparam integer DUR  = 900;

    task automatic stream_title(input integer ncells, input integer nprog,
                                input integer dur);
        integer i;
        begin
            for (i = 0; i < ncells; i = i + 1) begin
                @(negedge clk);
                cellf_we   = 1'b1;
                cellf_idx  = i[6:0];
                cellf_rbn  = BASE + i * STEP;
                cellf_secs = i * dur;
                @(negedge clk);
                cellf_we   = 1'b0;
            end
            for (i = 0; i < nprog; i = i + 1) begin
                @(negedge clk);
                pm_we    = 1'b1;
                pm_waddr = i[6:0];
                pm_wdata = (i * 2) + 1;          // 1-based entry cell: 1,3,5,7
                @(negedge clk);
                pm_we    = 1'b0;
            end
            @(negedge clk);
            title_secs  = ncells * dur;
            title_first = BASE;
            title_last  = BASE + ncells * STEP - 1;
            @(negedge clk);
        end
    endtask

    task automatic clear_req;
        begin dpad_pend = 0; chap_prev = 0; bar_active = 0; tick(6); end
    endtask

    task automatic ask_bar(input [31:0] r);
        begin clear_req(); bar_tgt = r; bar_active = 1'b1; tick(900); end
    endtask
    task automatic ask_chap(input [7:0] c);
        begin clear_req(); chap_pgm = c; chap_prev = 1'b1; tick(400); end
    endtask
    task automatic ask_dpad(input dir, input [6:0] mn, input [2:0] sc);
        begin clear_req(); dpad_dir = dir; dpad_min = mn; dpad_sec = sc;
              dpad_pend = 1'b1; tick(400); end
    endtask

    initial begin
        rst_n = 0; tick(4); rst_n = 1; tick(4);
        stream_title(NC, 4, DUR);

        // ---- T1: a chapter's start time is the AUTHORED one ----------------
        // pmap[c-1] -> entry cell -> that cell's start. No interpolation at all,
        // which is the point: a chapter target is a cell boundary by
        // construction and must not be approximated.
        $display("TEST 1: chapter start times");
        ask_chap(8'd1); chk(prev_ok, "chap 1 resolved"); chk_t(24'h00_00_00, "chap 1 = 0:00:00");
        ask_chap(8'd2); chk_t(24'h00_30_00, "chap 2 = 0:30:00");
        ask_chap(8'd3); chk_t(24'h01_00_00, "chap 3 = 1:00:00");
        ask_chap(8'd4); chk_t(24'h01_30_00, "chap 4 = 1:30:00");

        // ---- T2: an RBN exactly on a cell boundary ------------------------
        $display("TEST 2: RBN on a cell boundary");
        ask_bar(BASE + 3 * STEP);
        chk(prev_ok, "boundary resolved");
        chk_t(24'h00_45_00, "cell 3 start = 0:45:00");

        // ---- T3: an RBN inside a cell interpolates ------------------------
        // Halfway into cell 3: 2700 s + 900/2 = 3150 s.
        $display("TEST 3: interpolation inside a cell");
        ask_bar(BASE + 3 * STEP + (STEP / 2));
        chk_t(24'h00_52_30, "mid cell 3 = 0:52:30");
        // A quarter in: 2700 + 225 = 2925 s.
        ask_bar(BASE + 3 * STEP + (STEP / 4));
        chk_t(24'h00_48_45, "quarter cell 3 = 0:48:45");

        // ---- T4: the LAST cell brackets against the title, not a next cell -
        // There is no cellf[8], so the upper edge has to come from
        // title_last_rbn / title_secs -- which is why the reader exports them.
        $display("TEST 4: last cell uses the title end");
        ask_bar(BASE + 7 * STEP + (STEP / 2));
        chk_t(24'h01_52_30, "mid last cell = 1:52:30");

        // ---- T5: targets outside the title clamp --------------------------
        $display("TEST 5: clamps");
        ask_bar(32'd0);
        chk_t(24'h00_00_00, "below title start = 0:00:00");
        ask_bar(32'd2_000_000);
        chk_t(24'h02_00_00, "past title end = 2:00:00");

        // ---- T6: the D-pad delta, both ways, floored and capped -----------
        // dpad_sec is TENS of seconds, so (1, 3) is 1 min 30 s.
        $display("TEST 6: D-pad delta");
        live_time = 32'h01_00_00_00;                 // 1:00:00
        ask_dpad(1'b1, 7'd1, 3'd3); chk_t(24'h01_01_30, "fwd 1:30 -> 1:01:30");
        ask_dpad(1'b0, 7'd1, 3'd3); chk_t(24'h00_58_30, "back 1:30 -> 0:58:30");
        live_time = 32'h00_00_10_00;                 // 0:00:10
        ask_dpad(1'b0, 7'd5, 3'd0); chk_t(24'h00_00_00, "back past the start floors");
        live_time = 32'h01_59_00_00;                 // 1:59:00
        ask_dpad(1'b1, 7'd5, 3'd0); chk_t(24'h02_00_00, "fwd past the end caps");

        // ---- T7: request priority -----------------------------------------
        // A D-pad gesture is the most specific thing the user is doing, a
        // chapter burst next; the bar's cursor is the fallback.
        $display("TEST 7: request priority");
        live_time = 32'h01_00_00_00;
        clear_req();
        bar_tgt = BASE; bar_active = 1'b1;
        chap_pgm = 8'd4; chap_prev = 1'b1;
        dpad_dir = 1'b1; dpad_min = 7'd1; dpad_sec = 3'd3; dpad_pend = 1'b1;
        tick(400);
        chk_t(24'h01_01_30, "dpad outranks chapter and bar");
        dpad_pend = 1'b0; tick(400);
        chk_t(24'h01_30_00, "chapter outranks the bar");
        chap_prev = 1'b0; tick(900);
        chk_t(24'h00_00_00, "bar answers when alone");
        clear_req();
        chk(!prev_ok, "no request = no answer, HUD falls back to live");

        // ---- T8: an out-of-range chapter says nothing ---------------------
        // Better a live clock than a confidently wrong target time.
        $display("TEST 8: unknown chapter");
        ask_chap(8'd9);
        chk(!prev_ok, "chapter beyond the map = no answer");
        ask_chap(8'd0);
        chk(!prev_ok, "chapter 0 = no answer");

        // ---- T9: a new PGC replaces the map -------------------------------
        // The streams rewrite from index 0, so the entry count has to shrink
        // when a shorter PGC loads -- otherwise a target past the new end would
        // still be bracketed against the previous title's cells.
        // Shorter AND differently timed, so a stale entry would read as a
        // recognisably wrong number rather than a plausible one.
        $display("TEST 9: a shorter PGC replaces the table");
        stream_title(3, 2, 300);                 // 3 cells x 300 s = 0:15:00
        ask_bar(32'd2_000_000);
        chk_t(24'h00_15_00, "past the new end = new total");
        ask_chap(8'd2); chk_t(24'h00_10_00, "new chap 2 = cell 2 = 0:10:00");
        ask_chap(8'd3); chk(!prev_ok, "old chapter 3 is gone");

        if (errors == 0) $display("\nseek_time_tb: ALL TESTS PASSED");
        else begin
            $display("\nseek_time_tb: %0d FAILURE(S)", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin #50_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
`default_nettype wire
