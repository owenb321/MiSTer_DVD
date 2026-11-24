// iso_reader_trick_tb.sv -- trick play in dvd/dvd_iso_reader.sv on a REAL disc image.
//
// Serves every sector the reader asks for straight from the .iso ($fseek + $fread at
// run time; no image array), so the reader navigates the disc as it would on the
// board: IFOs, the title PGC, its cells. Then:
//   1. seeks to +SEEK (an RBN inside the title, chosen by the runner);
//   2. raises trick_en with +TIER / +REV, trick_go free (+GOPER=0) or one pulse every
//      +GOPER cycles (the cadence gate);
//   3. runs until +VOBUS VOBUs have been armed or the PGC's edge is reached;
//   4. drops trick_en and checks the reader carries on reading (the exit floor);
//   5. re-enters trick play mid-sector: every armed sector must be a NAV pack.
//
// Log (+OUT): what bench/dvd/run_trick_reader.sh compares with tools/trick_splice.py
// walk_cells over the SAME cell table:
//   C <i> <first> <last> <lvobu>   the reader's cell table (program order), at the seek
//   T <cell_i>                      the reader's cell when trick play began
//   R <lba>                         every sector STREAMED once trick play is on
//   P <lba>                         any other read (the seek's NAV-pack search)
//   A <nav> <end> <xcell_n> <cell>  every armed VOBU (trick_vobu), and the reader's cell_i
//   G                               a cadence-gate pulse (GOPER only)
//   E                               the edge was reached
//   X <reads>                       sectors read after trick_en fell (must be > 0)
// Prints PASS when the run completed (the comparison is the runner's).
`timescale 1ns/1ps

module iso_reader_trick_tb;
    reg         clk = 0;
    always #5 clk = ~clk;
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

    reg         seek_rbn_pulse = 0;
    reg  [31:0] seek_rbn = 0;
    wire        seek_ack;
    wire        cell_ready;
    wire [7:0]  cell_count;

    reg         trick_en = 0;
    reg  [1:0]  trick_tier = 0;
    reg         trick_rev = 0;
    reg         trick_go = 0;
    wire        trick_vobu, trick_edge;
    wire [31:0] trick_nav, trick_eltm;
    wire [15:0] trick_xcell_n;

    dvd_iso_reader dut (
        .trick_en(trick_en), .trick_tier(trick_tier), .trick_rev(trick_rev), .trick_go(trick_go),
        .trick_vobu(trick_vobu), .trick_nav(trick_nav), .trick_eltm(trick_eltm),
        .trick_edge(trick_edge), .trick_xcell_n(trick_xcell_n),
        .cc_btns(1'b0),
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size),
        .title_sel(4'd0), .aud_drained(1'b1), .vbuf_empty(1'b0),
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .still_off(1'b0), .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(cell_count),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(seek_ack),
        .seek_rbn_pulse(seek_rbn_pulse), .seek_rbn(seek_rbn), .seek_tm_req(1'b0), .seek_tm_secs(17'd0),
        .chap_pulse(1'b0), .chap_dir(1'b0), .chap_mag(5'd1), .chap_at_start(1'b0),
        .angle_pulse(1'b0), .cur_angle(), .angle_count(),
        .agl_vm(4'd0), .agl_vm_en(1'b0), .vm_pre_done(1'b0),
        .keep_vbuf(),
        .cur_cell(), .cell_ready(cell_ready),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(1'b0),
        .debug_active(), .debug_iso_mode()
    );

    // ---- the HPS: one 2048-byte sector per sd_rd, read from the image file ----
    integer fi, fo, m = 0, bc = 0, lat = 0, rc;
    reg [7:0]  sec [0:2047];
    reg [31:0] rlba = 0;
    reg [31:0] sk;
    reg        logging = 0;
    integer    n_after = 0, n_rd = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin
            sd_ack <= 1'b0;
            if (sd_rd) begin
                rlba <= sd_lba;
                // $fseek's offset is a signed 32-bit integer in Icarus: a DVD's
                // title VOBs sit past 2 GB, so seek from the start in steps of
                // 2^18 sectors (512 MB), then the remainder.
                rc = $fseek(fi, 0, 0);
                for (sk = sd_lba; sk >= 32'h40000; sk = sk - 32'h40000)
                    rc = $fseek(fi, 32'h20000000, 1);
                rc = $fseek(fi, sk * 2048, 1);
                rc = $fread(sec, fi);
                if (rc != 2048) for (bc = 0; bc < 2048; bc = bc + 1) sec[bc] = 8'h00;
                // R = a streamed sector (S_STREAM), P = any other read (the seek's
                // NAV-pack search re-reads its landing sector, then streams it)
                if (logging) $fwrite(fo, "%s %0d\n", (dut.state == dut.S_STREAM) ? "R" : "P", sd_lba);
                if (!trick_en && logging) n_after = n_after + 1;
                n_rd = n_rd + 1;
                lat <= 3; m <= 1;
            end
        end
        1: begin if (lat != 0) lat <= lat - 1; else begin sd_ack <= 1'b1; bc <= 0; m <= 2; end end
        2: begin
            sd_ack <= 1'b1; sd_buff_wr <= 1'b1;
            sd_buff_addr <= bc[13:0];
            sd_buff_dout <= sec[bc];
            bc <= bc + 1;
            if (bc == 2047) m <= 3;
        end
        3: begin sd_ack <= 1'b0; sd_buff_wr <= 1'b0; m <= 0; end
        endcase
    end

    // ---- the run ------------------------------------------------------------------
    string  iso, outp;
    integer vobus, goper, n_vobu = 0, n_go = 0, i, t, tier_a, rev_a, seek_a, maxv;
    reg sess2 = 0;
    integer n_vobu2 = 0;
    always @(posedge clk) if (trick_en && trick_vobu) begin
        // every armed sector must BE a NAV pack: the sector in transfer is the one
        // the arm came from (the arm fires at its byte 0x5FF)
        if (!(sec[1024] == 8'h00 && sec[1025] == 8'h00 && sec[1026] == 8'h01 &&
              sec[1027] == 8'hBF && sec[1030] == 8'h01))
            $fatal(1, "armed on a sector that is not a NAV pack (lba %0d)", rlba);
        if (!sess2) begin
            $fwrite(fo, "A %0d %0d %0d %0d\n", trick_nav, dut.trick_end, trick_xcell_n, dut.cell_i);
            n_vobu = n_vobu + 1;
        end else
            n_vobu2 = n_vobu2 + 1;
    end

    initial begin
        if (!$value$plusargs("ISO=%s", iso)) $fatal(1, "need +ISO=");
        if (!$value$plusargs("OUT=%s", outp)) $fatal(1, "need +OUT=");
        if (!$value$plusargs("SIZE=%d", file_size)) $fatal(1, "need +SIZE=");
        if (!$value$plusargs("SEEK=%d", seek_a)) $fatal(1, "need +SEEK=");
        if (!$value$plusargs("TIER=%d", tier_a)) tier_a = 1;
        if (!$value$plusargs("REV=%d", rev_a)) rev_a = 0;
        if (!$value$plusargs("VOBUS=%d", vobus)) vobus = 12;
        if (!$value$plusargs("GOPER=%d", goper)) goper = 0;
        fi = $fopen(iso, "rb");
        if (fi == 0) $fatal(1, "cannot open %s", iso);
        fo = $fopen(outp, "w");
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk) start = 1;
        @(posedge clk) start = 0;

        // navigation, then the title starts streaming
        t = 0;
        while (!cell_ready && t < 200_000_000) begin @(posedge clk); t = t + 1; end
        if (!cell_ready) $fatal(1, "the reader never reached cell mode");
        repeat (200_000) @(posedge clk);

        // the seek: lands in the cell that holds +SEEK, snapped to its VOBU
        seek_rbn = seek_a;
        @(posedge clk) seek_rbn_pulse = 1;
        @(posedge clk) seek_rbn_pulse = 0;
        t = 0;
        while (!seek_ack && t < 50_000_000) begin @(posedge clk); t = t + 1; end
        if (!seek_ack) $fatal(1, "the seek was never acknowledged");
        repeat (2_000) @(posedge clk);
        for (i = 0; i < cell_count; i = i + 1)
            $fwrite(fo, "C %0d %0d %0d %0d\n", i, dut.cell_first_mem[i], dut.cell_last_mem[i],
                    dut.cell_lv_mem[i]);

        // trick play
        trick_tier = tier_a[1:0];
        trick_rev  = rev_a[0];
        trick_go   = (goper == 0);
        logging    = 1;
        $fwrite(fo, "T %0d\n", dut.cell_i);
        trick_en   = 1;
        t = 0;
        maxv = 0;
        while (n_vobu < vobus && !trick_edge && t < 400_000_000) begin
            @(posedge clk);
            t = t + 1;
            if (goper != 0) begin
                trick_go = (t % goper == 0);
                if (trick_go) begin $fwrite(fo, "G\n"); n_go = n_go + 1; end
                // the gate: never more VOBUs armed than pulses given (+1, the first)
                if (n_vobu > n_go + 1) $fatal(1, "cadence gate broken: %0d VOBUs on %0d pulses", n_vobu, n_go);
            end
        end
        if (trick_edge) begin
            $fwrite(fo, "E\n");
            // The edge HOLDS: trick play still on and the gate open, nothing more may
            // be armed, and once the last VOBU's sectors are in, nothing more read.
            i = n_vobu;
            repeat (1_000_000) @(posedge clk);
            t = n_rd;
            trick_go = 1;
            repeat (2_000_000) @(posedge clk);
            if (n_vobu != i) $fatal(1, "a VOBU was armed past the edge");
            if (n_rd != t) $fatal(1, "%0d sectors read while held at the edge", n_rd - t);
        end
        if (n_vobu == 0) $fatal(1, "no VOBU was armed in trick play");

        // the exit floor: trick_en falls with no seek; the reader must keep reading
        trick_en = 0;
        trick_go = 0;
        repeat (3_000_000) @(posedge clk);
        $fwrite(fo, "X %0d\n", n_after);
        $fclose(fo);
        // Session 2: trick play re-entered partway through a sector (byte 0x500, past
        // the DSI signature at 0x400), with the snoop's registers still holding the
        // last session's NAV pack. Only a sector seen whole may arm.
        sess2 = 1;
        logging = 0;
        @(posedge clk);
        while (!(m == 2 && bc == 12'h500)) @(posedge clk);
        trick_en = 1;
        trick_go = 1;
        t = 0;
        while (n_vobu2 < 2 && t < 50_000_000) begin @(posedge clk); t = t + 1; end
        if (n_vobu2 < 2) $fatal(1, "session 2 armed %0d VOBUs", n_vobu2);
        trick_en = 0;
        $display("trick reader: %0d VOBUs armed, %0d cells crossed, edge %0d, %0d reads after exit",
                 n_vobu, trick_xcell_n, trick_edge, n_after);
        if (n_after == 0) $fatal(1, "the reader stopped reading when trick play ended");
        $display("PASS");
        $finish;
    end
endmodule
