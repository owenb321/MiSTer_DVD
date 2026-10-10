// iso_reader_stilloff_tb.sv - user STILL OFF (UOP18, audit item 5).
//
// A still_off pulse while the reader is parked in S_STILL runs the action the
// still's timer would have run at expiry (still_next): the next cell, the cell
// command, or the PGC end. It is ignored on a hold with no continuation of its
// own (still_act = 0). emu's button gate (no HLI armed or pending) is NOT here:
// it is gated by tools/check_still_off_wiring.py. See docs/dvd_nav.md "Still off".
//
// Fixture (2048-byte sectors, every cell ONE sector):
//   VTS_01 title PGCIT (entry_ids 0):
//     PGC1  cells A0 (still 0xFF) A1 (still 0)
//     PGC2  cell  A2 (still 0xFF)                      last cell
//     PGC3  cell  A3 (still 200 s, cell_cmd 1)          timed, command
//     PGC4  cells A4 (still 3 s) A5                    timed, no command
//     PGC5  cell  A6 (still 5 s, cell_cmd 1)            timed, left by a jump
//     PGC6  cell  A7 (still 0xFF, cell_cmd 1 = LinkPGN 1)   indefinite + a command
//                 (Tomb Raider's in-title menus: a looping command)
//     PGC7  cells A8 (still 0xFF, cell_cmd 1, NO command table) A9
//                 (a cmd_nr past the PGC's cell commands: malformed)
//   PGC6/PGC7 sit in the PGCIT's second sector (it spans 21-22).
//   VTS_01 VTSM PGCI_UT (one LU):
//     PGC1  cell  D0 (still 0), next_pgcn 0            -> POST falls through -> dead-end hold
//     PGC2  cell  D1 (still 0xFF)                      a menu indefinite still
//
// Arms (bench/dvd/run_still_off.sh --red names the mutation for each):
//   A  PGC1: park on A0 (indefinite), press -> A1 streams, no seek/jump
//   B  PGC2: park on A2 (indefinite, last), press -> vm_pgc_end (POST's turn)
//   C  PGC3: park on A3 (200 s timed + cmd), press -> vm_cell_cmd at once
//   D  PGC4: park on A4 (3 s timed), NO press -> the timer still advances to A5
//   E  PGC5: park on A6 (5 s timed + cmd), jump to VTSM PGC1, reach the dead-end
//      hold, wait past A6's 5 s: the stale timer must NOT fire (no vm_cell_cmd)
//   F  ...then press on that dead-end hold -> nothing (still parked, no event)
//   G  Disc Menus off (vm_mode=0): VTSM PGC2's indefinite still + press -> nothing
//   H  PGC1 again, press WHILE A0 is still streaming (not parked) -> nothing: A0
//      still parks normally afterwards
//   I  PGC6: park on A7 (indefinite + a command): the command waits out the still
//      (libdvdnav play_Cell_post), press -> vm_cell_cmd. docs/dvd_nav.md "An
//      indefinite still and its cell command"
//   J  PGC7: park on A8 (indefinite + a malformed cmd_nr), press -> A9 streams with
//      no vm_cell_cmd (libdvdnav "Invalid Cell command": the next cell)
`timescale 1ns/1ps

module iso_reader_stilloff_tb;

    localparam IMG_SECS  = 40;
    localparam IMG_BYTES = IMG_SECS*2048;
    localparam SEC       = 1000;              // SEC_DIV: one "second" = 1000 clk

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 0;

    wire [31:0] sd_lba;
    wire        sd_rd;
    reg         sd_ack = 0;
    reg  [13:0] sd_buff_addr = 0;
    reg  [7:0]  sd_buff_dout = 0;
    reg         sd_buff_wr = 0;

    wire [7:0]  stream_data;
    wire        stream_valid;
    reg         busy = 0;

    reg  [7:0]  img [0:IMG_BYTES-1];

    reg         jump_pulse = 0;
    reg  [1:0]  jump_domain = 0;
    reg  [7:0]  jump_vts = 0;
    reg  [15:0] jump_pgcn = 0;
    reg  [3:0]  jump_entry = 0;
    reg  [6:0]  jump_ttn = 0;
    reg  [7:0]  jump_pgn = 0;
    wire        jump_ack, pgc_loaded, pgc_error, menu_active, still_active;
    wire        seek_ack, nav_ready_w;
    wire        vm_cell_cmd, vm_pgc_end;

    reg         vm_mode = 1;
    reg         vm_adv = 0;
    reg         still_off = 0;

    dvd_iso_reader #(.SEC_DIV(SEC)) dut (
        .agl_vm(4'd0), .agl_vm_en(1'b0), .vm_pre_done(1'b0),
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(7'd0),
        .aud_drained(1'b1), .vbuf_empty(1'b1),
        .jump_ttn(jump_ttn), .jump_pgn(jump_pgn), .jump_ptt(10'd0),
        .still_off(still_off),
        .vm_mode(vm_mode), .vm_adv(vm_adv), .vm_replay(1'b0),
        .vm_cell_cmd(vm_cell_cmd), .vm_pgc_end(vm_pgc_end), .nav_ready_o(nav_ready_w),
        .auto_vts(), .cell_count_o(), .res_ttn(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(seek_ack),
        .seek_rbn_pulse(1'b0), .seek_rbn(32'd0), .seek_tm_req(1'b0), .seek_tm_secs(17'd0),
        .cur_cell(), .cell_ready(),
        .chap_pulse(1'b0), .chap_dir(1'b0), .chap_mag(5'd1),
        .chap_at_start(1'b1), .cur_pgm(), .nr_ptt_o(),
        .chap_edge(), .chap_edge_dir(),
        .jump_pulse(jump_pulse), .jump_natural(1'b0), .jump_domain(jump_domain), .jump_vts(jump_vts),
        .jump_pgcn(jump_pgcn), .jump_entry(jump_entry), .jump_cell(8'd0),
        .jump_ack(jump_ack), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .menu_active(menu_active), .still_active(still_active), .cur_vts(),
        .cur_pgcn_o(),
        .best_menu_vts(),
        .menu_btns_armed(1'b0),
        .cmd_we(), .cmd_waddr(), .cmd_wdata(),
        .cmd_nr_pre(), .cmd_nr_post(), .cmd_nr_cell(),
        .next_pgcn(), .prev_pgcn(), .goup_pgcn(),
        .cur_cell_cmdnr(),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .pal_we(), .pal_waddr(), .pal_wdata(),
        .debug_active(), .debug_iso_mode()
    );

    always #5 clk = ~clk;

    // ---- monitors ----------------------------------------------------------
    // last streamed byte, and counts of every event an arm may require or forbid
    reg  [7:0] last_byte = 8'h00;
    integer    n_bytes = 0, n_seek = 0, n_jump = 0, n_cmd = 0, n_pgend = 0;
    always @(posedge clk) begin
        if (stream_valid) begin last_byte <= stream_data; n_bytes = n_bytes + 1; end
        if (seek_ack    === 1'b1) n_seek  = n_seek + 1;
        if (jump_ack    === 1'b1) n_jump  = n_jump + 1;
        if (vm_cell_cmd === 1'b1) n_cmd   = n_cmd + 1;
        if (vm_pgc_end  === 1'b1) n_pgend = n_pgend + 1;
    end

    // mock HPS (3-cycle latency, 2048-byte blocks)
    integer m = 0, bc = 0, lat = 0;
    reg [31:0] rlba = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin sd_ack <= 1'b0; if (sd_rd) begin rlba <= sd_lba; lat <= 3; m <= 1; end end
        1: begin if (lat != 0) lat <= lat-1; else begin sd_ack <= 1'b1; bc <= 0; m <= 2; end end
        2: begin sd_ack <= 1'b1; sd_buff_wr <= 1'b1; sd_buff_addr <= bc[13:0];
                 sd_buff_dout <= img[rlba*2048 + bc]; bc <= bc+1; if (bc==2047) m <= 3; end
        3: begin sd_ack <= 1'b0; sd_buff_wr <= 1'b0; m <= 0; end
        endcase
    end

    // ---- image -------------------------------------------------------------
    integer i, cur, errors = 0;

    task put_rec(input integer off, input [31:0] ext, input [31:0] dlen,
                 input [7:0] flags, input [127:0] nm, input integer nlen,
                 output integer next_off);
        integer j; integer rl;
        begin
            rl = 33 + nlen; if (rl[0]) rl = rl + 1;
            img[off+0] = rl[7:0]; img[off+1] = 0;
            img[off+2] = ext[7:0]; img[off+3] = ext[15:8];
            img[off+4] = ext[23:16]; img[off+5] = ext[31:24];
            for (j = 6; j < 10; j = j + 1) img[off+j] = 0;
            img[off+10] = dlen[7:0]; img[off+11] = dlen[15:8];
            img[off+12] = dlen[23:16]; img[off+13] = dlen[31:24];
            for (j = 14; j < 25; j = j + 1) img[off+j] = 0;
            img[off+25] = flags; img[off+26] = 0; img[off+27] = 0;
            for (j = 28; j < 32; j = j + 1) img[off+j] = 0;
            img[off+32] = nlen[7:0];
            for (j = 0; j < nlen; j = j + 1) img[off+33+j] = nm[8*(nlen-1-j) +: 8];
            if ((33+nlen) & 1) img[off+33+nlen] = 0;
            next_off = off + rl;
        end
    endtask

    task be16(input integer a, input [15:0] v);
        begin img[a] = v[15:8]; img[a+1] = v[7:0]; end
    endtask
    task be32(input integer a, input [31:0] v);
        begin img[a]=v[31:24]; img[a+1]=v[23:16]; img[a+2]=v[15:8]; img[a+3]=v[7:0]; end
    endtask

    // PGC at byte pa with ncells one-sector cells from first_rbn; one program per
    // cell. Cell table @256, program map @240. Per-cell still/cmd set by put_cell.
    task put_pgc(input integer pa, input [7:0] ncells, input [15:0] nxt,
                 input [31:0] first_rbn);
        integer c, p;
        begin
            img[pa+2] = ncells; img[pa+3] = ncells;
            be16(pa+156, nxt); be16(pa+158, 0); be16(pa+160, 0);
            img[pa+163] = 0;
            be16(pa+228, 0); be16(pa+230, 16'd240); be16(pa+232, 16'd256);
            for (p = 0; p < ncells; p = p + 1) begin
                img[pa+240+p] = p + 1;
                c = pa + 256 + p*24;
                be32(c+8,  first_rbn + p);
                be32(c+20, first_rbn + p);
            end
        end
    endtask
    task put_cell(input integer pa, input integer idx, input [7:0] still, input [7:0] cmdnr);
        begin img[pa+256+idx*24+2] = still; img[pa+256+idx*24+3] = cmdnr; end
    endtask
    // a command table @off holding ONE cell command (0 pre, 0 post)
    task put_cellcmd(input integer pa, input [15:0] off, input [63:0] c);
        integer k; begin
            be16(pa+228, off);
            be16(pa+off+0, 16'd0); be16(pa+off+2, 16'd0); be16(pa+off+4, 16'd1);
            be16(pa+off+6, 16'd15);
            for (k = 0; k < 8; k = k + 1) img[pa+off+8+k] = c[8*(7-k) +: 8];
        end
    endtask

    // Title VOB VTS_01_1.VOB at sector 30 (10 cells A0..A9), menu VOB VTS_01_0.VOB
    // at sector 26 (2 cells D0, D1).
    task build;
        integer j, b;
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;
            img[32768]=1; img[32769]="C"; img[32770]="D"; img[32771]="0";
            img[32772]="0"; img[32773]="1"; img[32774]=1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);
            cur = 17*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 18, 2048, 8'h02, "VIDEO_TS", 8, cur);
            cur = 18*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 2048, 8'h00, "VIDEO_TS.IFO;1", 14, cur);
            put_rec(cur, 20, 8192, 8'h00, "VTS_01_0.IFO;1", 14, cur);      // 20..23
            put_rec(cur, 26, 2*2048, 8'h00, "VTS_01_0.VOB;1", 14, cur);    // 26..27
            put_rec(cur, 30, 10*2048, 8'h00, "VTS_01_1.VOB;1", 14, cur);   // 30..39

            be32(19*2048+196, 32'd0);                 // no TT_SRPT
            be32(20*2048+204, 32'd1);                 // vts_pgcit    -> 21
            be32(20*2048+208, 32'd3);                 // vtsm_pgci_ut -> 23

            // title VTS_PGCIT @21 (spans 21-22): 7 SRPs
            b = 21*2048;
            be16(b+0, 16'd7);
            be32(b+8+4,  32'd64);
            be32(b+16+4, 32'd448);
            be32(b+24+4, 32'd848);
            be32(b+32+4, 32'd1248);
            be32(b+40+4, 32'd1648);
            be32(b+48+4, 32'd2048);
            be32(b+56+4, 32'd2448);
            put_pgc(b+64,   8'd2, 16'd0, 32'd0);  put_cell(b+64,   0, 8'd255, 8'd0);  // A0 A1
            put_pgc(b+448,  8'd1, 16'd0, 32'd2);  put_cell(b+448,  0, 8'd255, 8'd0);  // A2
            put_pgc(b+848,  8'd1, 16'd0, 32'd3);  put_cell(b+848,  0, 8'd200, 8'd1);  // A3
            put_pgc(b+1248, 8'd2, 16'd0, 32'd4);  put_cell(b+1248, 0, 8'd3,   8'd0);  // A4 A5
            put_pgc(b+1648, 8'd1, 16'd0, 32'd6);  put_cell(b+1648, 0, 8'd5,   8'd1);  // A6
            put_pgc(b+2048, 8'd1, 16'd0, 32'd7);  put_cell(b+2048, 0, 8'd255, 8'd1);  // A7
            put_cellcmd(b+2048, 16'd300, 64'h2006000000000001);                   // LinkPGN 1
            put_pgc(b+2448, 8'd2, 16'd0, 32'd8);  put_cell(b+2448, 0, 8'd255, 8'd1);  // A8 A9

            // VTSM PGCI_UT @23: one LU -> PGCIT @16 with 2 SRPs
            b = 23*2048;
            be16(b+0, 16'd1);
            be32(b+4, 32'd2000);
            be16(b+8, 16'h656E); img[b+10] = 0; img[b+11] = 8'h80;
            be32(b+12, 32'd16);
            be16(b+16, 16'd2);
            be32(b+20, 32'd2000);
            be32(b+16+8+4,  32'd64);
            be32(b+16+16+4, 32'd600);
            put_pgc(b+16+64,  8'd1, 16'd0, 32'd0); put_cell(b+16+64,  0, 8'd0,   8'd0); // D0
            put_pgc(b+16+600, 8'd1, 16'd0, 32'd1); put_cell(b+16+600, 0, 8'd255, 8'd0); // D1

            for (j = 0; j < 2048; j = j + 1) begin
                img[26*2048 + j] = 8'hD0;
                img[27*2048 + j] = 8'hD1;
            end
            for (j = 0; j < 10*2048; j = j + 1)
                img[30*2048 + j] = 8'hA0 + (j / 2048);
        end
    endtask

    // ---- drivers -----------------------------------------------------------
    integer t0;
    task do_jump(input [1:0] dom, input [15:0] pgcn);
    begin
        @(negedge clk);
        jump_domain = dom; jump_vts = 8'd1; jump_pgcn = pgcn; jump_entry = 0;
        jump_ttn = 0; jump_pgn = 0; jump_pulse = 1;
        @(negedge clk); jump_pulse = 0;
        // Return only once the reader has TAKEN the jump: a hold from the previous
        // arm keeps still_active high until then, and wait_park would read it.
        t0 = 0;
        while (!(jump_ack === 1'b1) && t0 < 2000000) begin @(posedge clk); t0 = t0 + 1; end
        if (jump_ack !== 1'b1) begin $display("FAIL: jump never acked"); errors = errors + 1; end
        @(negedge clk);
    end
    endtask

    task press;
    begin
        @(negedge clk); still_off = 1; @(negedge clk); still_off = 0;
    end
    endtask

    // Wait for the reader to park in S_STILL with `want` the last byte streamed.
    task wait_park(input [7:0] want, input [8*40-1:0] label);
        integer t;
    begin
        t = 0;
        while (!(still_active === 1'b1) && t < 2000000) begin @(posedge clk); t = t + 1; end
        if (still_active !== 1'b1) begin
            $display("FAIL %0s: never parked on a still (state=%0d last=%02x)",
                     label, dut.state, last_byte);
            errors = errors + 1;
        end else if (last_byte !== want) begin
            $display("FAIL %0s: parked after %02x, expected %02x", label, last_byte, want);
            errors = errors + 1;
        end
        repeat (50) @(negedge clk);
    end
    endtask

    // Count events over a window of n cycles from a snapshot.
    integer s_bytes, s_seek, s_jump, s_cmd, s_pgend;
    task snap;
    begin
        s_bytes = n_bytes; s_seek = n_seek; s_jump = n_jump; s_cmd = n_cmd; s_pgend = n_pgend;
    end
    endtask

    // Nothing happened since snap: still parked, no stream, no event.
    task check_held(input integer cycles, input [8*48-1:0] label);
    begin
        repeat (cycles) @(posedge clk);
        if (still_active !== 1'b1 || n_bytes != s_bytes || n_seek != s_seek ||
            n_jump != s_jump || n_cmd != s_cmd || n_pgend != s_pgend) begin
            $display("FAIL %0s: expected the hold to stand (still=%b bytes+%0d seek+%0d jump+%0d cmd+%0d pgend+%0d)",
                     label, still_active, n_bytes-s_bytes, n_seek-s_seek, n_jump-s_jump,
                     n_cmd-s_cmd, n_pgend-s_pgend);
            errors = errors + 1;
        end else
            $display("%0s -> held  PASS", label);
    end
    endtask

    // VM stand-in: answer a POST/cell-command wait with vm_adv after a delay.
    task answer_adv;
    begin
        repeat (20) @(negedge clk); vm_adv = 1; @(negedge clk); vm_adv = 0;
    end
    endtask

    task wait_nav_ready;
        integer t;
    begin
        t = 0;
        while (!nav_ready_w && t < 2000000) begin @(posedge clk); t = t + 1; end
        if (!nav_ready_w) begin $display("FAIL: nav_ready timeout"); errors = errors + 1; end
        repeat (20) @(negedge clk);
    end
    endtask

    integer t;
    initial begin
        build; file_size = IMG_BYTES;
        repeat (5) @(negedge clk); rst_n = 1; repeat (5) @(negedge clk);
        start = 1; @(negedge clk); start = 0;
        wait_nav_ready;

        // ---- A: indefinite still mid-PGC -> next cell --------------------------
        do_jump(2'd3, 16'd1);
        wait_park(8'hA0, "A0 park on A0");
        if (dut.still_act !== 1'b1)
            begin $display("FAIL A0: an indefinite title still has no Still off (still_act=%b)", dut.still_act); errors = errors + 1; end
        snap; press;
        t = 0; while (last_byte !== 8'hA1 && t < 200000) begin @(posedge clk); t = t + 1; end
        if (last_byte !== 8'hA1 || n_seek != s_seek || n_jump != s_jump)
            begin $display("FAIL A: press on A0 -> last=%02x seek+%0d jump+%0d (expected A1, none)",
                            last_byte, n_seek-s_seek, n_jump-s_jump); errors = errors + 1; end
        else $display("A: indefinite still + press -> next cell A1  PASS");

        // ---- B: indefinite still on the last cell -> PGC end -------------------
        repeat (2000) @(negedge clk);
        do_jump(2'd3, 16'd2);
        wait_park(8'hA2, "B0 park on A2");
        snap; press;
        t = 0; while (n_pgend == s_pgend && t < 200000) begin @(posedge clk); t = t + 1; end
        // ...and DIRECTLY: no cell may stream between the press and the PGC end
        // (a "next cell" past the last one reads a garbage cell first).
        if (n_pgend != s_pgend + 1 || n_cmd != s_cmd || n_bytes != s_bytes)
            begin $display("FAIL B: press on A2 (last cell) -> pgend+%0d cmd+%0d bytes+%0d (expected 1, 0, 0)",
                            n_pgend-s_pgend, n_cmd-s_cmd, n_bytes-s_bytes); errors = errors + 1; end
        else $display("B: last-cell indefinite still + press -> PGC end  PASS");
        answer_adv;

        // ---- C: 200 s timed still with a cell command -> the command at once ---
        repeat (2000) @(negedge clk);
        do_jump(2'd3, 16'd3);
        wait_park(8'hA3, "C0 park on A3");
        if (dut.still_timed !== 1'b1)
            begin $display("FAIL C0: A3 is not a timed still"); errors = errors + 1; end
        snap; press;
        t = 0; while (n_cmd == s_cmd && t < 20000) begin @(posedge clk); t = t + 1; end
        if (n_cmd != s_cmd + 1 || n_pgend != s_pgend)
            begin $display("FAIL C: press on a 200 s still -> cmd+%0d pgend+%0d after %0d clk (expected 1, 0, well under %0d)",
                            n_cmd-s_cmd, n_pgend-s_pgend, t, 200*SEC); errors = errors + 1; end
        else $display("C: timed still + press -> cell command at once  PASS");
        answer_adv;

        // ---- D: 3 s timed still, no press -> the timer still advances ---------
        repeat (2000) @(negedge clk);
        do_jump(2'd3, 16'd4);
        wait_park(8'hA4, "D0 park on A4");
        t = 0; while (last_byte !== 8'hA5 && t < 10*SEC) begin @(posedge clk); t = t + 1; end
        if (last_byte !== 8'hA5)
            begin $display("FAIL D: the 3 s timed still never advanced (last=%02x)", last_byte); errors = errors + 1; end
        else $display("D: timed still, no press -> timer advances to A5 after %0d clk  PASS", t);

        // ---- E: a timed still left by a jump leaves no timer behind -----------
        repeat (2000) @(negedge clk);
        do_jump(2'd3, 16'd5);
        wait_park(8'hA6, "E0 park on A6");
        repeat (SEC/2) @(negedge clk);
        snap;
        do_jump(2'd2, 16'd1);                       // VTSM PGC1: D0, then POST falls through
        t = 0; while (n_pgend == s_pgend && t < 200000) begin @(posedge clk); t = t + 1; end
        snap;
        answer_adv;                                 // POST: nothing -> dead-end hold
        t = 0; while (!(still_active === 1'b1) && t < 200000) begin @(posedge clk); t = t + 1; end
        if (still_active !== 1'b1 || last_byte !== 8'hD0)
            begin $display("FAIL E0: no dead-end hold after D0 (still=%b last=%02x)", still_active, last_byte); errors = errors + 1; end
        snap;
        check_held(10*SEC, "E: no stale timer on a later dead-end hold");

        // ---- F: a press on the dead-end hold does nothing ----------------------
        // Its own fresh hold, so a stale timer that fired in E cannot fail F too.
        snap;
        do_jump(2'd2, 16'd1);
        t = 0; while (n_pgend == s_pgend && t < 200000) begin @(posedge clk); t = t + 1; end
        answer_adv;
        t = 0; while (!(still_active === 1'b1) && t < 200000) begin @(posedge clk); t = t + 1; end
        if (still_active !== 1'b1)
            begin $display("FAIL F0: no dead-end hold after D0"); errors = errors + 1; end
        repeat (50) @(negedge clk);
        snap; press;
        check_held(20000, "F: press on the POST fall-through hold");

        // ---- G: Disc Menus off: a menu indefinite still ignores the key --------
        vm_mode = 0;
        do_jump(2'd2, 16'd2);
        wait_park(8'hD1, "G0 park on D1 (menus off)");
        snap; press;
        check_held(20000, "G: menus off, menu 0xFF still + press");
        vm_mode = 1;

        // ---- H: a press before the still parks is not remembered ---------------
        do_jump(2'd3, 16'd1);
        t = 0; while (!(stream_valid === 1'b1 && stream_data === 8'hA0) && t < 2000000)
            begin @(posedge clk); t = t + 1; end
        press;                                      // A0 is streaming, not parked
        wait_park(8'hA0, "H0 park on A0");
        snap;
        check_held(20000, "H: press while A0 streamed, then park");

        // ---- I: indefinite still + a cell command -> held, then the command -----
        repeat (2000) @(negedge clk);
        do_jump(2'd3, 16'd6);
        wait_park(8'hA7, "I0 park on A7");
        if (dut.still_act !== 1'b1)
            begin $display("FAIL I0: no Still off on an indefinite still with a command"); errors = errors + 1; end
        snap;
        check_held(20000, "I1: the command waits out the still");
        snap; press;
        t = 0; while (n_cmd == s_cmd && t < 20000) begin @(posedge clk); t = t + 1; end
        if (n_cmd != s_cmd + 1 || n_pgend != s_pgend || n_bytes != s_bytes)
            begin $display("FAIL I: press on A7 -> cmd+%0d pgend+%0d bytes+%0d (expected 1, 0, 0)",
                            n_cmd-s_cmd, n_pgend-s_pgend, n_bytes-s_bytes); errors = errors + 1; end
        else $display("I: indefinite still + command -> held, press -> the command  PASS");
        answer_adv;

        // ---- J: indefinite still + a malformed cmd_nr -> held, then next cell --
        repeat (2000) @(negedge clk);
        do_jump(2'd3, 16'd7);
        wait_park(8'hA8, "J0 park on A8");
        snap;
        check_held(20000, "J1: a malformed cmd_nr still holds");
        snap; press;
        t = 0; while (last_byte !== 8'hA9 && t < 200000) begin @(posedge clk); t = t + 1; end
        if (last_byte !== 8'hA9 || n_cmd != s_cmd || n_seek != s_seek || n_jump != s_jump)
            begin $display("FAIL J: press on A8 -> last=%02x cmd+%0d seek+%0d jump+%0d (expected A9, 0, 0, 0)",
                            last_byte, n_cmd-s_cmd, n_seek-s_seek, n_jump-s_jump); errors = errors + 1; end
        else $display("J: malformed cmd_nr -> held, press -> next cell A9, no command  PASS");

        if (errors == 0) begin
            $display("ISO_READER_STILLOFF_TB: ALL TESTS PASSED");
            $finish;
        end else
            $fatal(1, "ISO_READER_STILLOFF_TB: FAILED with %0d errors", errors);
    end

    initial begin #400000000; $fatal(1, "GLOBAL TIMEOUT st=%0d", dut.state); end

endmodule
