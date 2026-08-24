// iso_reader_raw_tb.sv - raw MODE2/2352 (VCD/SVCD .bin) mode test for
// dvd/dvd_iso_reader.sv.
//
// The mock HPS serves 2048-byte blocks straight out of a raw-sector image, so
// CD sectors straddle block boundaries exactly as on hardware (2352 > 2048).
// The reader must detect the sync signature at file byte 0, enter raw mode,
// and stream ONLY the Mode-2 Form-2 payload windows [24, 2348) — byte-exact
// against the tools/cd_deblock_ref.py goldens.
//
// TEST 1: real VCD track-head slice (vcd_head.hex: pregap Form-2 zero-payload
//         sectors + the pregap->data transition + first MPEG packs).
// TEST 2: real VCD mid-stream slice (vcd_mid.hex: video+audio sectors) —
//         output must equal vcd_mid.golden.hex (a flat MPEG-1 system stream).
// TEST 3: synthetic SVCD slice (svcd_slice.hex: 4 Form-1 decoy sectors + an
//         MPEG-2 PS in Form-2 sectors) — the Form-1 sectors must be SKIPPED
//         (golden equals the wrapped PS exactly).
// TEST 4: DVD regression guard: a flat non-raw file must stream through the
//         unchanged +BLK path (raw_mode stays 0, byte-identical passthrough).
// TEST 5: EOF partial block: a raw image whose size is not a 2048 multiple
//         (the natural case: 2352-multiples aren't 2048-multiples) — the mock
//         pads the final block with 0xEE; the walk must never emit pad bytes
//         beyond the last full sector's window.
//
// Regenerate fixtures: VCD_TRACK_BIN=<track2.bin> tools/vcd_fixtures.py
`timescale 1ns/1ps

module iso_reader_raw_tb;

    localparam MAXIMG = 524288;   // bytes (raw fixtures are ~150-470 KB)

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

    wire        debug_iso_mode, debug_iso_error;
    wire        raw_mode_o;

    reg  [7:0]  img [0:MAXIMG-1];
    integer     img_n = 0;

    // ---- golden (deblocked) ----
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

    // ---------------------------------------------------------------
    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .raw_mode_o(raw_mode_o),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(debug_iso_mode),
        .debug_iso_error(debug_iso_error)
    );

    always #5 clk = ~clk;

    // ---- mock HPS: serve one 2048-byte block per sd_rd; bytes past the
    //      image end are 0xEE (framework pad model for TEST 5) ----
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

    // ---- fixture loader (line-counted hex, one byte per line) ----
    integer fd, r;
    reg [31:0] v;
    task load_img(input [1023:0] path);
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin $display("FATAL: cannot open fixture"); $fatal(1); end
            img_n = 0;
            while (!$feof(fd)) begin
                r = $fscanf(fd, "%h\n", v);
                if (r == 1) begin img[img_n] = v[7:0]; img_n = img_n + 1; end
            end
            $fclose(fd);
        end
    endtask
    task load_gold(input [1023:0] path);
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin $display("FATAL: cannot open golden"); $fatal(1); end
            gold_n = 0;
            while (!$feof(fd)) begin
                r = $fscanf(fd, "%h\n", v);
                if (r == 1) begin gold[gold_n] = v[7:0]; gold_n = gold_n + 1; end
            end
            $fclose(fd);
        end
    endtask

    // ---- checks ----
    integer errors = 0;
    integer i, t;

    task run_raw_case(input [1023:0] name, input integer expect_raw);
        begin
            rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
            m = 0; cap_n = 0;
            file_size = img_n;
            @(posedge clk);
            start = 1; @(posedge clk); start = 0;

            t = 0;
            while (cap_n < gold_n && t < 30000000) begin @(posedge clk); t = t + 1; end
            repeat (2000) @(posedge clk);   // let any spurious extra bytes surface

            $display("%0s: raw=%b cap_n=%0d (expect %0d)", name, raw_mode_o, cap_n, gold_n);
            if (raw_mode_o !== expect_raw[0]) begin errors=errors+1; $display("  ERR raw_mode"); end
            if (cap_n < gold_n) begin errors=errors+1; $display("  ERR short output"); end
            for (i = 0; i < gold_n && i < cap_n; i = i + 1)
                if (cap[i] !== gold[i]) begin
                    errors = errors + 1;
                    if (errors < 10)
                        $display("  MISMATCH @%0d: got %02x want %02x", i, cap[i], gold[i]);
                end
        end
    endtask

    initial begin
        // ============= TEST 1: VCD track head (pregap + first packs) =============
        load_img("bench/dvd/test_vobs/vcd_head.hex");
        load_gold("bench/dvd/test_vobs/vcd_head.golden.hex");
        run_raw_case("TEST1 vcd_head", 1);

        // ============= TEST 2: VCD mid-stream (A/V sectors) =============
        load_img("bench/dvd/test_vobs/vcd_mid.hex");
        load_gold("bench/dvd/test_vobs/vcd_mid.golden.hex");
        run_raw_case("TEST2 vcd_mid", 1);
        // spot-check: the deblocked stream must start on a pack start code
        if (!(cap[0]===8'h00 && cap[1]===8'h00 && cap[2]===8'h01)) begin
            errors = errors + 1; $display("  ERR TEST2 stream must start 00 00 01");
        end

        // ============= TEST 3: SVCD slice (Form-1 decoys skipped) =============
        load_img("bench/dvd/test_vobs/svcd_slice.hex");
        load_gold("bench/dvd/test_vobs/svcd_slice.golden.hex");
        run_raw_case("TEST3 svcd_slice", 1);
        if (!(cap[0]===8'h00 && cap[1]===8'h00 && cap[2]===8'h01 && cap[3]===8'hBA)) begin
            errors = errors + 1; $display("  ERR TEST3 stream must start 00 00 01 BA");
        end

        // ============= TEST 4: non-raw flat file regression =============
        // A ramp file (no sync, no CD001) must stream UNCHANGED via the flat
        // fallback with raw_mode=0.
        img_n = 40960;
        for (i = 0; i < img_n; i = i + 1) img[i] = i[7:0] ^ i[13:8];
        gold_n = img_n;
        for (i = 0; i < gold_n; i = i + 1) gold[i] = img[i];
        run_raw_case("TEST4 flat", 0);

        // ============= TEST 5: EOF partial block =============
        // Use the head fixture truncated to 65 blocks + 1000 bytes so the last
        // block is partial: the mock pads with 0xEE. Golden = deblock of the
        // padded byte stream the cache write port actually sees (the model
        // treats pad bytes by the same position walk; with the truncation
        // below they fall outside any Form-2 window, so none are emitted).
        load_img("bench/dvd/test_vobs/vcd_head.hex");
        img_n = 65*2048 + 1000;             // 133,120+1000 < 64 sectors' bytes
        begin : trunc_gold
            integer pos, m2, secp, g;
            pos = 0; m2 = 0; secp = 0; g = 0;
            for (i = 0; i < ((img_n + 2047)/2048)*2048; i = i + 1) begin
                v = (i < img_n) ? {24'd0, img[i]} : 32'h000000EE;
                if (pos == 15) m2   = (v[7:0] == 8'h02);
                if (pos == 18) secp = m2 && v[5];
                if (secp && pos >= 24 && pos < 2348) begin gold[g] = v[7:0]; g = g + 1; end
                if (pos == 2351) begin pos = 0; secp = 0; end
                else pos = pos + 1;
            end
            gold_n = g;
        end
        run_raw_case("TEST5 eof-partial", 1);

        // =============================================================
        if (errors == 0) $display("ISO_READER_RAW_TB: ALL TESTS PASSED");
        else begin
            $display("ISO_READER_RAW_TB: FAILED with %0d errors", errors);
            $fatal(1);
        end
        $finish;
    end

    // global watchdog
    initial begin
        #900000000;
        $display("ISO_READER_RAW_TB: TIMEOUT");
        $fatal(1);
    end

endmodule
