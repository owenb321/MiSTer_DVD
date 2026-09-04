// ============================================================================
// bench/dvd/dpad_seek_tb.sv -- unit tests for dvd/dpad_seek.sv
// ============================================================================
// Drives the REAL dvd/nav_dsi.sv from a synthetic 2048-byte-equivalent DSI
// payload built here, so the tests are self-contained and committed:
// bench/dvd/test_vobs/ is gitignored, so nothing load-bearing may depend on the
// real-disc fixtures (nav_dsi_tb skips itself when they are absent).
//
//   iverilog -g2012 -o /tmp/dpad_sim dvd/dpad_seek.sv dvd/nav_dsi.sv \
//            bench/dvd/dpad_seek_tb.sv && vvp /tmp/dpad_sim
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module dpad_seek_tb;

    localparam integer COAL = 200;      // shrunk coalesce window (cycles)
    localparam integer FRTO = 4000;     // shrunk wait-for-fresh timeout

    reg clk = 1'b0;
    always #18.5 clk = ~clk;            // ~27 MHz

    reg         rst_n = 1'b0;
    reg         nav_rst_n = 1'b0;       // the DUT's pipe_rst_n twin for nav_dsi
    reg         en = 1'b1, in_title = 1'b1, dvd_mode = 1'b1, lin_mode = 1'b0;
    reg         up_e = 0, dn_e = 0, lf_e = 0, rt_e = 0, cancel = 0;
    reg         nav_flush = 0;
    reg  [31:0] lin_blk = 32'd100_000;
    // Blocks per 10 s of linear file: the exact CD geometry for a raw VCD/SVCD
    // image (861 = 75 sectors/s * 2352 B / 2048), or a MEASURED rate for a flat
    // program stream (dvd/lin_rate.sv). The DUT must not care which.
    reg  [23:0] lin_blk10 = 24'd861;

    reg  [7:0]  dsi_byte = 8'd0;
    reg         dsi_valid = 1'b0, dsi_fs = 1'b0;

    wire [31:0] nv_pck_lbn, vobu_ea, next_vobu, prev_vobu;
    wire        dsi_commit;
    wire [5:0]  tbl_raddr;
    wire [31:0] tbl_rdata;
    // T0 probe: the DUT parks tbl_raddr at 0 while idle, so the TB may drive the
    // nav_dsi read port itself to inspect the table.
    reg  [5:0]  tbl_probe = 6'd0;
    wire [5:0]  tbl_addr_mux = (tbl_probe != 6'd0) ? tbl_probe : tbl_raddr;

    nav_dsi nav_dsi_i (
        .clk(clk), .rst_n(nav_rst_n),
        .dsi_byte(dsi_byte), .dsi_valid(dsi_valid), .dsi_frame_start(dsi_fs),
        .dsi_nv_pck_lbn(nv_pck_lbn), .dsi_vobu_ea(vobu_ea),
        .dsi_1stref_ea(), .dsi_vob_idn(), .dsi_c_idn(), .dsi_c_eltm(),
        .dsi_next_vobu(next_vobu), .dsi_prev_vobu(prev_vobu),
        .dsi_next_video(), .dsi_prev_video(),
        .dsi_category(), .dsi_ilvu_block(), .dsi_ilvu_last(),
        .dsi_commit(dsi_commit),
        .tbl_raddr(tbl_addr_mux), .tbl_rdata(tbl_rdata));

    wire        jump_fire, jump_dir, pend, pend_dir, pend_evt, pend_fail;
    wire [31:0] jump_base, jump_off;
    wire [1:0]  pend_n;
    wire [6:0]  pend_min;
    wire [2:0]  pend_sec;

    dpad_seek #(.COALESCE(COAL), .FRESH_TO(FRTO)) dut (
        .clk(clk), .rst_n(rst_n), .en(en), .in_title(in_title),
        .dvd_mode(dvd_mode), .lin_mode(lin_mode),
        .up_edge(up_e), .dn_edge(dn_e), .lf_edge(lf_e), .rt_edge(rt_e),
        .cancel(cancel), .nav_flush(nav_flush),
        .dsi_commit(dsi_commit), .dsi_stream(dsi_valid),
        .dsi_nv_pck_lbn(nv_pck_lbn), .dsi_vobu_ea(vobu_ea),
        .dsi_next_vobu(next_vobu), .dsi_prev_vobu(prev_vobu),
        .tbl_raddr(tbl_raddr), .tbl_rdata(tbl_rdata), .lin_blk(lin_blk),
        .lin_blk10(lin_blk10),
        .jump_fire(jump_fire), .jump_dir(jump_dir),
        .jump_base(jump_base), .jump_off(jump_off),
        .pend(pend), .pend_dir(pend_dir), .pend_n(pend_n),
        .pend_min(pend_min), .pend_sec(pend_sec),
        .pend_evt(pend_evt), .pend_fail(pend_fail));

    integer errors = 0;

    // ---- fire / fail capture ----------------------------------------------
    integer fires = 0, fails = 0;
    reg [31:0] f_off, f_base; reg f_dir;
    always @(posedge clk) begin
        if (jump_fire) begin fires = fires + 1; f_off = jump_off;
                             f_base = jump_base; f_dir = jump_dir; end
        if (pend_fail) fails = fails + 1;
        if (jump_fire && jump_base == 32'd0)
            begin $display("FATAL: jump_fire with jump_base==0 (stale-table trap)");
                  errors = errors + 1; end
    end

    // ---- synthetic DSI payload --------------------------------------------
    localparam integer DSI_LEN = 979;
    reg [7:0] sec [0:DSI_LEN-1];
    integer i;

    task put32(input integer off, input [31:0] v);
        begin sec[off+0]=v[31:24]; sec[off+1]=v[23:16];
              sec[off+2]=v[15:8];  sec[off+3]=v[7:0]; end
    endtask
    task put_fwda(input integer idx, input [31:0] v); put32(32'hEE  + idx*4, v); endtask
    task put_bwda(input integer idx, input [31:0] v); put32(32'h142 + idx*4, v); endtask

    localparam [31:0] EOC = 32'h3fff_ffff;      // END_OF_CELL sentinel
    localparam [31:0] LBN0 = 32'd500_000;

    // default table: distinct offsets so the test can name the rung that was used
    task setup_dsi(input [31:0] lbn);
        begin
            for (i = 0; i < DSI_LEN; i = i + 1) sec[i] = 8'h00;
            put32(32'h04, lbn);                       // nv_pck_lbn
            put32(32'h08, 32'd420);                   // vobu_ea
            put32(32'h13A, 32'h8000_0000 | 32'd430);  // next_vobu
            put32(32'h13E, 32'h8000_0000 | 32'd440);  // prev_vobu
            for (i = 0; i < 19; i = i + 1) begin
                put_fwda(i, 32'h8000_0000 | (32'd100 + i));
                put_bwda(i, 32'h8000_0000 | (32'd200 + i));
            end
            put_fwda(0, 32'h8000_0000 | 32'd30000);   // +120 s
            put_fwda(1, 32'h8000_0000 | 32'd15000);   // +60 s
            put_fwda(2, 32'h8000_0000 | 32'd7500);    // +30 s
            put_fwda(3, 32'h8000_0000 | 32'd2500);    // +10 s
            put_bwda(18, 32'h8000_0000 | 32'd31000);  // -120 s (dsi_tbl addr 37)
            put_bwda(17, 32'h8000_0000 | 32'd16000);  // -60 s  (addr 36)
            put_bwda(16, 32'h8000_0000 | 32'd8000);   // -30 s  (addr 35)
            put_bwda(15, 32'h8000_0000 | 32'd2600);   // -10 s  (addr 34)
        end
    endtask

    task feed_dsi;
        integer b;
        begin
            @(negedge clk);
            for (b = 0; b < DSI_LEN; b = b + 1) begin
                dsi_byte  = sec[b];
                dsi_valid = 1'b1;
                dsi_fs    = (b == 0);
                @(negedge clk);
            end
            dsi_valid = 1'b0; dsi_fs = 1'b0;
            repeat (4) @(negedge clk);
        end
    endtask

    // ---- stimulus helpers --------------------------------------------------
    task tick(input integer n); begin repeat (n) @(negedge clk); end endtask

    task press(input [1:0] d);   // 0=R 1=L 2=U 3=D
        begin
            @(negedge clk);
            rt_e = (d==2'd0); lf_e = (d==2'd1);
            up_e = (d==2'd2); dn_e = (d==2'd3);
            @(negedge clk);
            rt_e = 0; lf_e = 0; up_e = 0; dn_e = 0;
        end
    endtask

    task arm;                    // clean slate: fresh DSI, counters zeroed
        begin
            nav_rst_n = 1'b0; tick(2); nav_rst_n = 1'b1; tick(2);
            feed_dsi();
            fires = 0; fails = 0; f_off = 0; f_base = 0; f_dir = 0;
        end
    endtask

    task expect_fire(input [80*8-1:0] lbl, input [31:0] off, input dir,
                     input [31:0] base);
        begin
            tick(COAL + 400);
            if (fires != 1) begin
                $display("FAIL %0s: expected 1 fire, got %0d", lbl, fires);
                errors = errors + 1;
            end else if (f_off !== off || f_dir !== dir || f_base !== base) begin
                $display("FAIL %0s: off=%0d (want %0d) dir=%0b (want %0b) base=%0d (want %0d)",
                         lbl, f_off, off, f_dir, dir, f_base, base);
                errors = errors + 1;
            end else
                $display("PASS %0s: off=%0d dir=%0b base=%0d", lbl, f_off, f_dir, f_base);
        end
    endtask

    task expect_none(input [80*8-1:0] lbl, input integer want_fail);
        begin
            tick(COAL + 400);
            if (fires != 0) begin
                $display("FAIL %0s: expected NO fire, got %0d (off=%0d)", lbl, fires, f_off);
                errors = errors + 1;
            end else if (want_fail && fails == 0) begin
                $display("FAIL %0s: expected pend_fail", lbl);
                errors = errors + 1;
            end else
                $display("PASS %0s: no fire (fails=%0d)", lbl, fails);
        end
    endtask

    initial begin
        setup_dsi(LBN0);
        tick(4); rst_n = 1'b1; nav_rst_n = 1'b1; tick(4);

        // ---- T0: DEMONSTRATE the hazard dsi_fresh exists to cover --------
        // nav_dsi's rst_n clears the scalars but dsi_tbl/tbl_rdata live in a
        // SEPARATE UNRESET always block. This asserts that asymmetry directly,
        // so the trap is documented executably rather than only in prose.
        arm;
        tbl_probe = 6'd3; tick(3);
        if (tbl_rdata !== (32'h8000_0000 | 32'd2500)) begin
            $display("FAIL T0: table read back wrong before reset (%08x)", tbl_rdata);
            errors = errors + 1;
        end
        nav_rst_n = 1'b0; tick(3); nav_rst_n = 1'b1; tick(3);
        if (nv_pck_lbn !== 32'd0) begin
            $display("FAIL T0: nv_pck_lbn should clear on reset"); errors = errors + 1;
        end else if (tbl_rdata !== (32'h8000_0000 | 32'd2500)) begin
            $display("FAIL T0: dsi_tbl unexpectedly cleared -- re-read dpad_seek's");
            $display("         stale-table note; the freshness gate may be re-derivable");
            errors = errors + 1;
        end else
            $display("PASS T0: base cleared but dsi_tbl RETAINED = the stale-table trap");
        tbl_probe = 6'd0;

        // ---- T1: single Right = exactly fwda[3] ---------------------------
        arm; press(2'd0);
        expect_fire("T1 1xR = +10s fwda[3]", 32'd2500, 1'b1, LBN0);
        tick(120);      // let the MM:SS subtract loop settle
        if (pend_min !== 7'd0 || pend_sec !== 3'd1) begin
            $display("FAIL T1 readout %0d:%0d0 want 0:10", pend_min, pend_sec);
            errors = errors + 1; end

        // ---- T2: 2xR = two 10 s terms (no 20 s rung exists) ---------------
        arm; press(2'd0); press(2'd0);
        expect_fire("T2 2xR = 2 x fwda[3]", 32'd5000, 1'b1, LBN0);

        // ---- T3: 3xR = ONE exact 30 s lookup (the greedy-ladder payoff) ---
        arm; press(2'd0); press(2'd0); press(2'd0);
        expect_fire("T3 3xR = fwda[2] exact", 32'd7500, 1'b1, LBN0);

        // ---- T4: 6xR / 1xU / 2xU = exact 60 / 60 / 120 s ------------------
        arm; press(2'd0); press(2'd0); press(2'd0);
             press(2'd0); press(2'd0); press(2'd0);
        expect_fire("T4a 6xR = fwda[1] exact", 32'd15000, 1'b1, LBN0);
        arm; press(2'd2);
        expect_fire("T4b 1xU = fwda[1] exact", 32'd15000, 1'b1, LBN0);
        arm; press(2'd2); press(2'd2);
        expect_fire("T4c 2xU = fwda[0] exact", 32'd30000, 1'b1, LBN0);

        // ---- T5: backward addresses (37-a mirror) -------------------------
        arm; press(2'd1);
        expect_fire("T5a 1xL = bwda addr34", 32'd2600, 1'b0, LBN0);
        arm; press(2'd3);
        expect_fire("T5b 1xD = bwda addr36", 32'd16000, 1'b0, LBN0);

        // ---- T6: coarse cascade, leftover seconds credited ----------------
        setup_dsi(LBN0); put_fwda(1, EOC);            // 60 s rung END_OF_CELL
        arm; press(2'd2);
        expect_fire("T6 1xU, fwda[1] EOC -> 30+30", 32'd15000, 1'b1, LBN0);

        // ---- T7: fine cascade, first valid fine rung then STOP -------------
        setup_dsi(LBN0);
        put_fwda(3, EOC); put_fwda(4, EOC);           // fwda[5] = 100+5 = 105
        arm; press(2'd0);
        expect_fire("T7 1xR -> fine fwda[5]", 32'd105, 1'b1, LBN0);

        // ---- T8: forward structural fallback -------------------------------
        setup_dsi(LBN0);
        for (i = 0; i <= 15; i = i + 1) put_fwda(i, EOC);
        arm; press(2'd0);
        expect_fire("T8a all fwd EOC -> next_vobu", 32'd430, 1'b1, LBN0);
        put32(32'h13A, EOC);                          // next_vobu gone too
        arm; press(2'd0);
        expect_fire("T8b -> vobu_ea+1", 32'd421, 1'b1, LBN0);

        // ---- T9: backward dead-end = no fire, not a guess ------------------
        setup_dsi(LBN0);
        for (i = 3; i <= 18; i = i + 1) put_bwda(i, EOC);   // addrs 22..37
        put32(32'h13E, EOC);                               // prev_vobu gone
        arm; press(2'd1);
        expect_none("T9 backward dead-end", 1);

        // ---- T10: THE STALE-TABLE TRAP ------------------------------------
        // A flush clears nav_dsi's scalars but NOT dsi_tbl. A press in that
        // window must not resolve 0 +/- stale_offset (-> title start).
        setup_dsi(LBN0); arm;
        nav_flush = 1'b1; nav_rst_n = 1'b0; tick(2);
        nav_flush = 1'b0; nav_rst_n = 1'b1;
        fires = 0; fails = 0;
        press(2'd0);
        tick(COAL + FRTO + 400);
        if (fires != 0) begin
            $display("FAIL T10a: fired on a STALE table (off=%0d base=%0d)", f_off, f_base);
            errors = errors + 1;
        end else if (fails == 0) begin
            $display("FAIL T10a: no pend_fail after FRESH_TO"); errors = errors + 1;
        end else
            $display("PASS T10a: stale table blocked, timed out cleanly");

        // ...and once a fresh packet lands it resolves against the NEW base.
        setup_dsi(32'd900_000);
        nav_flush = 1'b1; nav_rst_n = 1'b0; tick(2);
        nav_flush = 1'b0; nav_rst_n = 1'b1;
        fires = 0; fails = 0;
        press(2'd0);
        tick(COAL + 20);
        feed_dsi();
        expect_fire("T10b resolves on the NEW base", 32'd2500, 1'b1, 32'd900_000);

        // ---- T11: mid-resolve disturbance restarts, doesn't corrupt --------
        setup_dsi(32'd700_000); arm;
        press(2'd0);
        tick(COAL + 2);                      // window just closed; resolve starting
        nav_flush = 1'b1; nav_rst_n = 1'b0; tick(4);
        nav_flush = 1'b0; nav_rst_n = 1'b1;
        feed_dsi();
        expect_fire("T11 restart after mid-resolve flush", 32'd2500, 1'b1, 32'd700_000);

        // ---- T12: L+R cancel out -> nothing ------------------------------
        setup_dsi(LBN0); arm; press(2'd0); press(2'd1);
        expect_none("T12 R+L net zero", 0);

        // ---- T13: window re-arm across three spaced presses ---------------
        arm;
        press(2'd0); tick(COAL/2);
        press(2'd0); tick(COAL/2);
        press(2'd0);
        expect_fire("T13 re-armed window = one 30 s jump", 32'd7500, 1'b1, LBN0);

        // ---- T14: linear mode uses the CD constant, never the table -------
        arm; dvd_mode = 1'b0; lin_mode = 1'b1;
        press(2'd0);
        expect_fire("T14a linear 1xR = 861 blocks", 32'd861, 1'b1, 32'd100_000);
        fires = 0; press(2'd2);
        expect_fire("T14b linear 1xU = 6x861", 32'd5166, 1'b1, 32'd100_000);
        dvd_mode = 1'b1; lin_mode = 1'b0;

        // ---- T17: linear mode takes the step from the PORT ----------------
        // A flat .mpg/.VOB has no CD geometry and no DSI, so its step is a rate
        // measured off the stream (dvd/lin_rate.sv). Same lin_mode path as the
        // raw-CD case above -- only the number differs, which is the whole
        // point: T14 keeps 861 and this keeps the DUT honest about using the
        // port rather than a constant.
        arm; dvd_mode = 1'b0; lin_mode = 1'b1; lin_blk10 = 24'd3000;
        press(2'd0);
        expect_fire("T17a flat 1xR = 3000 blocks", 32'd3000, 1'b1, 32'd100_000);
        fires = 0; press(2'd2);
        expect_fire("T17b flat 1xU = 6x3000", 32'd18_000, 1'b1, 32'd100_000);

        // ---- T18: no rate known -> refuse, never guess ---------------------
        // emu gates lin_mode on the rate being valid, so this should not arise;
        // it is the belt-and-braces that a 0 step can never fire a jump to the
        // base itself (which scrub_ctrl would clamp into a seek to nowhere).
        arm; lin_blk10 = 24'd0;
        press(2'd0);
        expect_none("T18 no rate = pend_fail", 1);
        lin_blk10 = 24'd861; dvd_mode = 1'b1; lin_mode = 1'b0;

        // ---- T15: inert when disabled / out of title / cancelled ----------
        arm; en = 1'b0; press(2'd0);
        expect_none("T15a en=0", 0);
        en = 1'b1; in_title = 1'b0; press(2'd0);
        expect_none("T15b !in_title", 0);
        in_title = 1'b1;
        arm; press(2'd0); tick(COAL/2); cancel = 1'b1; tick(4); cancel = 1'b0;
        expect_none("T15c cancel mid-window", 0);

        // ---- T16: taps keep accumulating well past the old 240 s ceiling --
        // 5xUp = 300 s = 12 + 12 + 6 units -> fwda[0] x2 + fwda[1].
        arm;
        press(2'd2); press(2'd2); press(2'd2); press(2'd2); press(2'd2);
        tick(120);      // let the MM:SS subtract loop settle
        if (pend_min !== 7'd5 || pend_sec !== 3'd0) begin
            $display("FAIL T16a readout %0d:%0d0 want 5:00", pend_min, pend_sec);
            errors = errors + 1; end
        expect_fire("T16a 5xU = 300 s (past the old cap)", 32'd75000, 1'b1, LBN0);

        // ---- T16b: a long tap burst keeps going -- 20xUp = 20 min ---------
        arm;
        for (i = 0; i < 20; i = i + 1) press(2'd2);
        tick(120);      // let the MM:SS subtract loop settle
        if (pend_min !== 7'd20 || pend_sec !== 3'd0) begin
            $display("FAIL T16b readout %0d:%0d0 want 20:00", pend_min, pend_sec);
            errors = errors + 1; end
        // 120 units = 10 x the 120 s rung
        expect_fire("T16b 20xU = 20 min, 10 rungs", 32'd300000, 1'b1, LBN0);

        // ---- T16c: mixed taps give an exact MM:SS readout -----------------
        arm;
        press(2'd2); press(2'd2);                         // +2:00
        press(2'd0); press(2'd0); press(2'd0);             // +0:30
        tick(120);      // let the MM:SS subtract loop settle
        if (pend_min !== 7'd2 || pend_sec !== 3'd3) begin
            $display("FAIL T16c readout %0d:%0d0 want 2:30", pend_min, pend_sec);
            errors = errors + 1; end
        // 15 units = 12 + 3 -> fwda[0] + fwda[2]
        expect_fire("T16c 2:30 = fwda[0] + fwda[2]", 32'd37500, 1'b1, LBN0);

        // ---- T16d: the readout saturates at the widest MM:SS (99:50) ------
        arm;
        for (i = 0; i < 110; i = i + 1) press(2'd2);       // 110 min of taps
        tick(120);      // let the MM:SS subtract loop settle
        if (pend_min !== 7'd99 || pend_sec !== 3'd5) begin
            $display("FAIL T16d readout %0d:%0d0 want 99:50", pend_min, pend_sec);
            errors = errors + 1; end
        tick(COAL + 3000);

        // ---- T19: the TAP-REPEATING REMOTE burst (issue #35 keyboard path) --
        // dvd/emu.sv now ORs the keyboard/remote Fast Fwd + Rewind keys onto
        // rt_edge/lf_edge instead of scrub_ctrl's held levels, precisely because
        // an IR receiver does not send a hold: Retro Remake's SuperDock firmware
        // (DockIR src/main.c) emits key-down -> 80 ms -> key-up PER NEC REPEAT
        // FRAME, ~110 ms apart, so a long press is ~9 discrete taps a second.
        // Against scrub_ctrl that is ~9 complete seek gestures a second (its
        // accumulate tick is 60 ms, so each 80 ms tap leaves pending_off != 0 and
        // every release issues a real seek) -- the rapid flush/re-lock regime the
        // headers of scrub_ctrl.sv and dpad_seek.sv record as fatal. Here the
        // identical burst must produce EXACTLY ONE jump.
        // Spacing is scaled like the window: ~110/400 of COALESCE.
        arm;
        for (i = 0; i < 9; i = i + 1) begin press(2'd0); tick(COAL/4); end
        tick(120);      // let the MM:SS subtract loop settle
        if (pend_min !== 7'd1 || pend_sec !== 3'd3) begin
            $display("FAIL T19a readout %0d:%0d0 want 1:30", pend_min, pend_sec);
            errors = errors + 1; end
        // 9 units = 6 + 3 -> fwda[1] + fwda[2] = 15000 + 7500
        expect_fire("T19a 9-tap IR burst = ONE seek", 32'd22500, 1'b1, LBN0);

        // ---- T19b: ...and the window really does close ---------------------
        // The bound on T17a: taps spaced WIDER than the window are separate
        // gestures, so coalescing cannot silently swallow a deliberate second
        // press. Two isolated taps = two seeks.
        arm;
        press(2'd0); tick(COAL + 400);
        press(2'd0); tick(COAL + 400);
        if (fires !== 2) begin
            $display("FAIL T19b: expected 2 fires from 2 spaced taps, got %0d", fires);
            errors = errors + 1;
        end else if (f_off !== 32'd2500) begin
            $display("FAIL T19b: last off=%0d want 2500 (one 10 s rung)", f_off);
            errors = errors + 1;
        end else
            $display("PASS T19b: spaced taps stay separate (2 fires, off=%0d)", f_off);

        if (errors == 0) $display("DPAD_SEEK_TB: ALL TESTS PASSED");
        else begin $display("DPAD_SEEK_TB: %0d FAILURE(S)", errors); $fatal(1); end
        $finish;
    end

    initial begin #40_000_000; $display("DPAD_SEEK_TB: TIMEOUT"); $fatal(1); end

endmodule

`default_nettype wire
