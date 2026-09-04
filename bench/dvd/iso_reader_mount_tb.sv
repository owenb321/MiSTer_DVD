// iso_reader_mount_tb.sv — issue #48: the reader must survive a mount that carries
// no media, and a mount that arrives on top of a read already in flight.
//
// Why these two:
//
// [1] EMPTY IMAGE. Main sends UIO_SET_SDSTAT even when the file never opened, with
//     sd_image[].size zeroed, and hps_io raises img_mounted for an all-zero status
//     word too (that is how an eject arrives). total_blocks is then 0, S_INIT took
//     the "< 17 sectors" branch and wrote a ZERO-LENGTH extent, and S_STREAM's
//     terminator was `strm_blk + 1 == ext_blocks_q` -- which 0 can never satisfy.
//     The reader walked LBA 0,1,2,... of an empty slot for ever, and because no
//     sector data ever arrives, emu.sv's "unsupported image" watchdog holds instead
//     of firing: a blank screen with no logo and no message. emu.sv now also
//     declines to start on a zero size; this is the second of the two locks.
//
// [2] MOUNT OVER AN IN-FLIGHT READ. `start` pre-empts every state and clears sd_rd
//     and blk_inflight, but an HPS transaction is not cancellable. ⚠ The mock HPS
//     used by the other iso_reader benches cannot see this class at all: it latches
//     the request on the FIRST cycle sd_rd is high and always serves it. The real
//     hps_io picks the request up by POLLING command 'h16 at Main's poll rate, so a
//     request withdrawn before the next poll is simply lost. The mock here polls,
//     which is what makes [2] able to fail.
//
// MEASURED against the pre-fix RTL (S_INIT's zero check removed and the S_STREAM
// terminator back to `==`):
//   [1] sd_rd requests after an empty mount   10  (expect 0)                FAIL
//   [1] reader state                          10 = S_STREAM (expect DONE)   FAIL
// 10 is only "how many fitted in the bench window" -- the walk has no end, which
// is the defect. [2] and [3] pass either way and are there to catch the fix
// over-reaching: an empty mount must not leave the reader unable to start again.
`timescale 1ns/1ps

module iso_reader_mount_tb;

    // dvd_iso_reader's own state encoding; debug_state's low 6 bits are `state`.
    localparam [5:0] S_IDLE   = 6'd0;
    localparam [5:0] S_STREAM = 6'd10;
    localparam [5:0] S_DONE   = 6'd11;

    reg         clk = 0, rst_n = 0;
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
    wire [15:0] debug_state;
    wire [5:0]  rd_state = debug_state[5:0];

    always #5 clk = ~clk;

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size),
        .title_sel(7'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(debug_state), .debug_iso_mode(), .debug_iso_error()
    );

    // ---- a small flat image: no CD sync at byte 0, no CD001 at LBA 16, so the
    // reader takes the linear fallback -- the .mpg path from the bug report.
    localparam integer NSEC = 24;
    reg [7:0] img [0:NSEC*2048-1];

    // ---- mock HPS ----------------------------------------------------------
    // POLLED, unlike the mock in iso_reader_tb.sv: the request is only picked up
    // when the poll tick comes round, so a request the reader withdraws in the
    // meantime is lost, exactly as it is on hardware.
    localparam integer POLL_PERIOD = 40;   // clocks between "user_io_poll" visits
    integer m = 0, bc = 0, poll = 0;
    reg [31:0] rlba = 0;
    integer reqs = 0;                      // requests the HPS actually accepted

    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin
            sd_ack <= 1'b0;
            poll   <= (poll == POLL_PERIOD-1) ? 0 : poll + 1;
            if (poll == 0 && sd_rd) begin
                rlba <= sd_lba; reqs <= reqs + 1; bc <= 0; m <= 1;
            end
        end
        1: begin
            sd_ack       <= 1'b1;
            sd_buff_wr   <= 1'b1;
            sd_buff_addr <= bc[13:0];
            sd_buff_dout <= (rlba < NSEC) ? img[rlba*2048 + bc] : 8'h00;
            bc           <= bc + 1;
            if (bc == 2047) m <= 2;
        end
        2: begin sd_ack <= 1'b0; m <= 0; end   // falling edge = block done
        endcase
    end

    integer i, errs = 0;
    integer reqs_mark;
    reg [5:0] st;

    initial begin
        for (i = 0; i < NSEC*2048; i = i + 1) img[i] = 8'hB0;
        // a pack start code at byte 0 so the linear path has something plausible
        img[0] = 8'h00; img[1] = 8'h00; img[2] = 8'h01; img[3] = 8'hBA;

        repeat (4) @(posedge clk);
        rst_n = 1; repeat (2) @(posedge clk);

        // ================================================================== [1]
        $display("=== [1] an empty image must stop, not stream for ever ===");
        file_size = 64'd0;
        start = 1; @(posedge clk); start = 0;
        reqs_mark = reqs;
        repeat (20000) @(posedge clk);
        st = rd_state;
        $display("    sd_rd requests served: %0d (expect 0)", reqs - reqs_mark);
        $display("    reader state: %0d (expect %0d = S_DONE)", st, S_DONE);
        if (st !== S_DONE) begin
            $display("FAIL [1]: state %0d, expected S_DONE (%0d)", st, S_DONE);
            errs = errs + 1;
        end
        if (reqs != reqs_mark) begin
            $display("FAIL [1]: the reader issued %0d reads against an empty slot",
                     reqs - reqs_mark);
            errs = errs + 1;
        end
        if (stream_valid) begin
            $display("FAIL [1]: the reader is delivering bytes from an empty image");
            errs = errs + 1;
        end

        // ================================================================== [2]
        $display("=== [2] a real mount after the empty one must still work ===");
        file_size = NSEC * 2048;
        start = 1; @(posedge clk); start = 0;
        reqs_mark = reqs;
        repeat (30000) @(posedge clk);
        $display("    sd_rd requests served: %0d (expect > 0)", reqs - reqs_mark);
        if (reqs == reqs_mark) begin
            $display("FAIL [2]: an empty mount left the reader unable to start again");
            errs = errs + 1;
        end

        // ================================================================== [3]
        $display("=== [3] a mount landing on an in-flight read must not wedge ===");
        // Wait until a block is genuinely in flight (sd_ack high mid-transfer),
        // then re-mount on top of it.
        @(posedge clk);
        while (!(sd_ack && bc > 100)) @(posedge clk);
        start = 1; @(posedge clk); start = 0;
        reqs_mark = reqs;
        repeat (40000) @(posedge clk);
        $display("    sd_rd requests served after the collision: %0d (expect > 0)",
                 reqs - reqs_mark);
        if (reqs == reqs_mark) begin
            $display("FAIL [3]: the reader stopped requesting after a mount collision");
            errs = errs + 1;
        end

        $display("=== iso_reader mount testbench: %0d error(s) ===", errs);
        if (errs) begin
            $display("iso_reader_mount_tb FAILED");
            $fatal(1, "iso_reader_mount_tb FAILED");
        end
        $display("PASS");
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "iso_reader_mount_tb: timeout");
    end
endmodule
