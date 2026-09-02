// wav_probe_tb.sv - RIFF/WAVE (CD-DA/WAV mode) probe + streaming test for
// dvd/dvd_iso_reader.sv. Golden model: tools/wav_ref.py (fixtures generated
// into bench/dvd/test_wav/ by `python3 tools/wav_ref.py gen bench/dvd/test_wav`
// — run_wav.sh does this).
//
// TEST 1: pcm441.wav    canonical 44-byte header, 44.1 kHz, partial final
//                       block — cdda_mode=1, fs=0, streamed bytes == the data
//                       payload byte-exactly (header never emitted).
// TEST 2: pcm48.wav     canonical, 48 kHz — fs=1.
// TEST 3: listchunk.wav LIST+fact chunks before data (chunk walker).
// TEST 4: oddchunk.wav  odd-cksize chunk (RIFF pad rule) + trailing id3 AFTER
//                       the data chunk — the trailing bytes must never stream.
// TEST 5: all five reject fixtures — wav_bad=1, cdda_mode=0, ZERO bytes out.
// TEST 6: flat regressions — a non-RIFF ramp streams unchanged (large and,
//                       new with this feature, SMALL <17-block files, which
//                       used to skip the byte-0 probe entirely).
// TEST 7: seeks on listchunk (data_off=90, off mod 4 = 2 — the interesting
//                       pair phase): block-1 seek resumes at the first
//                       pair-aligned byte (2048 + (90 mod 4) = 2050), block-0
//                       seek replays the full payload; byte-exact both ways
//                       (also proves the flat-PS pack hunt never arms).
`timescale 1ns/1ps

module wav_probe_tb;

    localparam MAXIMG = 65536;

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

    wire        raw_mode_o, cdda_mode_o, wav_bad_o;
    wire [1:0]  cdda_fs_o;

    reg  [7:0]  img [0:MAXIMG-1];
    integer     img_n = 0;

    reg  [7:0]  gold [0:MAXIMG-1];
    integer     gold_n = 0;

    // ---- capture ----
    integer cap_n = 0;
    reg [7:0] cap [0:MAXIMG-1];
    always @(posedge clk)
        if (stream_valid) begin
            cap[cap_n] = stream_data;
            cap_n = cap_n + 1;
        end

    reg         seek_rbn_pulse = 0;
    reg  [31:0] seek_rbn_r = 0;
    reg         flat_seek_en = 0;
    wire        lin_seek_ok_o;
    wire [31:0] lin_blk_o;
    wire        seek_ack_w;

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_rbn_pulse(seek_rbn_pulse), .seek_rbn(seek_rbn_r), .seek_ack(seek_ack_w),
        .flat_seek_en(flat_seek_en), .lin_seek_ok_o(lin_seek_ok_o), .lin_blk_o(lin_blk_o),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .raw_mode_o(raw_mode_o),
        .cdda_mode_o(cdda_mode_o), .cdda_fs_o(cdda_fs_o), .wav_bad_o(wav_bad_o),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(), .debug_iso_error()
    );

    always #5 clk = ~clk;

    // ---- mock HPS: serve one 2048-byte block per sd_rd; bytes past the
    //      image end are 0xEE (framework pad model) ----
    integer m = 0;
    integer bc = 0;
    reg [31:0] rlba = 0;
    integer lat = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin
            sd_ack <= 1'b0;
            if (sd_rd) begin rlba <= sd_lba; lat <= 3; m <= 1; end
        end
        1: begin
            if (lat != 0) lat <= lat - 1;
            else begin sd_ack <= 1'b1; bc <= 0; m <= 2; end
        end
        2: begin
            sd_ack       <= 1'b1;
            sd_buff_wr   <= 1'b1;
            sd_buff_addr <= bc[13:0];
            sd_buff_dout <= (rlba*2048 + bc < img_n) ? img[rlba*2048 + bc] : 8'hEE;
            bc           <= bc + 1;
            if (bc == 2047) m <= 3;
        end
        3: begin
            sd_ack     <= 1'b0;   // falling edge -> block done
            sd_buff_wr <= 1'b0;
            m          <= 0;
        end
        endcase
    end

    // ---- fixture loaders ----
    integer fd, r;
    reg [31:0] v;
    task load_img(input [1023:0] path);
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin $display("FATAL: cannot open fixture %0s", path); $fatal(1); end
            img_n = 0;
            while (!$feof(fd)) begin
                r = $fscanf(fd, "%h\n", v);
                if (r == 1) begin img[img_n] = v[7:0]; img_n = img_n + 1; end
            end
            $fclose(fd);
        end
    endtask
    // .meta = "<fs_code> <data_off> <npairs>"
    integer meta_fs, meta_doff, meta_npairs;
    task load_meta(input [1023:0] path);
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin $display("FATAL: cannot open meta %0s", path); $fatal(1); end
            r = $fscanf(fd, "%d %d %d\n", meta_fs, meta_doff, meta_npairs);
            if (r != 3) begin $display("FATAL: bad meta"); $fatal(1); end
            $fclose(fd);
        end
    endtask
    // ---- checks ----
    integer errors = 0;
    integer i, t;

    // expected stream = the pair-truncated data payload (from img + meta)
    task gold_from_meta;
        begin
            gold_n = meta_npairs * 4;
            for (i = 0; i < gold_n; i = i + 1) gold[i] = img[meta_doff + i];
        end
    endtask

    task do_seek;
        begin
            seek_rbn_pulse = 1; @(posedge clk); seek_rbn_pulse = 0;
            t = 0;
            while (!seek_ack_w && t < 100000) begin @(posedge clk); t = t + 1; end
            if (!seek_ack_w && t >= 100000) begin
                errors = errors + 1; $display("  ERR seek never acked");
            end
            repeat (10) @(posedge clk);
            cap_n = 0;
        end
    endtask

    task mount;
        begin
            rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
            m = 0; cap_n = 0;
            file_size = img_n;
            @(posedge clk);
            start = 1; @(posedge clk); start = 0;
        end
    endtask

    // run a case whose expected output is gold[0..gold_n)
    task run_case(input [1023:0] name, input integer exp_cdda,
                  input integer exp_fs);
        begin
            mount;
            t = 0;
            while (cap_n < gold_n && t < 10000000) begin @(posedge clk); t = t + 1; end
            repeat (4000) @(posedge clk);   // let spurious extra bytes surface
            $display("%0s: cdda=%b fs=%0d bad=%b cap_n=%0d (expect %0d)",
                     name, cdda_mode_o, cdda_fs_o, wav_bad_o, cap_n, gold_n);
            if (cdda_mode_o !== exp_cdda[0]) begin errors=errors+1; $display("  ERR cdda_mode"); end
            if (exp_cdda[0] && cdda_fs_o !== exp_fs[1:0]) begin errors=errors+1; $display("  ERR cdda_fs"); end
            if (wav_bad_o !== 1'b0) begin errors=errors+1; $display("  ERR wav_bad set on accept path"); end
            if (cap_n != gold_n) begin errors=errors+1; $display("  ERR output length"); end
            for (i = 0; i < gold_n && i < cap_n; i = i + 1)
                if (cap[i] !== gold[i]) begin
                    errors = errors + 1;
                    if (errors < 10)
                        $display("  MISMATCH @%0d: got %02x want %02x", i, cap[i], gold[i]);
                end
        end
    endtask

    task run_reject(input [1023:0] name);
        begin
            mount;
            repeat (30000) @(posedge clk);
            $display("%0s: cdda=%b bad=%b cap_n=%0d", name, cdda_mode_o, wav_bad_o, cap_n);
            if (wav_bad_o !== 1'b1) begin errors=errors+1; $display("  ERR wav_bad not set"); end
            if (cdda_mode_o !== 1'b0) begin errors=errors+1; $display("  ERR cdda_mode set on reject"); end
            if (cap_n != 0) begin errors=errors+1; $display("  ERR bytes streamed on reject"); end
        end
    endtask

    initial begin
        // ============= TEST 1: canonical 44.1 kHz =============
        load_img("bench/dvd/test_wav/pcm441.wav.hex");
        load_meta("bench/dvd/test_wav/pcm441.meta");
        gold_from_meta;
        run_case("TEST1 pcm441", 1, 0);

        // ============= TEST 2: canonical 48 kHz =============
        load_img("bench/dvd/test_wav/pcm48.wav.hex");
        load_meta("bench/dvd/test_wav/pcm48.meta");
        gold_from_meta;
        run_case("TEST2 pcm48", 1, 1);

        // ============= TEST 3: LIST/fact chunks before data =============
        load_img("bench/dvd/test_wav/listchunk.wav.hex");
        load_meta("bench/dvd/test_wav/listchunk.meta");
        gold_from_meta;
        run_case("TEST3 listchunk", 1, 0);

        // ============= TEST 4: odd chunk + trailing id3 =============
        load_img("bench/dvd/test_wav/oddchunk.wav.hex");
        load_meta("bench/dvd/test_wav/oddchunk.meta");
        gold_from_meta;
        run_case("TEST4 oddchunk", 1, 0);

        // ============= TEST 5: rejects =============
        load_img("bench/dvd/test_wav/rej_mono.wav.hex");     run_reject("TEST5a rej_mono");
        load_img("bench/dvd/test_wav/rej_24bit.wav.hex");    run_reject("TEST5b rej_24bit");
        load_img("bench/dvd/test_wav/rej_float.wav.hex");    run_reject("TEST5c rej_float");
        load_img("bench/dvd/test_wav/rej_96k.wav.hex");      run_reject("TEST5d rej_96k");
        load_img("bench/dvd/test_wav/rej_latedata.wav.hex"); run_reject("TEST5e rej_latedata");

        // ============= TEST 6: flat regressions =============
        // large ramp (>17 blocks): unchanged flat path
        img_n = 40960;
        for (i = 0; i < img_n; i = i + 1) img[i] = i[7:0] ^ i[13:8];
        gold_n = img_n;
        for (i = 0; i < gold_n; i = i + 1) gold[i] = img[i];
        run_case("TEST6a flat-large", 0, 0);
        // small ramp (<17 blocks): used to skip the probe; must still stream
        img_n = 10240;
        for (i = 0; i < img_n; i = i + 1) img[i] = i[7:0] + 8'd7;
        gold_n = img_n;
        for (i = 0; i < gold_n; i = i + 1) gold[i] = img[i];
        run_case("TEST6b flat-small", 0, 0);

        // ============= TEST 7: seeks on listchunk (data_off=90) =============
        load_img("bench/dvd/test_wav/listchunk.wav.hex");
        load_meta("bench/dvd/test_wav/listchunk.meta");
        gold_from_meta;
        run_case("TEST7 pre-seek", 1, 0);
        if (lin_seek_ok_o !== 1'b1) begin errors=errors+1; $display("  ERR lin_seek_ok"); end
        // block-1 seek: resume at byte 2048 + (data_off mod 4) = 2050
        begin : seek_blk1
            integer astart, want;
            astart = 2048 + (meta_doff % 4);
            want   = meta_npairs*4 - (astart - meta_doff);
            seek_rbn_r = 32'd1; do_seek;
            t = 0;
            while (cap_n < want && t < 10000000) begin @(posedge clk); t = t + 1; end
            repeat (4000) @(posedge clk);
            $display("TEST7 blk1 seek: cap_n=%0d (expect %0d, astart=%0d)", cap_n, want, astart);
            if (cap_n != want) begin errors=errors+1; $display("  ERR post-seek length"); end
            if (((astart - meta_doff) % 4) != 0) begin errors=errors+1; $display("  ERR astart not pair-aligned"); end
            for (i = 0; i < want && i < cap_n; i = i + 1)
                if (cap[i] !== img[astart + i]) begin
                    errors = errors + 1;
                    if (errors < 10)
                        $display("  SEEK MISMATCH @%0d: got %02x want %02x", i, cap[i], img[astart+i]);
                end
        end
        // block-0 seek: full payload again (header still never emitted)
        seek_rbn_r = 32'd0; do_seek;
        t = 0;
        while (cap_n < gold_n && t < 10000000) begin @(posedge clk); t = t + 1; end
        repeat (4000) @(posedge clk);
        $display("TEST7 blk0 seek: cap_n=%0d (expect %0d)", cap_n, gold_n);
        if (cap_n != gold_n) begin errors=errors+1; $display("  ERR blk0 post-seek length"); end
        for (i = 0; i < gold_n && i < cap_n; i = i + 1)
            if (cap[i] !== gold[i]) begin
                errors = errors + 1;
                if (errors < 10)
                    $display("  SEEK0 MISMATCH @%0d: got %02x want %02x", i, cap[i], gold[i]);
            end

        // =============================================================
        if (errors == 0) $display("WAV_PROBE_TB: ALL TESTS PASSED");
        else begin
            $display("WAV_PROBE_TB: FAILED with %0d errors", errors);
            $fatal(1);
        end
        $finish;
    end

    // global watchdog
    initial begin
        #400000000;
        $display("WAV_PROBE_TB: TIMEOUT");
        $fatal(1);
    end

endmodule
