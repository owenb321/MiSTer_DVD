// memreq_retime_tb.sv — prove the DVD-FORK RETIME in rtl/mpeg2/framestore.v
// (pipeline register between framestore_request and mem_request_fifo's M10K
// write port) is TRANSPARENT: same requests, same order, no overflow.
//
// Two identical fifo_dc instances (the real mem_request_fifo geometry:
// 88 bits x 2^6, prog_thresh 16 — dvd/mem_override/fifo_size.v) are fed the
// same randomized request stream from a modeled framestore_request source that
// obeys the REAL stop rule: it samples prog_full through a one-cycle register
// (the PR fj#58 mem_req_af_r idiom) and stops issuing while that reads full.
//   REF     : source -> fifo                     (pre-retime wiring)
//   RETIMED : source -> 1-deep pipe reg -> fifo  (the framestore.v change)
// A slow, bursty reader drains both. Checks:
//   [1] the drained sequences are IDENTICAL (content and order, 1:1);
//   [2] neither fifo ever overflows — the retime's extra in-flight request is
//       absorbed by the 16-slot threshold margin;
//   [3] the retimed fifo's write side never sees wr_en while full.
//
// Build:
//   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 rtl/mpeg2/wrappers.v \
//       rtl/mpeg2/fwft.v rtl/mpeg2/xilinx_fifo_dc.v rtl/mpeg2/xfifo_sc.v \
//       bench/dvd/memreq_retime_tb.sv -o /tmp/memreq_retime && vvp /tmp/memreq_retime

`timescale 1ns/1ps

module memreq_retime_tb;

    // real mem_request_fifo geometry
    localparam [8:0] DW = 9'd88, AW = 9'd6, THRESH = 9'd16;
    localparam int   NREQ = 20000;

    reg wr_clk = 0, rd_clk = 0, rst = 0;
    always #6.17 wr_clk = ~wr_clk;      // ~81 MHz (clk_dec)
    always #4.63 rd_clk = ~rd_clk;      // ~108 MHz (mem clk)

    // ---- shared source (framestore_request model) --------------------------
    reg  [87:0] src_dta;
    reg         src_en;

    // REF fifo write side = source direct
    wire        ref_prog_full, ref_full, ref_overflow;
    // RETIMED fifo write side = source through the pipe register
    reg  [87:0] pipe_dta;
    reg         pipe_en;
    wire        ret_prog_full, ret_full, ret_overflow;

    // the fj#58 registered-almost-full stop rule, applied to BOTH branches:
    // the source stops when EITHER branch's registered prog_full says stop
    // (both fifos see the same stream, so their fills track within 1).
    reg ref_af_r = 1'b1, ret_af_r = 1'b1;
    always @(posedge wr_clk)
        if (~rst) begin ref_af_r <= 1'b1; ret_af_r <= 1'b1; end
        else      begin ref_af_r <= ref_prog_full; ret_af_r <= ret_prog_full; end
    wire src_stop = ref_af_r | ret_af_r;

    // the retime under test (mirrors framestore.v exactly)
    always @(posedge wr_clk)
        if (~rst) begin
            pipe_en  <= 1'b0;
            pipe_dta <= 88'b0;
        end else begin
            pipe_en  <= src_en;
            pipe_dta <= src_dta;
        end

    // ---- the two fifos -----------------------------------------------------
    wire [87:0] ref_dout, ret_dout;
    wire        ref_empty, ret_empty, ref_valid, ret_valid;
    reg         ref_rd_en, ret_rd_en;

    fifo_dc #(.dta_width(DW), .addr_width(AW), .prog_thresh(THRESH), .FIFO_XILINX(1))
    ref_fifo (
        .rst(rst), .wr_clk(wr_clk),
        .din(src_dta), .wr_en(src_en),
        .full(ref_full), .wr_ack(), .overflow(ref_overflow), .prog_full(ref_prog_full),
        .rd_clk(rd_clk), .dout(ref_dout), .rd_en(ref_rd_en),
        .empty(ref_empty), .valid(ref_valid), .underflow(), .prog_empty()
    );

    fifo_dc #(.dta_width(DW), .addr_width(AW), .prog_thresh(THRESH), .FIFO_XILINX(1))
    ret_fifo (
        .rst(rst), .wr_clk(wr_clk),
        .din(pipe_dta), .wr_en(pipe_en),
        .full(ret_full), .wr_ack(), .overflow(ret_overflow), .prog_full(ret_prog_full),
        .rd_clk(rd_clk), .dout(ret_dout), .rd_en(ret_rd_en),
        .empty(ret_empty), .valid(ret_valid), .underflow(), .prog_empty()
    );

    // ---- source driver: bursty random issue, honours the stop rule ---------
    integer issued = 0, seed = 32'hD4D5EED;
    always @(posedge wr_clk) begin
        src_en <= 1'b0;
        if (rst && issued < NREQ && !src_stop) begin
            // bursty: ~70% issue probability inside a burst window
            if ($dist_uniform(seed, 0, 9) < 7) begin
                src_dta <= {$random(seed), $random(seed), $random(seed)};
                src_en  <= 1'b1;
                issued  = issued + 1;
            end
        end
    end

    // ---- drain + compare ---------------------------------------------------
    // Each fifo drains through its OWN gated reader (cycle alignment between
    // the two is NOT part of the transparency claim — only sequence equality
    // is), with shared bursty stalls so both ride through near-full episodes.
    integer stall = 0;
    always @(posedge rd_clk) begin
        if (!rst) begin ref_rd_en <= 1'b0; ret_rd_en <= 1'b0; stall <= 0; end
        else begin
            ref_rd_en <= 1'b0; ret_rd_en <= 1'b0;
            if (stall > 0) stall <= stall - 1;
            else if ($dist_uniform(seed, 0, 99) < 3)
                stall <= $dist_uniform(seed, 20, 120);
            else begin
                ref_rd_en <= !ref_empty;
                ret_rd_en <= !ret_empty;
            end
        end
    end

    // sequence capture
    reg [87:0] ref_q [0:NREQ-1];
    reg [87:0] ret_q [0:NREQ-1];
    integer ref_n = 0, ret_n = 0;
    integer errors = 0;
    reg ovf_seen = 0, wr_while_full = 0;
    always @(posedge rd_clk) begin
        if (ref_valid) begin ref_q[ref_n] <= ref_dout; ref_n = ref_n + 1; end
        if (ret_valid) begin ret_q[ret_n] <= ret_dout; ret_n = ret_n + 1; end
    end
    always @(posedge wr_clk) begin
        if (ref_overflow || ret_overflow) ovf_seen <= 1'b1;
        if (pipe_en && ret_full)          wr_while_full <= 1'b1;
    end

    initial begin
        rst = 0; repeat (8) @(posedge wr_clk); rst = 1;
        wait (issued == NREQ);
        // let both drain completely
        wait (ref_empty && ret_empty && !pipe_en);
        repeat (40) @(posedge rd_clk);
        if (ref_n != NREQ || ret_n != NREQ) begin
            errors = errors + 1;
            $display("FAIL: drained ref %0d / ret %0d of %0d requests", ref_n, ret_n, NREQ);
        end else begin
            for (integer i = 0; i < NREQ; i = i + 1)
                if (ref_q[i] !== ret_q[i]) begin
                    errors = errors + 1;
                    if (errors < 5)
                        $display("FAIL: sequence mismatch #%0d: ref %h ret %h", i, ref_q[i], ret_q[i]);
                end
        end
        if (ovf_seen)      begin errors = errors + 1; $display("FAIL: a fifo overflowed"); end
        if (wr_while_full) begin errors = errors + 1; $display("FAIL: retimed write while full"); end
        if (errors == 0)
            $display("MEMREQ_RETIME_TB: ALL TESTS PASSED (%0d requests, 1:1 in order, no overflow)", ref_n);
        else begin
            $display("MEMREQ_RETIME_TB: %0d FAILURE(S)", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin #10_000_000; $display("MEMREQ_RETIME_TB: TIMEOUT"); $fatal(1); end

endmodule
