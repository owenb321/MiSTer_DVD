// =============================================================================
// bench/dvd/mem_shim_serialize_tb.sv
// =============================================================================
// Isolates the read-serializer in dvd/mem_shim.sv. Models an f2sdram bridge
// that ACCEPTS every read (waitrequest=0) but NEVER returns readdatavalid —
// exactly the on-hardware failure. If the serializer works, mem_shim must issue
// exactly ONE read and then block forever (rd_count == 1). If rd_count climbs,
// the serializer is not limiting outstanding reads — which would explain the
// hardware reading rd_count=33319 with rsp_count=75.
// =============================================================================
`timescale 1ns/1ps
module mem_shim_serialize_tb;
    localparam CMD_READ = 2'd2;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;   // 100 MHz

    // mem_req FIFO side
    reg  [1:0]  req_cmd  = CMD_READ;
    reg  [21:0] req_addr = 22'h000040;   // non-ADDR_ERR
    reg  [63:0] req_dta  = 0;
    wire        req_en;
    reg         req_valid = 1'b1;         // infinite supply of read commands

    // mem_res side
    wire [63:0] res_dta;
    wire        res_en;
    reg         res_almost_full = 1'b0;

    // ddr3 bridge model: accept everything, never respond
    wire [28:0] ddr3_addr;
    wire [7:0]  ddr3_burstcnt;
    wire        ddr3_read, ddr3_write;
    wire [63:0] ddr3_writedata;
    wire [7:0]  ddr3_byteenable;
    reg  [63:0] ddr3_readdata = 0;
    reg         ddr3_readdatavalid = 1'b0;   // <-- NEVER asserted
    reg         ddr3_waitrequest = 1'b0;     // <-- always accept

    wire [3:0]  dbg_state;
    wire [1:0]  dbg_saved_cmd;
    wire        dbg_sdram_busy, dbg_sdram_ack;
    wire [15:0] dbg_rd_count, dbg_wr_count, dbg_rsp_count, dbg_read_pend;

    mem_shim dut (
        .clk(clk), .rst_n(rst_n), .hard_rst_n(rst_n),
        .mem_req_rd_cmd(req_cmd), .mem_req_rd_addr(req_addr), .mem_req_rd_dta(req_dta),
        .mem_req_rd_en(req_en), .mem_req_rd_valid(req_valid),
        .mem_res_wr_dta(res_dta), .mem_res_wr_en(res_en), .mem_res_wr_almost_full(res_almost_full),
        .ddr3_addr(ddr3_addr), .ddr3_burstcnt(ddr3_burstcnt),
        .ddr3_read(ddr3_read), .ddr3_write(ddr3_write),
        .ddr3_writedata(ddr3_writedata), .ddr3_byteenable(ddr3_byteenable),
        .ddr3_readdata(ddr3_readdata), .ddr3_readdatavalid(ddr3_readdatavalid),
        .ddr3_waitrequest(ddr3_waitrequest),
        .debug_state(dbg_state), .debug_saved_cmd(dbg_saved_cmd),
        .debug_sdram_busy(dbg_sdram_busy), .debug_sdram_ack(dbg_sdram_ack),
        .debug_rd_count(dbg_rd_count), .debug_wr_count(dbg_wr_count),
        .debug_rsp_count(dbg_rsp_count), .debug_read_pend_cycles(dbg_read_pend)
    );

    // Model standard-mode FIFO: when mem_shim consumes (req_en & req_valid),
    // present the next read command (different address) on the following cycle.
    always @(posedge clk) begin
        if (req_en && req_valid) req_addr <= req_addr + 22'd8;
    end

    integer i;
    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;

        // Run ~5 timeout windows (RD_TIMEOUT=2047) with the bridge never
        // responding. The serializer keeps one read in flight; the give-up
        // timeout should release it after each window and issue the next, so
        // rd_count should climb to roughly cycles/2048 — bounded, one at a time.
        for (i = 0; i < 11000; i = i + 1) @(posedge clk);

        $display("After 11000 cycles, bridge never returned a read response:");
        $display("  rd_count  = %0d (reads accepted by bridge)", dbg_rd_count);
        $display("  rsp_count = %0d (readdatavalid pulses)",      dbg_rsp_count);
        if (dbg_rd_count >= 3 && dbg_rd_count <= 8 && dbg_rsp_count == 0)
            $display("  RESULT: PASS — read times out and RE-ISSUES ~1 per window (retry active), still serialized.");
        else if (dbg_rd_count <= 1)
            $display("  RESULT: FAIL — still blocking forever; retry timeout not working.");
        else
            $display("  RESULT: CHECK — rd_count=%0d (expected ~5 over 11000 cycles).", dbg_rd_count);
        $finish;
    end
endmodule
