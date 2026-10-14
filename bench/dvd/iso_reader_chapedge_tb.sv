// iso_reader_chapedge_tb.sv - Next/Prev chapter at the TITLE EDGE (audit item 7).
//
// With Disc Menus on (vm_mode) a chapter burst that has nowhere left to go in
// the title is handed to the VM (chap_edge / chap_edge_dir) instead of
// clamping:
//   Next that STARTS on the title's last chapter -> chap_edge dir=1 (VM: POST)
//   Prev at the start of chapter 1 with a prev_pgcn naming ANOTHER PGC
//                                                 -> chap_edge dir=0 (VM: link)
// Everything else keeps today's behaviour: an overshooting burst clamps, a
// prev_pgcn of 0 or of this PGC restarts chapter 1, one Prev mid-chapter
// restarts it, and Disc Menus off never emits. The Prev landing uses a new
// "last program" start (jump_pgn = 8'hFF), checked here on the reader side.
// See docs/dvd_nav.md "Chapter skip at the title's edges".
//
// Fixture (2048-byte sectors; cells are 16 sectors, see iso_reader_ptt_tb):
//   VTS_01 PGCIT, entry_ids 0:
//     PGC1  2 programs  cells B0 B1   prev 0
//     PGC2  1 program   cell  B2      prev 0
//     PGC3  2 programs  cells B3 B4   prev 1   (another PGC)
//     PGC4  2 programs  cells B5 B6   prev 4   (ITSELF)
//   VTS_PTT_SRPT:
//     t1 = {1,1} {1,2} {2,1}   multi-PGC, PGC2 holds the last chapter
//     t2 = {2,1}               single chapter
//     t3 = {3,1} {3,2}
//     t4 = {4,1} {4,2}
//   Phase 2 re-mounts the same image with NO VTS_PTT_SRPT (nr_ptt = 0), so the
//   no-table resolve arm (CH_R) is exercised as well as CH_GR's legacy branch.
//
// Arms (bench/dvd/run_chap_edge.sh --red names the mutation for each):
//   A  t1 ch3 (last, PGC2): Next -> edge dir=1, no seek/jump
//   B  same with vm_mode=0 -> no edge, no move (today's clamp)
//   C  t3 ch1: Next x3 -> clamps to ch2 (seek, B4), no edge
//   D  t3 ch2: Next -> edge dir=1
//   E  t3 ch1 start: Prev, prev_pgcn=1 -> edge dir=0, no seek
//   F  t4 ch1 start: Prev, prev_pgcn=self -> restart ch1 (seek, B5), no edge
//   G  t1 ch1 start: Prev, prev_pgcn=0 -> restart ch1 (seek, B0), no edge
//   H  t3 ch1 MID-chapter: Prev -> restart ch1 (seek, B3), no edge
//   I  jump VTS1 PGCN3 pgn=0xFF -> lands on PGC3's last program (B4)
//   J  t2 (single chapter): Next -> edge dir=1 (the vm_mode arm relaxation)
//   K  no PTT table, PGC3 ch2: Next -> edge dir=1 (CH_R arm)
//   L  no PTT table, PGC3 ch1 start: Prev -> edge dir=0 (CH_R arm)
`timescale 1ns/1ps

module iso_reader_chapedge_tb;

    localparam NVOB = 7*16;                    // 7 cells x 16 sectors
    localparam IMG_SECS  = 25 + NVOB;
    localparam IMG_BYTES = IMG_SECS*2048;

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
    reg  [9:0]  jump_ptt = 0;
    wire        jump_ack, pgc_loaded, pgc_error, menu_active, still_active;
    wire        seek_ack, nav_ready_w;

    reg         vm_mode = 1;
    reg         chap_pulse = 0;
    reg         chap_dir = 0;
    reg  [4:0]  chap_mag = 5'd1;
    reg         chap_at_start = 1;
    wire [7:0]  cur_pgm_w;
    wire [10:0] nr_ptt_w;
    wire        chap_edge, chap_edge_dir;

    dvd_iso_reader dut (
        .cc_btns(1'b0),   // issue #176 hold off: a new input floats Z unless tied
        .cc_aud_low(1'b0), // issue #176 audio-low release off: tie the new input
        .agl_vm(4'd0), .agl_vm_en(1'b0), .vm_pre_done(1'b0),
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(7'd0),
        .aud_drained(1'b1), .vbuf_empty(1'b0),
        .jump_ttn(jump_ttn), .jump_pgn(jump_pgn), .jump_ptt(jump_ptt),
        .still_off(1'b0), .vm_mode(vm_mode), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(nav_ready_w),
        .auto_vts(), .cell_count_o(), .res_ttn(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(seek_ack),
        .seek_rbn_pulse(1'b0), .seek_rbn(32'd0), .seek_tm_req(1'b0), .seek_tm_secs(17'd0),
        .cur_cell(), .cell_ready(),
        .chap_pulse(chap_pulse), .chap_dir(chap_dir), .chap_mag(chap_mag),
        .chap_at_start(chap_at_start), .cur_pgm(cur_pgm_w), .nr_ptt_o(nr_ptt_w),
        .chap_edge(chap_edge), .chap_edge_dir(chap_edge_dir),
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
    reg       await_first = 0;
    reg [7:0] post_jump_byte = 0;
    reg       post_jump_v = 0;
    reg       saw_seek_ack = 0, saw_jump_ack = 0;
    integer   edge_n = 0;
    reg       edge_dir_l = 0;
    always @(posedge clk) begin
        if (jump_ack || seek_ack) begin await_first <= 1'b1; post_jump_v <= 1'b0; end
        if (seek_ack) saw_seek_ack <= 1'b1;
        if (jump_ack) saw_jump_ack <= 1'b1;
        if (chap_edge === 1'b1) begin edge_n = edge_n + 1; edge_dir_l = chap_edge_dir; end
        if (stream_valid && await_first) begin
            post_jump_byte <= stream_data;
            post_jump_v    <= 1'b1;
            await_first    <= 1'b0;
        end
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

    // PGC at byte pa: nprog programs over nprog cells (program p -> cell p+1),
    // cells at first_rbn, first_rbn+16, ...; prev_pgcn @158.
    task put_pgc(input integer pa, input [7:0] nprog, input [15:0] prev,
                 input [31:0] first_rbn);
        integer c, p;
        begin
            img[pa+2] = nprog; img[pa+3] = nprog;
            be16(pa+156, 0); be16(pa+158, prev); be16(pa+160, 0);
            img[pa+163] = 0;
            be16(pa+228, 0); be16(pa+230, 16'd240); be16(pa+232, 16'd256);
            for (p = 0; p < nprog; p = p + 1) begin
                img[pa+240+p] = p + 1;
                c = pa + 256 + p*24;
                be32(c+8,  first_rbn + p*16);
                be32(c+20, first_rbn + p*16 + 15);
            end
        end
    endtask

    task build(input with_ptt);
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
            put_rec(cur, 20, 10240, 8'h00, "VTS_01_0.IFO;1", 14, cur);      // 20..24
            put_rec(cur, 25, NVOB*2048, 8'h00, "VTS_01_1.VOB;1", 14, cur);  // 25..

            be32(19*2048+196, 32'd0);                 // no TT_SRPT (JumpVTS_TT path)
            be32(20*2048+200, with_ptt ? 32'd1 : 32'd0);  // vts_ptt_srpt -> 21
            be32(20*2048+204, 32'd4);                 // vts_pgcit    -> 24

            // VTS_PTT_SRPT @21: 4 titles
            b = 21*2048;
            be16(b+0, 16'd4);
            be32(b+4, 32'd135);                       // last_byte (t4 ends at 136)
            be32(b+8, 32'd100); be32(b+12, 32'd112); be32(b+16, 32'd116); be32(b+20, 32'd124);
            be16(b+100,1); be16(b+102,1);  be16(b+104,1); be16(b+106,2);  be16(b+108,2); be16(b+110,1);
            be16(b+112,2); be16(b+114,1);
            be16(b+116,3); be16(b+118,1);  be16(b+120,3); be16(b+122,2);
            be16(b+124,4); be16(b+126,1);  be16(b+128,4); be16(b+130,2);

            // VTS_PGCIT @24: 4 SRPs, entry_id 0
            b = 24*2048;
            be16(b+0, 16'd4);
            be32(b+8+4,  32'd16);
            be32(b+16+4, 32'd400);
            be32(b+24+4, 32'd800);
            be32(b+32+4, 32'd1200);
            put_pgc(b+16,   8'd2, 16'd0, 32'd0);      // PGC1: B0 B1
            put_pgc(b+400,  8'd1, 16'd0, 32'd32);     // PGC2: B2
            put_pgc(b+800,  8'd2, 16'd1, 32'd48);     // PGC3: B3 B4, prev = PGC1
            put_pgc(b+1200, 8'd2, 16'd4, 32'd80);     // PGC4: B5 B6, prev = itself

            for (j = 0; j < NVOB*2048; j = j + 1)
                img[25*2048 + j] = 8'hB0 + (j / (16*2048));
        end
    endtask

    // ---- drivers -----------------------------------------------------------
    task do_jump(input [6:0] ttn, input [15:0] pgcn, input [7:0] pgn, input [9:0] part);
    begin
        @(negedge clk);
        jump_domain = 2'd3; jump_vts = 8'd1; jump_pgcn = pgcn; jump_entry = 0;
        jump_ttn = ttn; jump_pgn = pgn; jump_ptt = part; jump_pulse = 1;
        @(negedge clk); jump_pulse = 0; jump_ptt = 0;
    end
    endtask

    // Mount a title (or a PGC), let its first byte stream, then pin the cell
    // (busy=1) so the skip resolves against a stable cell_i.
    task mount(input [6:0] ttn, input [15:0] pgcn, input [7:0] pgn,
               input [7:0] want, input [8*48-1:0] label);
        begin mount_part(ttn, pgcn, pgn, 10'd0, want, label); end
    endtask

    // ...at chapter `part` of title `ttn` (JumpVTS_PTT), so an arm can start
    // where it needs to without depending on an earlier arm's landing.
    task mount_part(input [6:0] ttn, input [15:0] pgcn, input [7:0] pgn,
                    input [9:0] part, input [7:0] want, input [8*48-1:0] label);
        integer t;
    begin
        // Isolation: let anything a previous arm left in flight (a seek that
        // a mutation produced instead of an edge) land first, then sample the
        // first byte after THIS jump's own ack - so one failing arm cannot
        // cascade into the next arm's mount.
        busy = 0;
        repeat (20000) @(negedge clk);
        saw_jump_ack = 0;
        do_jump(ttn, pgcn, pgn, part);
        t = 0;
        while (!saw_jump_ack && t < 3000000) begin @(posedge clk); t = t + 1; end
        t = 0;
        while (!post_jump_v && t < 3000000) begin @(posedge clk); t = t + 1; end
        if (post_jump_byte !== want) begin
            $display("FAIL %0s: mount streamed %02x, expected %02x", label, post_jump_byte, want);
            errors = errors + 1;
        end
        busy = 1;
        repeat (200) @(negedge clk);
    end
    endtask

    task chap_skip(input dir, input [4:0] mag);
    begin
        saw_seek_ack = 0; saw_jump_ack = 0; post_jump_v = 0;
        @(negedge clk);
        chap_dir = dir; chap_mag = mag; chap_pulse = 1;
        @(negedge clk); chap_pulse = 0;
    end
    endtask

    // A move resolved through a within-PGC SEEK and landed on `want`, no edge.
    task check_seek(input [7:0] want, input integer e0, input [8*48-1:0] label);
        integer t;
    begin
        t = 0;
        while (!saw_seek_ack && !saw_jump_ack && t < 3000000) begin @(posedge clk); t = t + 1; end
        if (!saw_seek_ack || saw_jump_ack) begin
            $display("FAIL %0s: expected a SEEK (seek=%0d jump=%0d)", label, saw_seek_ack, saw_jump_ack);
            errors = errors + 1;
        end else begin
            busy = 0;
            t = 0;
            while (!post_jump_v && t < 3000000) begin @(posedge clk); t = t + 1; end
            busy = 1;
            if (post_jump_byte !== want) begin
                $display("FAIL %0s: landed %02x, expected %02x", label, post_jump_byte, want);
                errors = errors + 1;
            end else if (edge_n !== e0) begin
                $display("FAIL %0s: a chap_edge fired on an ordinary move", label);
                errors = errors + 1;
            end else
                $display("%0s -> seek, landed %02x  PASS", label, want);
        end
        repeat (200) @(negedge clk);
    end
    endtask

    // An edge: exactly one chap_edge with the expected direction, and no move.
    task check_edge(input want_dir, input integer e0, input [8*48-1:0] label);
        integer t;
    begin
        for (t = 0; t < 6000; t = t + 1) @(posedge clk);
        if (edge_n !== e0 + 1) begin
            $display("FAIL %0s: %0d chap_edge pulses, expected 1", label, edge_n - e0);
            errors = errors + 1;
        end else if (edge_dir_l !== want_dir) begin
            $display("FAIL %0s: chap_edge_dir=%0d, expected %0d", label, edge_dir_l, want_dir);
            errors = errors + 1;
        end else if (saw_seek_ack || saw_jump_ack) begin
            $display("FAIL %0s: the edge also moved (seek=%0d jump=%0d)",
                     label, saw_seek_ack, saw_jump_ack);
            errors = errors + 1;
        end else
            $display("%0s -> edge dir=%0d  PASS", label, want_dir);
    end
    endtask

    // Neither an edge nor a move.
    task check_none(input integer e0, input [8*48-1:0] label);
        integer t;
    begin
        for (t = 0; t < 6000; t = t + 1) @(posedge clk);
        if (edge_n !== e0 || saw_seek_ack || saw_jump_ack) begin
            $display("FAIL %0s: expected nothing (edges=%0d seek=%0d jump=%0d)",
                     label, edge_n - e0, saw_seek_ack, saw_jump_ack);
            errors = errors + 1;
        end else
            $display("%0s -> no edge, no move  PASS", label);
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

    integer e0;
    initial begin
        // ======== Phase 1: VTS_PTT_SRPT present (CH_GR legacy branch) ========
        build(1'b1); file_size = IMG_BYTES;
        repeat (5) @(negedge clk); rst_n = 1; repeat (5) @(negedge clk);
        start = 1; @(negedge clk); start = 0;
        wait_nav_ready;

        // A: title 1 ch3 = PGC2, the last chapter of a multi-PGC title
        mount(7'd1, 16'd0, 8'd0, 8'hB0, "A0 mount t1");
        chap_at_start = 1;
        chap_skip(1'b1, 5'd1); check_seek(8'hB1, edge_n, "A1 setup t1 ch1->ch2");
        e0 = edge_n; chap_skip(1'b1, 5'd1);
        // the cross-PGC ch2->ch3 jump (the HW-confirmed path, unchanged)
        begin : waj integer t; t = 0;
            while (!saw_jump_ack && t < 3000000) begin @(posedge clk); t = t + 1; end
            busy = 0; t = 0;
            while (!post_jump_v && t < 3000000) begin @(posedge clk); t = t + 1; end
            busy = 1;
            if (!saw_jump_ack || post_jump_byte !== 8'hB2 || edge_n !== e0) begin
                $display("FAIL A2: cross-PGC ch2->ch3 jump=%0d byte=%02x edges=%0d",
                         saw_jump_ack, post_jump_byte, edge_n - e0);
                errors = errors + 1;
            end else $display("A2 setup t1 ch2->ch3 cross-PGC, no edge  PASS");
            repeat (200) @(negedge clk);
        end
        e0 = edge_n; chap_skip(1'b1, 5'd1); check_edge(1'b1, e0, "A: t1 Next at the last chapter");

        // B: the same press with Disc Menus off is today's clamp: nothing.
        vm_mode = 0;
        e0 = edge_n; chap_skip(1'b1, 5'd1); check_none(e0, "B: t1 Next at last, vm_mode=0");
        vm_mode = 1;

        // C: overshoot clamps (Next x3 from t3 ch1 lands on ch2, no edge)
        mount(7'd3, 16'd0, 8'd0, 8'hB3, "C0 mount t3");
        e0 = edge_n; chap_skip(1'b1, 5'd3); check_seek(8'hB4, e0, "C: t3 Next x3 clamps to ch2");

        // D: ...and a Next FROM the last chapter is the edge (own mount at
        // t3 part 2, so D does not lean on C's landing)
        mount_part(7'd3, 16'd0, 8'd0, 10'd2, 8'hB4, "D0 mount t3 ch2");
        e0 = edge_n; chap_skip(1'b1, 5'd1); check_edge(1'b1, e0, "D: t3 Next from the last chapter");

        // E: Prev at ch1's start, prev_pgcn = PGC1 (another PGC) -> edge dir=0
        mount(7'd3, 16'd0, 8'd0, 8'hB3, "E0 mount t3");
        chap_at_start = 1;
        e0 = edge_n; chap_skip(1'b0, 5'd1); check_edge(1'b0, e0, "E: t3 Prev at ch1, prev=other");

        // H: one Prev MID-chapter 1 restarts it, even with a prev_pgcn
        chap_at_start = 0;
        e0 = edge_n; chap_skip(1'b0, 5'd1); check_seek(8'hB3, e0, "H: t3 Prev mid-ch1 restarts");
        chap_at_start = 1;

        // F: prev_pgcn = this PGC -> restart ch1 (deliberate libdvdnav deviation)
        mount(7'd4, 16'd0, 8'd0, 8'hB5, "F0 mount t4");
        e0 = edge_n; chap_skip(1'b0, 5'd1); check_seek(8'hB5, e0, "F: t4 Prev at ch1, prev=self");

        // G: prev_pgcn = 0 -> restart ch1 (today's behaviour)
        mount(7'd1, 16'd0, 8'd0, 8'hB0, "G0 mount t1");
        e0 = edge_n; chap_skip(1'b0, 5'd1); check_seek(8'hB0, e0, "G: t1 Prev at ch1, prev=0");

        // I: the Prev landing: PGCN 3 starting at its LAST program (pgn 0xFF)
        mount(7'd0, 16'd3, 8'hFF, 8'hB4, "I: jump PGCN3 pgn=0xFF -> last program");
        if (post_jump_byte === 8'hB4) $display("I: jump PGCN3 pgn=0xFF lands on B4  PASS");

        // J: a single-chapter title arms in vm_mode, and Next is its edge
        mount(7'd2, 16'd0, 8'd0, 8'hB2, "J0 mount t2");
        e0 = edge_n; chap_skip(1'b1, 5'd1); check_edge(1'b1, e0, "J: t2 single chapter Next");

        // ======== Phase 2: no VTS_PTT_SRPT (nr_ptt = 0 -> CH_R) ==============
        busy = 0;
        build(1'b0);
        start = 1; @(negedge clk); start = 0;
        wait_nav_ready;
        mount(7'd0, 16'd3, 8'd0, 8'hB3, "K0 mount PGCN3");
        if (nr_ptt_w !== 11'd0) begin
            $display("FAIL K0: nr_ptt=%0d, the no-table fixture expects 0", nr_ptt_w);
            errors = errors + 1;
        end
        // L first (we are on ch1): Prev at ch1, prev_pgcn = 1 -> edge dir=0
        chap_at_start = 1;
        e0 = edge_n; chap_skip(1'b0, 5'd1); check_edge(1'b0, e0, "L: no PTT, Prev at ch1, prev=other");
        e0 = edge_n; chap_skip(1'b1, 5'd1); check_seek(8'hB4, e0, "K1 setup no PTT ch1->ch2");
        e0 = edge_n; chap_skip(1'b1, 5'd1); check_edge(1'b1, e0, "K: no PTT, Next at the last chapter");
        busy = 0;

        if (errors == 0) begin
            $display("ISO_READER_CHAPEDGE_TB: ALL TESTS PASSED");
            $finish;
        end else
            $fatal(1, "ISO_READER_CHAPEDGE_TB: FAILED with %0d errors", errors);
    end

    initial begin #400000000; $fatal(1, "GLOBAL TIMEOUT st=%0d", dut.state); end

endmodule
