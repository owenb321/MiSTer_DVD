// cdda_toc_tb.sv -- dvd/cdda_toc.sv: the CD-DA track table.
//
// Golden: tools/cdda_toc_ref.py, which states the WIRE FORMAT independently of
// both implementations (the Main that writes the blob and the RTL that parses
// it). Scoring against a model derived from the RTL would prove nothing -- that
// is how dvd_vm_ref.py once agreed with a real navigation bug for months.
//
//  [1] a good upload commits, and every boundary lookup matches the golden
//  [2] (retired 2026-09-10 with the seek-bar notches -- the replay is gone)
//  [3] track skip targets: next/prev/current bounds at the edges
//  [4] NEVER-GARBAGE: a truncated, a bad-magic, a bad-version and an
//      absurd-ntracks upload each leave the PREVIOUS table intact
//  [5] a new mount invalidates the table (a table belongs to one disc)
//  [6] where a single skip lands (next / prev-restart / prev / both ends)
//  [7] a BURST stacks: N presses move N tracks, with the same restart rule
`timescale 1ns/1ps

module cdda_toc_tb;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg         dl = 0, wr = 0;
    reg [26:0]  addr = 0;
    reg  [7:0]  dout = 0;
    reg [15:0]  idx = 16'd250;
    reg         mount = 0;
    reg [31:0]  lin_blk = 0;

    wire        toc_valid;
    wire [7:0]  n_tracks, cur_track;
    wire [31:0] cur_start, cur_end, prev_start, next_start;
    reg         skip_req = 0, skip_fwd = 0;
    reg  [4:0]  skip_mag = 5'd1;
    wire        past_start;
    wire        skip_fire;
    wire [31:0] skip_tgt;

    cdda_toc dut (
        .clk(clk), .rst_n(rst_n),
        .ioctl_download(dl), .ioctl_wr(wr), .ioctl_addr(addr),
        .ioctl_dout(dout), .ioctl_index(idx),
        .mount(mount), .lin_blk(lin_blk),
        .toc_valid(toc_valid), .n_tracks(n_tracks), .cur_track(cur_track),
        .cur_start(cur_start), .cur_end(cur_end),
        .prev_start(prev_start), .next_start(next_start),
        .skip_req(skip_req), .skip_fwd(skip_fwd),
        .skip_mag(skip_mag), .past_start(past_start),
        .skip_fire(skip_fire), .skip_tgt(skip_tgt)
    );

    integer errors = 0;
    task chk(input [8*72-1:0] what, input integer got, input integer want);
        if (got !== want) begin
            errors = errors + 1;
            $display("  FAIL %0s: got %0d want %0d", what, got, want);
        end else $display("  ok   %0s = %0d", what, got);
    endtask

    // ---- the golden blob + probes ----
    localparam MAXB = 512;
    reg [7:0] blob [0:MAXB-1];
    integer blob_n = 0;
    reg [31:0] pr_blk [0:63];
    reg [7:0]  pr_trk [0:63];
    integer npr = 0;
    integer meta_ntr, meta_total, meta_len, meta_npr;

    integer fd, r; reg [31:0] v, v2;
    initial begin : load
        fd = $fopen("bench/dvd/test_cdda/toc.hex", "r");
        if (!fd) begin $display("FATAL: run tools/cdda_toc_ref.py first"); $fatal(1); end
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h\n", v);
            if (r == 1) begin blob[blob_n] = v[7:0]; blob_n = blob_n + 1; end
        end
        $fclose(fd);
        fd = $fopen("bench/dvd/test_cdda/probes.hex", "r");
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %h\n", v, v2);
            if (r == 2) begin pr_blk[npr] = v; pr_trk[npr] = v2[7:0]; npr = npr + 1; end
        end
        $fclose(fd);
        fd = $fopen("bench/dvd/test_cdda/toc.meta", "r");
        r = $fscanf(fd, "%d %d %d %d\n", meta_ntr, meta_total, meta_len, meta_npr);
        $fclose(fd);
    end

    // ⚠ The malformed-upload arms MUST carry DIFFERENT data from the good one.
    // The first version of this bench sent the SAME blob with one byte broken and
    // then asserted "n_tracks unchanged" -- which passes whether the upload was
    // rejected or accepted, because accepting it would have written back the very
    // same 4. Two mutations (no length check, no magic check) survived that bench.
    // alt[] therefore says ntracks=3 with every track start shifted, so a wrongly
    // accepted upload is visible in both n_tracks and a lookup.
    reg [7:0] alt [0:MAXB-1];
    integer   alt_len;        // the length alt's OWN header implies: 12 + 4*3
    task build_alt;
        integer i;
        begin
            for (i = 0; i < blob_n; i = i + 1) alt[i] = blob[i];
            alt[5] = 8'd3;                       // ntracks 4 -> 3
            for (i = 0; i < 4; i = i + 1)        // shift every start by +4096
                alt[12 + 4*i + 1] = blob[12 + 4*i + 1] + 8'd16;
            alt_len = 12 + 4 * 3;                // what alt's own header implies
        end
    endtask

    // send `n` bytes of a blob (0 = good, 1 = alt), optionally corrupting one
    task upload_src(input integer src, input integer n, input integer bad_at,
                    input [7:0] bad_val, input [15:0] use_idx);
        integer i;
        begin
            idx = use_idx;
            @(negedge clk); dl = 1;
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                wr = 1; addr = i[26:0];
                dout = (bad_at == i) ? bad_val : (src ? alt[i] : blob[i]);
                @(negedge clk); wr = 0;
            end
            @(negedge clk); dl = 0;
            repeat (8) @(posedge clk);
        end
    endtask

    // send `n` bytes of the blob, optionally corrupting one
    task upload(input integer n, input integer bad_at, input [7:0] bad_val,
                input [15:0] use_idx);
        integer i;
        begin
            idx = use_idx;
            @(negedge clk); dl = 1;
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                wr = 1; addr = i[26:0];
                dout = (bad_at == i) ? bad_val : blob[i];
                @(negedge clk); wr = 0;
            end
            @(negedge clk); dl = 0;
            repeat (8) @(posedge clk);
        end
    endtask

    // let the one-track-per-clock scan settle on a new position
    task settle; repeat (300) @(posedge clk); endtask

    reg skip_fire_seen = 0;
    always @(posedge clk) if (skip_fire) skip_fire_seen <= 1'b1;

    // one debounced burst, and wait for the resolved target
    // A skip may wait for the table walk to reach its entry (one sync read port),
    // so wait up to ~two sweeps -- a fixed 4-cycle wait would miss real fires.
    task do_burst(input fwd, input [4:0] mag);
        integer k;
        begin
            skip_fwd = fwd;
            skip_mag = mag;
            skip_fire_seen = 0;          // ⚠ per-arm: a stale flag would let a
                                         // silent no-fire pass on the next arm
            @(negedge clk); skip_req = 1; @(negedge clk); skip_req = 0;
            for (k = 0; k < 400 && !skip_fire_seen; k = k + 1) @(posedge clk);
            if (!skip_fire_seen) begin
                errors = errors + 1; $display("  FAIL skip did not fire");
            end
        end
    endtask
    task do_skip(input fwd); do_burst(fwd, 5'd1); endtask


    integer i, want_trk;
    initial begin
        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
        #1;
        $display("cdda_toc_tb: blob %0d bytes, %0d tracks, %0d probes",
                 blob_n, meta_ntr, npr);
        chk("[0] blob length matches meta", blob_n, meta_len);

        // ---- [1] a good upload commits ----
        $display("=== [1] a good upload commits and every boundary matches ===");
        upload(blob_n, -1, 8'd0, 16'd250);
        chk("[1] toc_valid", toc_valid, 1);
        chk("[1] n_tracks",  n_tracks,  meta_ntr);

        for (i = 0; i < npr; i = i + 1) begin
            lin_blk = pr_blk[i];
            settle;
            want_trk = pr_trk[i];
            if (cur_track !== want_trk[7:0]) begin
                errors = errors + 1;
                $display("  FAIL blk %0d: track %0d want %0d", pr_blk[i], cur_track, want_trk);
            end
        end
        $display("  ok   [1] %0d boundary lookups all match the golden", npr);

        // ---- [3] skip targets ----
        $display("=== [3] track-skip targets ===");
        lin_blk = pr_blk[0]; settle;                     // inside track 1
        chk("[3a] on track 1, prev == track 1 start", prev_start, cur_start);
        lin_blk = {blob[12+4*2+3], blob[12+4*2+2], blob[12+4*2+1], blob[12+4*2]};
        settle;                                          // start of track 3
        chk("[3b] track 3 detected", cur_track, 3);
        chk("[3c] next == track 4 start", next_start,
            {blob[12+4*3+3], blob[12+4*3+2], blob[12+4*3+1], blob[12+4*3]});
        chk("[3d] prev == track 2 start", prev_start,
            {blob[12+4*1+3], blob[12+4*1+2], blob[12+4*1+1], blob[12+4*1]});
        chk("[3e] cur_start == track 3 start", cur_start, lin_blk);
        lin_blk = meta_total - 1; settle;                 // last block
        chk("[3f] last block is the last track", cur_track, meta_ntr);
        chk("[3g] next on the last track clamps to the end", next_start, meta_total);

        // ---- [4] never-garbage ----
        $display("=== [4] a malformed upload must not disturb a good table ===");
        build_alt;
        // ⚠ EACH ARM MUST BREAK EXACTLY ONE RULE, and be the right LENGTH for the
        // ntracks its own header declares -- otherwise the length check rejects it
        // for the wrong reason and the arm proves nothing about the rule it names.
        // An earlier version got that wrong: `alt` declares 3 tracks, so its
        // "truncated" 24-byte upload was a perfectly VALID 3-track table, which
        // committed and cascaded into every later check.
        //
        // The assertion is INVALIDATION, not preservation. The entry RAM is
        // written as bytes arrive, so a failed upload cannot leave the old table
        // intact -- it must leave NO table. (That is the defect this arm found:
        // the module used to keep toc_valid set while the starts underneath it
        // had already been overwritten.)
        upload_src(1, alt_len - 4, -1, 8'd0, 16'd250);    // genuinely short
        chk("[4a] truncated -> no table", toc_valid, 0);
        upload_src(0, blob_n, -1, 8'd0, 16'd250);         // a good one restores it
        chk("[4a] good upload restores",  toc_valid, 1);
        chk("[4a] ...with the right count", n_tracks, meta_ntr);

        upload_src(1, alt_len, 0, 8'h58, 16'd250);        // right length, magic 'X'
        chk("[4b] bad magic -> no table", toc_valid, 0);
        upload_src(0, blob_n, -1, 8'd0, 16'd250);
        upload_src(1, alt_len, 4, 8'd9, 16'd250);         // right length, version 9
        chk("[4c] bad version -> no table", toc_valid, 0);
        upload_src(0, blob_n, -1, 8'd0, 16'd250);
        upload_src(1, 27'd12, 5, 8'd0, 16'd250);          // ntracks 0
        chk("[4d] zero ntracks -> no table", toc_valid, 0);
        upload_src(0, blob_n, -1, 8'd0, 16'd250);

        // A download at SOMEONE ELSE'S index must not touch us at all -- not the
        // table, and not even the validity.
        upload_src(1, alt_len, -1, 8'd0, 16'd7);
        chk("[4e] wrong ioctl index: untouched", toc_valid, 1);
        chk("[4e] ...count intact",              n_tracks, meta_ntr);
        // ...and the CONTENT is still the good table: alt's starts are shifted,
        // so a wrongly accepted upload would move this lookup.
        lin_blk = {blob[12+4*2+3], blob[12+4*2+2], blob[12+4*2+1], blob[12+4*2]};
        settle;
        chk("[4g] lookup still uses the GOOD starts", cur_track, 3);

        // ---- [5] a mount invalidates ----
        $display("=== [5] a new disc invalidates the table ===");
        @(negedge clk); mount = 1; @(negedge clk); mount = 0;
        repeat (4) @(posedge clk);
        chk("[5] toc_valid cleared", toc_valid, 0);
        chk("[5] cur_track cleared", cur_track, 0);

        // ---- [6] WHERE DOES A SKIP LAND? --------------------------------
        // This is the question the hardware round could not answer -- the drive
        // dropped the disc mid-test -- and it is the one a bench answers best,
        // because "the audio changed" does not tell you WHICH block you reached.
        $display("=== [6] track-skip targets ===");
        // ⚠ [5] deliberately invalidated the table, so re-upload before asking
        // where a skip lands -- otherwise every arm here measures "no table"
        // and passes for the wrong reason.
        upload_src(0, blob_n, -1, 8'd0, 16'd250);
        chk("[6] table reloaded", toc_valid, 1);
        begin : skip_arms
            integer t2, t3, t4;
            t2 = {blob[12+4*1+3], blob[12+4*1+2], blob[12+4*1+1], blob[12+4*1]};
            t3 = {blob[12+4*2+3], blob[12+4*2+2], blob[12+4*2+1], blob[12+4*2]};
            t4 = {blob[12+4*3+3], blob[12+4*3+2], blob[12+4*3+1], blob[12+4*3]};

            // mid-track 2 -> NEXT lands exactly on track 3's first block
            lin_blk = t2 + 5000; settle;
            do_skip(1'b1);
            chk("[6a] next -> track 3", skip_tgt, t3);

            // ...and PREVIOUS from there RESTARTS track 2 (we are >3 s in)
            do_skip(1'b0);
            chk("[6b] prev -> restart", skip_tgt, t2);

            // but within ~3 s of the start, PREVIOUS goes to the track before --
            // so a double-press reaches it, exactly like a CD player.
            lin_blk = t3 + 100; settle;
            do_skip(1'b0);
            chk("[6c] prev near start -> prev trk", skip_tgt, t2);

            // the very first track has nothing before it: clamp to its own start
            lin_blk = 32'd50; settle;
            do_skip(1'b0);
            chk("[6d] prev on trk 1", skip_tgt, 0);

            // and NEXT on the last track clamps to the image end rather than
            // running off the table
            lin_blk = t4 + 100; settle;
            do_skip(1'b1);
            chk("[6e] next on last -> end", skip_tgt, meta_total);

            // ---- [7] A BURST OF PRESSES STACKS (user report 2026-09-11) ----
            // Each arm starts on a DIFFERENT track from the answer a single
            // press would give, so an implementation that ignores skip_mag
            // lands somewhere else and fails.
            $display("=== [7] a burst stacks, like DVD chapter skips ===");
            lin_blk = 32'd5000; settle;                        // mid-track 1
            do_burst(1'b1, 5'd3);
            chk("[7a] next x3 from track 1 -> track 4", skip_tgt, t4);
            lin_blk = t3 + 5000; settle;                       // track 3, past start
            do_burst(1'b0, 5'd2);
            chk("[7b] prev x2 mid-track 3 -> track 2 (restart counts)", skip_tgt, t2);
            lin_blk = t4 + 100; settle;                        // track 4, at start
            do_burst(1'b0, 5'd2);
            chk("[7c] prev x2 at start of 4 -> track 2", skip_tgt, t2);
            lin_blk = t2 + 5000; settle;
            do_burst(1'b1, 5'd9);
            chk("[7d] next x9 past the last -> disc end", skip_tgt, meta_total);
            lin_blk = t3 + 100; settle;
            do_burst(1'b0, 5'd9);
            chk("[7e] prev x9 past the first -> track 1", skip_tgt, 0);
            // the exported verdict emu's HUD projection reads
            lin_blk = t3 + 100;  settle; chk("[7f] past_start at a track start", past_start, 0);
            lin_blk = t3 + 5000; settle; chk("[7g] past_start mid-track", past_start, 1);

            // a skip with no table must not fire at all
            @(negedge clk); mount = 1; @(negedge clk); mount = 0;
            repeat (4) @(posedge clk);
            // ⚠ Watch the LATCH, not the wire: skip_fire is a one-cycle pulse,
            // so sampling it a few cycles later reads 0 whether or not it fired
            // -- a check that cannot fail. (A mutation that fired a skip with no
            // table passed against exactly that mistake.)
            skip_fire_seen = 0;
            skip_req = 1; @(negedge clk); skip_req = 0;
            repeat (400) @(posedge clk);   // as long as a real fire may take
            chk("[6f] no table, no skip", skip_fire_seen, 0);
        end

        if (errors == 0) $display("CDDA_TOC_TB: ALL TESTS PASSED");
        else begin $display("CDDA_TOC_TB: FAILED with %0d errors", errors); $fatal(1); end
        $finish;
    end

    initial begin #50000000; $display("CDDA_TOC_TB: TIMEOUT"); $fatal(1); end
endmodule
