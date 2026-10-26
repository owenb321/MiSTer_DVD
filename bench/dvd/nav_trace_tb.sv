// nav_trace_tb.sv -- the nav event FIFO (dvd/nav_trace.sv) against its header contract.
//
// Arms (each prints PASS [arm] or FAIL [arm] ...; run_nav_trace.sh --red requires
// every mutation to fail exactly its own arm):
//   [codes]  every source, fired alone, gives its own code and payload
//   [order]  events on separate cycles come out in the order they happened; events in
//            ONE cycle come out in the documented priority order
//   [simul]  all 16 sources in one cycle: 16 entries, none lost; a GPRM write on
//            every cycle (the mount clear) loses none and merges none
//   [merge]  a source firing again while still pending is counted, not silent
//   [ovf]    300 events into 256 slots: the first 256 kept in order, ovf = 44 exactly,
//            and the FIFO accepts again once drained
//   [ts]     the stc and free-tick stamps are the values at the write cycle, exactly
//   [proto]  header words, the 64-entry cap, an aborted drain loses nothing, a full
//            drain at the minimum strobe spacing (M10K read-ahead), zeros past the end
//   [absent] no other command (0x7A, 0x7B, 0x017C, ...) ever takes the bus or pops
//
// Every input is driven from t=0 (no Z), and every comparison is !== so an X fails.
`timescale 1ns/1ps
module nav_trace_tb;

    reg         clk = 1'b0;
    always #5 clk = ~clk;
    reg         rst_n = 1'b0;
    reg         io_enable = 1'b0, io_strobe = 1'b0;
    reg  [15:0] io_din = 16'd0;
    wire        drive;
    wire [15:0] dout;
    reg         tick = 1'b0;
    reg  [32:0] stc = 33'd0;
    reg         gprm_we = 1'b0;
    reg   [3:0] gprm_a = 4'd0;
    reg  [15:0] gprm_d = 16'd0;
    reg  [24:0] joy_rise = 25'd0, kbd_joy = 25'd0;
    reg  [10:0] ps2_key = 11'd0;
    reg         btn_act = 1'b0;
    reg   [5:0] btn_sel = 6'd0, btn_ns = 6'd0;
    reg         cell_cmd = 1'b0;
    reg   [7:0] cell_cmdnr = 8'd0;
    reg         hli_arm = 1'b0;
    reg  [31:0] h_sptm = 32'd0;
    reg         btns_armed = 1'b0;
    reg   [7:0] cur_cell = 8'd0, cur_vts = 8'd0;
    reg  [15:0] cur_pgcn = 16'd0;
    reg         menu_active = 1'b0;
    reg   [5:0] flush = 6'd0;
    reg         aud_low = 1'b0;
    reg  [15:0] aud_frames = 16'd0;
    reg         pause = 1'b0, still = 1'b0, video_live = 1'b0;
    reg   [2:0] x_ev = 3'd0;
    reg  [77:0] x_pl = 78'd0;

    nav_trace dut (
        .clk(clk), .rst_n(rst_n),
        .io_enable(io_enable), .io_strobe(io_strobe), .io_din(io_din),
        .drive(drive), .dout(dout),
        .tick(tick), .stc(stc),
        .gprm_we(gprm_we), .gprm_a(gprm_a), .gprm_d(gprm_d),
        .joy_rise(joy_rise), .kbd_joy(kbd_joy), .ps2_key(ps2_key),
        .btn_act(btn_act), .btn_sel(btn_sel), .btn_ns(btn_ns),
        .cell_cmd(cell_cmd), .cell_cmdnr(cell_cmdnr),
        .hli_arm(hli_arm), .h_sptm(h_sptm), .btns_armed(btns_armed),
        .cur_cell(cur_cell), .cur_vts(cur_vts), .cur_pgcn(cur_pgcn), .menu_active(menu_active),
        .flush(flush), .aud_low(aud_low), .aud_frames(aud_frames),
        .pause(pause), .still(still), .video_live(video_live),
        .x_ev(x_ev), .x_pl(x_pl));

    localparam [15:0] CMD = 16'h007C, MAGIC = 16'h5E01;
    localparam [4:0] C_GPRM = 1, C_STC = 2, C_JOY = 3, C_PS2 = 4, C_BTN = 5, C_CCMD = 6,
                     C_HLI = 7, C_ARMED = 8, C_CELL = 9, C_PGC = 10, C_FLSH = 11,
                     C_AUDL = 12, C_STAT = 13, C_X0 = 14, C_X1 = 15, C_X2 = 16;

    // ---- clock model: what the DUT's stamps must equal, per posedge index ----
    integer cyc = 0;                       // at a negedge: index of the NEXT posedge
    reg [32:0] stc_hist  [0:65535];
    reg [32:0] free_hist [0:65535];
    reg [32:0] free_m = 33'd0;
    reg        stc_auto = 1'b0, tick_auto = 1'b0;
    always @(posedge clk) begin
        stc_hist[cyc[15:0]]  <= stc;
        free_hist[cyc[15:0]] <= free_m;
        if (!rst_n) free_m <= 33'd0; else if (tick) free_m <= free_m + 33'd1;
        cyc <= cyc + 1;
    end
    always @(negedge clk) begin
        if (stc_auto) stc <= stc + 33'd1;
        tick <= tick_auto;
    end

    reg drive_seen = 1'b0;
    always @(posedge clk) if (drive === 1'b1) drive_seen <= 1'b1;

    // ---- verdicts ----
    integer arm_fail, any_fail = 0;
    reg [8*8-1:0] arm_name;
    task begin_arm(input [8*8-1:0] n); begin arm_name = n; arm_fail = 0; end endtask
    task check(input cond, input [8*64-1:0] what); begin
        if (cond !== 1'b1) begin
            if (arm_fail < 6) $display("FAIL [%0s] %0s", arm_name, what);
            arm_fail = arm_fail + 1;
        end
    end endtask
    task end_arm; begin
        if (arm_fail == 0) $display("PASS [%0s]", arm_name);
        else begin $display("FAIL [%0s] (%0d checks)", arm_name, arm_fail); any_fail = 1; end
    end endtask

    // ---- stimulus helpers: inputs change on the negedge ----
    task nclk(input integer n); repeat (n) @(negedge clk); endtask

    task reset; begin
        @(negedge clk);
        rst_n = 1'b0; stc_auto = 1'b0; tick_auto = 1'b0; stc = 33'd0;
        gprm_we = 0; joy_rise = 0; kbd_joy = 0; ps2_key = 0; btn_act = 0; btn_sel = 0;
        btn_ns = 0; cell_cmd = 0; cell_cmdnr = 0; hli_arm = 0; h_sptm = 0; btns_armed = 0;
        cur_cell = 0; cur_vts = 0; cur_pgcn = 0; menu_active = 0; flush = 0; aud_low = 0;
        aud_frames = 0; pause = 0; still = 0; video_live = 0; x_ev = 0; x_pl = 0;
        io_enable = 0; io_strobe = 0; io_din = 0;
        nclk(3); rst_n = 1'b1; nclk(3);
    end endtask

    // one-cycle pulses; return the event's posedge index
    task fire_gprm(input [3:0] a, input [15:0] d, output integer e); begin
        gprm_we = 1; gprm_a = a; gprm_d = d; e = cyc; @(negedge clk); gprm_we = 0;
    end endtask
    task fire_x(input integer k, input [25:0] pl, output integer e); begin
        x_ev[k] = 1'b1; x_pl[k*26 +: 26] = pl; e = cyc; @(negedge clk); x_ev[k] = 1'b0;
    end endtask

    // ---- drained entries ----
    integer ne;
    reg  [4:0]  e_code [0:1023];
    reg  [25:0] e_pl   [0:1023];
    reg  [32:0] e_stc  [0:1023];
    reg  [15:0] e_fts  [0:1023];
    reg  [15:0] w      [0:511];
    integer     nw, hdr_edge;

    // One transaction: command, then strobes `sp` cycles apart. stop >= 0 aborts after
    // that many words. Entries (when the magic is right) are appended to e_*.
    task drain(input [15:0] cmd, input integer sp, input integer stop); integer k, n, tot; begin
        @(negedge clk); io_enable = 1; drive_seen = 0; nclk(2);
        io_din = cmd; io_strobe = 1; hdr_edge = cyc; @(negedge clk); io_strobe = 0; io_din = 0;
        w[0] = dout; nw = 1;
        tot = 12;
        for (k = 1; k < tot && (stop < 0 || k < stop); k = k + 1) begin
            nclk(sp - 1);
            io_strobe = 1; @(negedge clk); io_strobe = 0;
            w[k] = dout; nw = k + 1;
            if (k == 1 && w[0] === MAGIC) tot = 10 + 5 * w[1] + 2;
        end
        nclk(2); io_enable = 0; nclk(3);
        if (w[0] === MAGIC && (stop < 0)) begin
            n = w[1];
            for (k = 0; k < n; k = k + 1) begin
                e_code[ne] = w[10 + 5*k][15:11];
                e_pl[ne]   = {w[10 + 5*k][10:0], w[11 + 5*k][15:1]};
                e_stc[ne]  = {w[11 + 5*k][0], w[12 + 5*k], w[13 + 5*k]};
                e_fts[ne]  = w[14 + 5*k];
                ne = ne + 1;
            end
        end
    end endtask
    task drain_all(input integer sp); integer guard; begin
        guard = 0;
        drain(CMD, sp, -1);
        while (w[0] === MAGIC && w[1] !== 16'd0 && guard < 20) begin
            drain(CMD, sp, -1); guard = guard + 1;
        end
    end endtask

    // expect entry i
    task want(input integer i, input [4:0] c, input [25:0] pl, input [8*40-1:0] what); begin
        check(i < ne, what);
        if (i < ne) begin
            if (e_code[i] !== c || e_pl[i] !== pl) begin
                check(1'b0, what);
                if (arm_fail <= 6) $display("      entry %0d: code %0d pl %h, want code %0d pl %h",
                                            i, e_code[i], e_pl[i], c, pl);
            end
        end
    end endtask

    integer i, j, e, e2, base, cnt, seed;
    integer exp_code [0:63];
    reg [25:0] exp_pl [0:63];
    reg [15:0] seen;

    initial begin
        // ================================================================ [codes]
        reset; begin_arm("codes"); ne = 0;
        stc = 33'h1_0000_0100; nclk(2); drain_all(4); ne = 0;          // baseline jump: discard
        fire_gprm(4'd0, 16'hBEEF, e);                                   nclk(4);
        // STC: 40 cycles of +1 must log nothing, then one jump logs one delta
        stc_auto = 1; nclk(40); stc_auto = 0; nclk(2);
        stc = stc - 33'd1000; nclk(4);
        joy_rise = 25'h0000081; @(negedge clk); joy_rise = 0;          nclk(4);   // pad: B4 + up
        joy_rise = 25'h0000100; kbd_joy = 25'h0000100; @(negedge clk);
        joy_rise = 0; kbd_joy = 0;                                      nclk(4);   // keyboard Menu
        ps2_key = {1'b1, 1'b1, 1'b0, 8'h5A};                            nclk(4);   // Enter make
        btn_sel = 6'd3; btn_ns = 6'd5; btn_act = 1; @(negedge clk); btn_act = 0; nclk(4);
        cur_cell = 8'd7;                                                nclk(4);   // -> CELL
        cell_cmdnr = 8'd2; cell_cmd = 1; @(negedge clk); cell_cmd = 0;  nclk(4);
        h_sptm = 32'h1234_5678; btn_ns = 6'd9; hli_arm = 1; @(negedge clk); hli_arm = 0; nclk(4);
        btns_armed = 1;                                                 nclk(4);
        cur_pgcn = 16'h8123;                                            nclk(4);   // -> PGC
        flush = 6'b001001;                                              nclk(4);   // load + seek rise
        flush = 6'b000000;                                              nclk(4);   // falls: nothing
        aud_frames = 16'd5; aud_low = 1;                                nclk(4);
        pause = 1;                                                      nclk(4);
        fire_x(0, 26'h3AAAAAA, e); nclk(3); fire_x(1, 26'h1555555, e); nclk(3);
        fire_x(2, 26'h2000001, e); nclk(3);
        drain_all(4);
        check(ne == 17, "17 entries");
        want(0,  C_GPRM,  {6'd0, 4'd0, 16'hBEEF},              "GPRM g0 = BEEF");
        want(1,  C_STC,   26'h3FFFC18,                        "STC_JUMP delta -1000");
        want(2,  C_JOY,   {1'b0, 25'h0000081},                "JOY pad");
        want(3,  C_JOY,   {1'b1, 25'h0000100},                "JOY keyboard flag");
        want(4,  C_PS2,   {16'd0, 1'b1, 1'b0, 8'h5A},         "PS2 Enter make");
        want(5,  C_BTN,   {14'd0, 6'd5, 6'd3},                "BTN_ACT 3 of 5");
        want(6,  C_CELL,  {9'd0, 1'b0, 8'd0, 8'd7},           "CELL 7");
        want(7,  C_CCMD,  {10'd0, 8'd7, 8'd2},                "CELL_CMD 2 in cell 7");
        want(8,  C_HLI,   {6'd9, 20'h45678},                  "HLI_ARM sptm low 20");
        want(9,  C_ARMED, {19'd0, 1'b1, 6'd9},                "ARMED rise");
        want(10, C_PGC,   {1'b0, 1'b0, 8'd0, 16'h8123},       "PGC 0x8123");
        want(11, C_FLSH,  {20'd0, 6'b001001},                 "FLUSH load+seek");
        want(12, C_AUDL,  {9'd0, 1'b1, 16'd5},                "AUD_LOW");
        want(13, C_STAT,  {18'd0, 4'b0001, 4'b0001},          "STATE pause");
        want(14, C_X0,    26'h3AAAAAA,                        "X0");
        want(15, C_X1,    26'h1555555,                        "X1");
        want(16, C_X2,    26'h2000001,                        "X2");
        end_arm;

        // ================================================================ [order]
        reset; begin_arm("order"); ne = 0; seed = 7; cnt = 0;
        for (i = 0; i < 40; i = i + 1) begin
            j = $unsigned($random(seed)) % 3;
            if (j == 0) begin exp_code[i] = C_GPRM; exp_pl[i] = {6'd0, i[3:0], 16'hA000 + i[15:0]};
                              fire_gprm(i[3:0], 16'hA000 + i[15:0], e); end
            else if (j == 1) begin exp_code[i] = C_X0; exp_pl[i] = 26'h100 + i;
                              fire_x(0, 26'h100 + i, e); end
            else begin exp_code[i] = C_X2; exp_pl[i] = 26'h200 + i; fire_x(2, 26'h200 + i, e); end
            nclk($unsigned($random(seed)) % 3 + 1);           // gaps of 2..4 cycles
        end
        drain_all(4);
        check(ne == 40, "40 entries");
        for (i = 0; i < 40; i = i + 1) want(i, exp_code[i], exp_pl[i], "separate-cycle order");
        // one cycle, three sources: priority order GPRM, JOY, X2
        ne = 0;
        gprm_we = 1; gprm_a = 4'd1; gprm_d = 16'h0011; joy_rise = 25'h10; x_ev[2] = 1; x_pl[77:52] = 26'h77;
        @(negedge clk); gprm_we = 0; joy_rise = 0; x_ev = 0; nclk(6);
        drain_all(4);
        check(ne == 3, "3 same-cycle entries");
        want(0, C_GPRM, {6'd0, 4'd1, 16'h0011}, "same cycle: GPRM first");
        want(1, C_JOY,  {1'b0, 25'h10},         "same cycle: JOY second");
        want(2, C_X2,   26'h77,                 "same cycle: X2 last");
        end_arm;

        // ================================================================ [simul]
        reset; begin_arm("simul"); ne = 0;
        gprm_we = 1; gprm_a = 4'd2; gprm_d = 16'h2222; stc = 33'd5000;
        joy_rise = 25'h1; ps2_key = 11'h400; btn_act = 1; cell_cmd = 1; hli_arm = 1;
        btns_armed = 1; cur_cell = 8'd1; cur_pgcn = 16'd1; flush = 6'h1; aud_low = 1;
        pause = 1; x_ev = 3'b111;
        @(negedge clk);
        gprm_we = 0; joy_rise = 0; btn_act = 0; cell_cmd = 0; hli_arm = 0; x_ev = 0;
        nclk(30);
        drain_all(4);
        check(ne == 16, "16 entries from one cycle");
        seen = 16'd0;
        for (i = 0; i < ne; i = i + 1) if (e_code[i] >= 1 && e_code[i] <= 16) seen[e_code[i] - 1] = 1'b1;
        check(seen === 16'hFFFF, "every code present once");
        check(w[4] === 16'd0, "no merges");
        // the mount clear: a GPRM write on every cycle, nothing else
        ne = 0;
        for (i = 0; i < 16; i = i + 1) begin
            gprm_we = 1; gprm_a = i[3:0]; gprm_d = 16'h5000 + i[15:0]; @(negedge clk);
        end
        gprm_we = 0; nclk(6);
        drain_all(4);
        check(ne == 16, "16 back-to-back GPRM writes");
        for (i = 0; i < 16; i = i + 1) want(i, C_GPRM, {6'd0, i[3:0], 16'h5000 + i[15:0]}, "burst value");
        check(w[4] === 16'd0, "burst: no merges");
        end_arm;

        // ================================================================ [merge]
        reset; begin_arm("merge"); ne = 0;
        gprm_we = 1; joy_rise = 25'h1; ps2_key = 11'h400; btn_act = 1; cell_cmd = 1; hli_arm = 1;
        btns_armed = 1; cur_cell = 8'd1; cur_pgcn = 16'd1; flush = 6'h1; aud_low = 1;
        pause = 1; x_ev = 3'b111; stc = 33'd77;
        @(negedge clk);
        gprm_we = 0; joy_rise = 0; btn_act = 0; cell_cmd = 0; hli_arm = 0; x_ev = 0;
        @(negedge clk);
        btn_act = 1; @(negedge clk); btn_act = 0;            // BTN again, still pending
        nclk(30);
        drain_all(4);
        check(ne == 16, "16 entries (the second BTN merged)");
        check(w[4] === 16'd1, "merges = 1");
        end_arm;

        // ================================================================ [ovf]
        reset; begin_arm("ovf"); ne = 0;
        for (i = 0; i < 300; i = i + 1) begin fire_gprm(i[3:0], i[15:0], e); @(negedge clk); end
        nclk(4);
        drain_all(4);
        check(ne == 256, "256 kept");
        for (i = 0; i < 256; i = i + 1) want(i, C_GPRM, {6'd0, i[3:0], i[15:0]}, "the first 256, in order");
        check(w[3] === 16'd44, "ovf = 44");
        ne = 0; fire_gprm(4'd9, 16'h0999, e); nclk(4); drain_all(4);
        check(ne == 1, "accepts again after the drain");
        want(0, C_GPRM, {6'd0, 4'd9, 16'h0999}, "the post-drain event");
        check(w[3] === 16'd44, "ovf holds at 44");
        end_arm;

        // ================================================================ [ts]
        reset; begin_arm("ts"); ne = 0;
        stc = 33'h1_FFFF_F000; nclk(2); drain_all(4); ne = 0;          // baseline jump: discard
        stc_auto = 1; tick_auto = 1;                                    // stc wraps 33 bits below
        nclk(5000);
        fire_x(0, 26'd1, e); nclk(37);
        fire_gprm(4'd3, 16'd3, e2); nclk(1234);
        // a same-cycle pair: the lower-priority one is written a cycle later
        gprm_we = 1; gprm_a = 4'd4; gprm_d = 16'd4; x_ev[1] = 1; base = cyc;
        @(negedge clk); gprm_we = 0; x_ev = 0;
        nclk(4000);
        stc_auto = 0;
        drain_all(4);
        check(ne == 4, "4 entries");
        // (which of the same-cycle pair goes first is [order]'s business, not this arm's)
        check(e_code[0] === C_X0 && e_code[1] === C_GPRM &&
              ((e_code[2] === C_GPRM && e_code[3] === C_X1) || (e_code[2] === C_X1 && e_code[3] === C_GPRM)),
              "codes X0, GPRM, then the pair");
        exp_code[0] = e + 1; exp_code[1] = e2 + 1; exp_code[2] = base + 1; exp_code[3] = base + 2;
        for (i = 0; i < 4 && i < ne; i = i + 1) begin
            j = exp_code[i] & 16'hFFFF;
            if (e_stc[i] !== stc_hist[j]) begin
                check(1'b0, "stc stamp = the STC at the write cycle");
                $display("      entry %0d stc %h, want %h", i, e_stc[i], stc_hist[j]);
            end
            if (e_fts[i] !== free_hist[j][20:5]) begin
                check(1'b0, "fts stamp = free tick [20:5] at the write cycle");
                $display("      entry %0d fts %h, want %h", i, e_fts[i], free_hist[j][20:5]);
            end
        end
        check(e_stc[3] < 33'h1000, "the 33-bit STC wrapped through 0 without a jump event");
        end_arm;

        // ================================================================ [proto]
        reset; begin_arm("proto"); ne = 0;
        stc = 33'h1_2345_6789; nclk(2); drain_all(4); ne = 0;          // baseline jump: discard
        tick_auto = 1; nclk(3000);
        for (i = 0; i < 100; i = i + 1) begin fire_x(0, i, e); @(negedge clk); end
        drain(CMD, 4, -1);
        check(w[0] === MAGIC,  "word 0 = MAGIC");
        check(w[0][15] === 1'b0 && w[0] !== 16'd0, "MAGIC: bit 15 clear, non-zero");
        check(w[1] === 16'd64, "word 1: N capped at 64");
        check(w[2] === 16'd100, "word 2: fill = 100");
        check(w[3] === 16'd0 && w[4] === 16'd0, "words 3, 4: ovf, merges = 0");
        check({w[5], w[6]} === free_hist[hdr_edge & 16'hFFFF][31:0], "words 5-6: free_now at the command");
        check({w[7][0], w[8], w[9]} === stc_hist[hdr_edge & 16'hFFFF], "words 7-9: stc_now at the command");
        check(w[7][15:1] === 15'd0, "word 7 upper bits 0");
        check(w[330] === 16'd0 && w[331] === 16'd0, "zeros past the last entry");
        drain(CMD, 4, -1);
        check(w[1] === 16'd36 && w[2] === 16'd36, "second drain: the other 36");
        drain(CMD, 4, -1);
        check(w[0] === MAGIC && w[1] === 16'd0 && w[2] === 16'd0, "third drain: empty");
        check(w[10] === 16'd0 && w[11] === 16'd0, "empty drain: zeros after the header");
        check(ne == 100, "100 entries over two drains");
        for (i = 0; i < 100; i = i + 1) want(i, C_X0, i, "payloads in order across drains");
        // a transaction cut after two words of the first entry loses nothing
        ne = 0;
        for (i = 0; i < 3; i = i + 1) begin fire_x(1, 26'h300 + i, e); @(negedge clk); end
        drain(CMD, 4, 12);
        drain_all(4);
        check(ne == 3, "aborted drain: all 3 still there");
        for (i = 0; i < 3; i = i + 1) want(i, C_X1, 26'h300 + i, "aborted drain: intact");
        // the minimum strobe spacing: the M10K's read latency is hidden by read-ahead.
        // Payloads differ in their TOP bits: the word a late RAM would serve stale is
        // the first one after a pop, {code, payload[25:15]}.
        ne = 0;
        for (i = 0; i < 5; i = i + 1) begin fire_x(2, (i << 21) | (26'h15A5A + i), e); @(negedge clk); end
        drain_all(2);
        check(ne == 5, "spacing 2: 5 entries");
        for (i = 0; i < 5; i = i + 1) want(i, C_X2, (i << 21) | (26'h15A5A + i), "spacing 2: each entry its own");
        end_arm;

        // ================================================================ [absent]
        reset; begin_arm("absent"); ne = 0;
        fire_x(0, 26'h11, e); nclk(2); fire_x(0, 26'h12, e); nclk(4);
        exp_code[0] = 16'h007A; exp_code[1] = 16'h007B; exp_code[2] = 16'h017C;
        exp_code[3] = 16'h007D; exp_code[4] = 16'h0000; exp_code[5] = 16'h7C00; exp_code[6] = 16'hFF7C;
        for (i = 0; i < 7; i = i + 1) begin
            drain(exp_code[i], 4, -1);
            check(drive_seen === 1'b0, "another command never takes the bus");
            check(w[0] !== MAGIC, "another command never answers MAGIC");
        end
        drain_all(4);
        check(ne == 2, "nothing popped by other commands");
        want(0, C_X0, 26'h11, "first kept");
        want(1, C_X0, 26'h12, "second kept");
        check(drive_seen === 1'b1, "0x7C does take the bus");
        end_arm;

        $display("RESULT: %s", any_fail ? "FAIL" : "PASS");
        if (any_fail) $fatal(1, "nav_trace_tb: FAIL");
        $finish;
    end
endmodule
