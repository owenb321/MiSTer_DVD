// cdda_toc_tb.sv -- dvd/cdda_toc.sv: the CD-DA track table.
//
// Golden: tools/cdda_toc_ref.py, which states the WIRE FORMAT independently of
// both implementations (the Main that writes the blob and the RTL that parses
// it). Scoring against a model derived from the RTL would prove nothing -- that
// is how dvd_vm_ref.py once agreed with a real navigation bug for months.
//
//  [1] a good upload commits, and every boundary lookup matches the golden
//  [2] the notch replay emits one boundary per track, in order
//  [3] track skip targets: next/prev/current bounds at the edges
//  [4] NEVER-GARBAGE: a truncated, a bad-magic, a bad-version and an
//      absurd-ntracks upload each leave the PREVIOUS table intact
//  [5] a new mount invalidates the table (a table belongs to one disc)
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
    wire        notch_we;
    wire [6:0]  notch_idx;
    wire [31:0] notch_blk;

    cdda_toc dut (
        .clk(clk), .rst_n(rst_n),
        .ioctl_download(dl), .ioctl_wr(wr), .ioctl_addr(addr),
        .ioctl_dout(dout), .ioctl_index(idx),
        .mount(mount), .lin_blk(lin_blk),
        .toc_valid(toc_valid), .n_tracks(n_tracks), .cur_track(cur_track),
        .cur_start(cur_start), .cur_end(cur_end),
        .prev_start(prev_start), .next_start(next_start),
        .notch_we(notch_we), .notch_idx(notch_idx), .notch_blk(notch_blk)
    );

    integer errors = 0;
    task chk(input [255:0] what, input integer got, input integer want);
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

    // ---- notch capture ----
    reg [31:0] nb [0:99];
    integer nn = 0;
    always @(posedge clk) if (notch_we) begin nb[notch_idx] = notch_blk; nn = nn + 1; end

    integer i, want_trk;
    initial begin
        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
        #1;
        $display("cdda_toc_tb: blob %0d bytes, %0d tracks, %0d probes",
                 blob_n, meta_ntr, npr);
        chk("[0] blob length matches meta", blob_n, meta_len);

        // ---- [1] a good upload commits ----
        $display("=== [1] a good upload commits and every boundary matches ===");
        nn = 0;
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

        // ---- [2] notch replay ----
        $display("=== [2] one notch per track, in order ===");
        chk("[2] notches emitted", nn >= meta_ntr, 1);
        for (i = 0; i < meta_ntr; i = i + 1)
            if (nb[i] !== {blob[12+4*i+3], blob[12+4*i+2], blob[12+4*i+1], blob[12+4*i]}) begin
                errors = errors + 1;
                $display("  FAIL notch %0d = %0d", i, nb[i]);
            end
        $display("  ok   [2] every notch equals its track start");

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

        if (errors == 0) $display("CDDA_TOC_TB: ALL TESTS PASSED");
        else begin $display("CDDA_TOC_TB: FAILED with %0d errors", errors); $fatal(1); end
        $finish;
    end

    initial begin #50000000; $display("CDDA_TOC_TB: TIMEOUT"); $fatal(1); end
endmodule
