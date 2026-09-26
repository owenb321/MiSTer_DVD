// cdda_audio_tb.sv - end-to-end WAV/CD-DA audio path test:
//   dvd_iso_reader (WAV probe + payload stream) -> dvd_audio_decode cdda port
//   (lpcm_unpack, le byte order, 44.1/48 kHz NCO) -> audio_l/r pairs,
// checked BIT-EXACT against tools/wav_ref.py's .pcm.hex goldens.
//
// Mirrors the emu.sv wiring: stream_valid routes to cdda_wr_* (never the
// demux), reader busy = lpcm afull, sched_en=0 (free-run — no PTS exists).
//
// TEST A: pcm441.wav end-to-end, all 2500 pairs bit-exact + 44.1 kHz NCO
//         cadence (mean aud_ce_play interval ~= 27e6/44100 = 612.2 cycles).
// TEST B: pcm48.wav — fs=1, cadence ~= 562.5 cycles, bit-exact.
// TEST C: pause — no pairs pop while pause=1; the stream resumes bit-exact
//         (sample continuity, no loss) after release.
// TEST D: seek on listchunk (data_off=90): seek to block 1 with the emu-style
//         aud_flush level -> post-seek pairs bit-exact from the pair-aligned
//         resume point (byte 2050) — the channel-swap guard, end to end.
// TEST E: RED-first le proof — the same payload bytes through a bare
//         lpcm_unpack with le=0 must NOT match the golden (they are the
//         byte-swapped values); le=1 must match. Proves the le mux is what
//         makes TEST A pass, not an accident of the fixture.
// (The elapsed/total clock is NOT tested here any more: dvd/cdda_time.sv was
//  retired in the rebase onto the post-v0.5.0 main, which had grown
//  dvd/lin_rate.sv -- one time model shared by every linear source. Its
//  fixed-rate arm covers CD-DA in lin_rate_tb TEST 14.)
`timescale 1ns/1ps

module cdda_audio_tb;

    localparam MAXIMG = 32768;
    localparam MAXP   = 4096;

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

    wire        cdda_mode_w, wav_bad_w;
    wire [1:0]  cdda_fs_w;
    wire        cdda_full_w;

    reg         seek_rbn_pulse = 0;
    reg  [31:0] seek_rbn_r = 0;
    wire        seek_ack_w;
    wire [31:0] lin_blk_w;

    reg  [7:0]  img [0:MAXIMG-1];
    integer     img_n = 0;
    reg  [31:0] gpair [0:MAXP-1];    // golden pairs {L,R}
    integer     gp_n = 0;

    integer meta_fs, meta_doff, meta_npairs;

    // ---------------- DUT 1: reader ----------------
    dvd_iso_reader rdr (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(7'd0), .vbuf_empty(1'b0), 
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_rbn_pulse(seek_rbn_pulse), .seek_rbn(seek_rbn_r), .seek_tm_req(1'b0), .seek_tm_secs(17'd0), .seek_ack(seek_ack_w),
        .flat_seek_en(1'b0), .lin_seek_ok_o(), .lin_blk_o(lin_blk_w),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(cdda_full_w),
        .raw_mode_o(),
        .cdda_mode_o(cdda_mode_w), .cdda_fs_o(cdda_fs_w), .wav_bad_o(wav_bad_w),
        .debug_active(),   
         .debug_iso_mode() 
    );

    // ---------------- DUT 2: audio decode (cdda port) ----------------
    reg pause = 0;
    reg cdda_flush = 0;
    wire signed [15:0] audio_l, audio_r;

    dvd_audio_decode #(.CLK_HZ(27000000), .AUD_HZ(48000)) dec (
        .clk(clk), .rst_n(rst_n), .enable(1'b1), .pause(pause), .aud_soft_switch(1'b0),
        .ring_byte(8'd0), .ring_valid(1'b0), .ring_ready(),
        .frame_valid(1'b0), .frame_len(16'd0), .frame_type(2'd0),
        .lpcm_quant(2'd0),
        .frame_pts(33'd0), .frame_pts_valid(1'b0), .frame_pop(),
        .cdda_mode(cdda_mode_w), .cdda_fs(cdda_fs_w),
        .cdda_wr_en(stream_valid & cdda_mode_w), .cdda_wr_data(stream_data),
        .cdda_flush(cdda_flush), .cdda_full(cdda_full_w),
        .nco_trim(22'sd0), .dispatch_pts(), .dispatch_pts_valid(),
        .sched_en(1'b0), .stc_anchored(1'b0),
        .arr_pts(33'd0), .arr_pts_valid(1'b0), .video_live(1'b0),
        .stc(33'd0), .av_ofs(18'sd0),
        .audio_l(audio_l), .audio_r(audio_r),
        .ac3_synced(), .ac3_err(), .dbg_ac3_resets(), .dbg_ac3_err_resets(),
        .dbg_draining(), .dbg_play_pts_valid(), .dbg_armed_data(), .dbg_skip_run(),
        .dbg_play_pts(), .dbg_rearm_cnt(), .dbg_fbrel_cnt(), .dbg_skip_cnt(),
        .dbg_play_err(), .dbg_cur_codec(), .dbg_mp2_avalid(),
        .dbg_mp2_s_nz(), .dbg_mp2_pcm_nz()
    );


    always #5 clk = ~clk;

    // ---- mock HPS block server (0xEE pad past EOF) ----
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
            sd_ack     <= 1'b0;
            sd_buff_wr <= 1'b0;
            m          <= 0;
        end
        endcase
    end

    // ---- popped-pair capture (hierarchical: the unpacker's pop strobe) ----
    integer cap_n = 0;
    reg [31:0] cap [0:MAXP-1];
    // NCO cadence instrumentation: cycles between pops
    integer pop_cycles = 0, pop_count = 0;
    reg     counting = 0;
    always @(posedge clk) begin
        if (dec.lpcm_aud_valid) begin
            cap[cap_n] = {audio_l_now(), audio_r_now()};
            cap_n = cap_n + 1;
            if (counting) begin pop_count = pop_count + 1; end
        end
        if (counting) pop_cycles = pop_cycles + 1;
    end
    // audio_l/r register one cycle AFTER lpcm_aud_valid; capture the source pair
    function [15:0] audio_l_now; audio_l_now = dec.lpcm_l; endfunction
    function [15:0] audio_r_now; audio_r_now = dec.lpcm_r; endfunction

    // ---- fixture loaders ----
    integer fd, r;
    reg [31:0] v;
    task load_img(input [1023:0] path);
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin $display("FATAL: cannot open %0s", path); $fatal(1); end
            img_n = 0;
            while (!$feof(fd)) begin
                r = $fscanf(fd, "%h\n", v);
                if (r == 1) begin img[img_n] = v[7:0]; img_n = img_n + 1; end
            end
            $fclose(fd);
        end
    endtask
    task load_pairs(input [1023:0] path);
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin $display("FATAL: cannot open %0s", path); $fatal(1); end
            gp_n = 0;
            while (!$feof(fd)) begin
                r = $fscanf(fd, "%h\n", v);
                if (r == 1) begin gpair[gp_n] = v; gp_n = gp_n + 1; end
            end
            $fclose(fd);
        end
    endtask
    task load_meta(input [1023:0] path);
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin $display("FATAL: cannot open meta"); $fatal(1); end
            r = $fscanf(fd, "%d %d %d\n", meta_fs, meta_doff, meta_npairs);
            $fclose(fd);
        end
    endtask

    reg [31:0] red_cap [0:31];
    integer    red_n;
    integer errors = 0;
    integer i, t;

    task mount;
        begin
            rst_n = 0; repeat (6) @(posedge clk); rst_n = 1; @(posedge clk);
            m = 0; cap_n = 0; pop_cycles = 0; pop_count = 0; counting = 0;
            file_size = img_n;
            @(posedge clk);
            start = 1; @(posedge clk); start = 0;
        end
    endtask

    task wait_pairs(input integer want);
        begin
            t = 0;
            while (cap_n < want && t < 60000000) begin @(posedge clk); t = t + 1; end
        end
    endtask

    task check_pairs(input [1023:0] name, input integer from, input integer n);
        begin
            for (i = 0; i < n && i < cap_n; i = i + 1)
                if (cap[i] !== gpair[from + i]) begin
                    errors = errors + 1;
                    if (errors < 10)
                        $display("  %0s MISMATCH pair %0d: got %08x want %08x",
                                 name, i, cap[i], gpair[from + i]);
                end
            if (cap_n < n) begin errors=errors+1; $display("  ERR %0s short: %0d/%0d", name, cap_n, n); end
        end
    endtask

    real mean;
    integer c0;

    initial begin
        // ============ TEST A: pcm441 end-to-end + cadence ============
        load_img("bench/dvd/test_wav/pcm441.wav.hex");
        load_pairs("bench/dvd/test_wav/pcm441.pcm.hex");
        load_meta("bench/dvd/test_wav/pcm441.meta");
        mount;
        wait_pairs(200);           // let startup settle, then measure cadence
        counting = 1; c0 = cap_n;
        wait_pairs(gp_n);
        counting = 0;
        $display("TESTA pcm441: cdda=%b fs=%0d pairs=%0d/%0d", cdda_mode_w, cdda_fs_w, cap_n, gp_n);
        if (cdda_fs_w !== 2'd0) begin errors=errors+1; $display("  ERR fs"); end
        check_pairs("A", 0, gp_n);
        mean = pop_count ? (1.0*pop_cycles)/pop_count : 0.0;
        $display("TESTA cadence: mean %0.2f cycles/pair (expect ~612.24)", mean);
        if (pop_count < 100 || mean < 610.0 || mean > 615.0) begin
            errors=errors+1; $display("  ERR 44.1k cadence");
        end

        // ============ TEST B: pcm48 ============
        load_img("bench/dvd/test_wav/pcm48.wav.hex");
        load_pairs("bench/dvd/test_wav/pcm48.pcm.hex");
        load_meta("bench/dvd/test_wav/pcm48.meta");
        mount;
        wait_pairs(200);
        counting = 1;
        wait_pairs(gp_n);
        counting = 0;
        $display("TESTB pcm48: fs=%0d pairs=%0d/%0d", cdda_fs_w, cap_n, gp_n);
        if (cdda_fs_w !== 2'd1) begin errors=errors+1; $display("  ERR fs"); end
        check_pairs("B", 0, gp_n);
        mean = pop_count ? (1.0*pop_cycles)/pop_count : 0.0;
        $display("TESTB cadence: mean %0.2f cycles/pair (expect ~562.50)", mean);
        if (pop_count < 100 || mean < 560.0 || mean > 565.0) begin
            errors=errors+1; $display("  ERR 48k cadence");
        end

        // ============ TEST C: pause (sample continuity) ============
        load_img("bench/dvd/test_wav/pcm441.wav.hex");
        load_pairs("bench/dvd/test_wav/pcm441.pcm.hex");
        mount;
        wait_pairs(500);
        pause = 1;
        c0 = cap_n;
        repeat (20000) @(posedge clk);           // ~32 pair times
        if (cap_n != c0) begin errors=errors+1; $display("  ERR pairs popped while paused"); end
        pause = 0;
        wait_pairs(gp_n);
        $display("TESTC pause: held at %0d, resumed to %0d/%0d", c0, cap_n, gp_n);
        check_pairs("C", 0, gp_n);               // continuity: nothing lost

        // ============ TEST D: seek + flush (channel-swap guard) ============
        load_img("bench/dvd/test_wav/listchunk.wav.hex");
        load_meta("bench/dvd/test_wav/listchunk.meta");
        mount;
        wait_pairs(300);
        // emu-style: seek pulse; on seek_ack assert the aud_flush level ~64 cyc
        seek_rbn_r = 32'd1;
        seek_rbn_pulse = 1; @(posedge clk); seek_rbn_pulse = 0;
        t = 0;
        while (!seek_ack_w && t < 100000) begin @(posedge clk); t = t + 1; end
        cdda_flush = 1;
        repeat (64) @(posedge clk);
        cdda_flush = 0;
        cap_n = 0;
        begin : seekd
            integer astart, want, base;
            astart = 2048 + (meta_doff % 4);             // 2050
            want   = (meta_npairs*4 - (astart - meta_doff)) / 4;
            wait_pairs(want);
            $display("TESTD seek: pairs=%0d/%0d (astart byte %0d)", cap_n, want, astart);
            if (cap_n < want) begin errors=errors+1; $display("  ERR short post-seek"); end
            for (i = 0; i < want && i < cap_n; i = i + 1) begin
                base = astart + i*4;
                if (cap[i] !== {img[base+1], img[base], img[base+3], img[base+2]}) begin
                    errors = errors + 1;
                    if (errors < 10)
                        $display("  D MISMATCH pair %0d: got %08x want %02x%02x%02x%02x",
                                 i, cap[i], img[base+1], img[base], img[base+3], img[base+2]);
                end
            end
        end

        // ============ TEST E: RED-first le proof (bare unpacker) ============
        begin : red_le_chk
            integer k;
            $display("TESTE le RED proof (bare lpcm_unpack, le=0 vs golden)");
            // le=0 (BE) over LE payload bytes must byte-swap every sample
            red_run(1'b0);
            k = 0;
            for (i = 0; i < 16; i = i + 1)
                if (red_cap[i] === gpair0(i)) k = k + 1;
            if (k == 16) begin errors=errors+1; $display("  ERR le=0 matched golden (test has no teeth)"); end
            // le=1 must match
            red_run(1'b1);
            for (i = 0; i < 16; i = i + 1)
                if (red_cap[i] !== gpair0(i)) begin
                    errors=errors+1;
                    if (errors < 10) $display("  E MISMATCH pair %0d: got %08x want %08x", i, red_cap[i], gpair0(i));
                end
        end


        // =============================================================
        if (errors == 0) $display("CDDA_AUDIO_TB: ALL TESTS PASSED");
        else begin
            $display("CDDA_AUDIO_TB: FAILED with %0d errors", errors);
            $fatal(1);
        end
        $finish;
    end

    // ---- TEST E rig: bare lpcm_unpack fed the pcm441 payload bytes ----
    reg        red_clk = 0;
    reg        red_rst = 1;
    reg        red_le = 0;
    reg        red_wr = 0;
    reg [7:0]  red_wd = 0;
    wire       red_full;
    wire signed [15:0] red_l, red_r;
    wire       red_v;
    reg        red_ce = 0;
    lpcm_unpack #(.FIFO_AW(6)) red_dut (
        .clk(red_clk), .rst(red_rst), .quant(2'd0), .le(red_le),
        .wr_en(red_wr), .wr_data(red_wd), .full(red_full), .afull(),
        .aud_ce(red_ce), .audio_l(red_l), .audio_r(red_r), .aud_valid(red_v)
    );
    always #7 red_clk = ~red_clk;
    always @(posedge red_clk) if (red_v) begin red_cap[red_n] = {red_l, red_r}; red_n = red_n + 1; end

    function [31:0] gpair0(input integer idx); gpair0 = gpair[idx]; endfunction

    task red_run(input le_v);
        integer j;
        begin
            red_rst = 1; red_le = le_v; red_n = 0;
            repeat (4) @(posedge red_clk);
            red_rst = 0; @(posedge red_clk);
            // Feed the first 64 payload bytes (16 pairs) of pcm441 (doff=44).
            // Drive AFTER the edge (+#1) — setting the byte then waiting for the
            // edge races the DUT's own always_ff at that same timestep, which
            // silently duplicates/drops bytes.
            for (j = 0; j < 64; j = j + 1) begin
                @(posedge red_clk); #1;
                red_wr = 1; red_wd = img_pcm441(44 + j);
            end
            @(posedge red_clk); #1; red_wr = 0;
            // pop 16 pairs
            for (j = 0; j < 20; j = j + 1) begin
                @(posedge red_clk); #1; red_ce = 1;
                @(posedge red_clk); #1; red_ce = 0;
                repeat (2) @(posedge red_clk);
            end
        end
    endtask
    // pcm441 payload byte accessor: TEST E runs after other fixtures loaded
    // into img[], so keep a private copy latched at TEST A load time
    reg [7:0] p441 [0:255];
    integer   p441_ok = 0;
    function [7:0] img_pcm441(input integer idx); img_pcm441 = p441[idx - 44]; endfunction
    initial begin : keep441
        // snapshot the first 256 payload-adjacent bytes after TEST A's load
        wait (img_n > 0);
        repeat (10) @(posedge clk);
        for (int kk = 0; kk < 256; kk = kk + 1) p441[kk] = img[44 + kk];
        p441_ok = 1;
    end

    // global watchdog
    initial begin
        #900000000;
        $display("CDDA_AUDIO_TB: TIMEOUT");
        $fatal(1);
    end

endmodule
