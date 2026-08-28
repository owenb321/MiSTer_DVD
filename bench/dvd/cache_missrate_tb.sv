// =============================================================================
// bench/dvd/cache_missrate_tb.sv — verify dvd/mem_shim_burst.sv miss-rate telemetry
// =============================================================================
// The Matrix-vs-BBB compute-vs-memory disambiguator (memory:
// clock-lever-exhausted-matrix). mem_shim_burst now reports, per 65536-cycle
// window, debug_cache_missrate = {miss_pct[15:8], reads_hi[7:0]} where miss_pct =
// cache_miss*256/(cache_hit+cache_miss) (8-bit, 0xFF~=100% miss).
//
// This TB drives three controlled READ streams (no data checking — correctness is
// covered by mem_shim_burst_tb) and samples miss_pct after a full window:
//   A PURE-HIT     re-read a warmed 64-word region          -> miss_pct ~= 0x00
//   B SEQUENTIAL   contiguous reads (1 miss / 8-word line)  -> miss_pct ~= 0x20 (12.5%)
//   C PURE-MISS    stride-8 over fresh lines (every miss)   -> miss_pct ~= 0xFF
// If the divider/accounting is wrong these three won't land on 0 / ~32 / ~255.
// =============================================================================
`timescale 1ns/1ps
module cache_missrate_tb;
    localparam CMD_NOOP = 2'd0;
    localparam CMD_READ = 2'd2;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;   // 100 MHz

    // ---- synthetic request generator (standard FIFO timing) ----
    // mode: 0=idle(NOOP), 1=pure-hit, 2=sequential, 3=pure-miss
    integer    gen_mode = 0;
    reg [21:0] gen_seq  = 0;     // running counter for seq/miss modes
    localparam [21:0] HIT_BASE = 22'h002000;
    localparam [21:0] SEQ_BASE = 22'h020000;
    localparam [21:0] MIS_BASE = 22'h060000;  // clear of phase-B's swept range

    reg  [1:0]  req_cmd;
    reg  [21:0] req_addr;
    reg  [63:0] req_dta;
    reg         req_valid;
    wire        req_en;

    // present the next command the cycle after req_en (matches fifo_dc model)
    always @(posedge clk) begin
        if (!rst_n) begin
            req_valid <= 1'b0; req_cmd <= CMD_NOOP; req_addr <= 0; req_dta <= 0;
            gen_seq <= 0;
        end else if (req_en) begin
            if (gen_mode == 0) begin
                req_cmd <= CMD_NOOP; req_addr <= 0; req_valid <= 1'b1;
            end else begin
                req_cmd <= CMD_READ; req_valid <= 1'b1;
                case (gen_mode)
                    1: req_addr <= HIT_BASE + (gen_seq % 64);   // cached -> hit
                    2: req_addr <= SEQ_BASE + gen_seq;          // 1 miss / 8 reads
                    3: req_addr <= MIS_BASE + (gen_seq << 3);   // every read a fresh line
                    default: req_addr <= 0;
                endcase
                gen_seq <= gen_seq + 1;
            end
        end else begin
            req_valid <= 1'b0;
        end
    end

    // ---- DUT ----
    wire [63:0] res_dta;
    wire        res_en;
    reg         res_almost_full = 1'b0;

    wire [28:0] ddr_addr;
    wire [7:0]  ddr_burstcnt;
    wire        ddr_read, ddr_write;
    wire [63:0] ddr_writedata;
    wire [7:0]  ddr_byteenable;
    reg  [63:0] ddr_readdata = 0;
    reg         ddr_readdatavalid = 0;
    reg         ddr_waitrequest = 0;

    wire [3:0]  dbg_state;
    wire [1:0]  dbg_saved_cmd;
    wire        dbg_busy, dbg_ack;
    wire [15:0] dbg_rd, dbg_wr, dbg_rsp, dbg_pend, dbg_missrate;

    // cwf_en/dual_en tied OFF: these ports postdate this TB and were left
    // unconnected (= X) — the flop-tag FSM happened to resolve the X to the
    // same "cwf off, dual off" config, the BRAM-tag FSM's reordered state
    // ternary does not. emu.sv always drives both pins on hardware.
    mem_shim_burst #(.ASSOC(4), .NSETS(64)) dut (
        .clk(clk), .rst_n(rst_n), .hard_rst_n(rst_n),
        .cwf_en(1'b0), .dual_en(1'b0),
        .mem_req_rd_cmd(req_cmd), .mem_req_rd_addr(req_addr), .mem_req_rd_dta(req_dta),
        .mem_req_rd_en(req_en), .mem_req_rd_valid(req_valid),
        .mem_res_wr_dta(res_dta), .mem_res_wr_en(res_en), .mem_res_wr_almost_full(res_almost_full),
        .ddr3_addr(ddr_addr), .ddr3_burstcnt(ddr_burstcnt),
        .ddr3_read(ddr_read), .ddr3_write(ddr_write),
        .ddr3_writedata(ddr_writedata), .ddr3_byteenable(ddr_byteenable),
        .ddr3_readdata(ddr_readdata), .ddr3_readdatavalid(ddr_readdatavalid),
        .ddr3_waitrequest(ddr_waitrequest),
        .debug_state(dbg_state), .debug_saved_cmd(dbg_saved_cmd),
        .debug_sdram_busy(dbg_busy), .debug_sdram_ack(dbg_ack),
        .debug_rd_count(dbg_rd), .debug_wr_count(dbg_wr),
        .debug_rsp_count(dbg_rsp), .debug_read_pend_cycles(dbg_pend),
        .debug_cache_missrate(dbg_missrate)
    );

    // ---- behavioral Avalon burst DDR model (returns 0 data; we don't check it) ----
    integer rd_lat, rd_beats;
    reg [21:0] rd_ptr;
    localparam RD_LATENCY = 12;
    always @(posedge clk) begin
        if (!rst_n) begin
            ddr_readdatavalid <= 0; ddr_readdata <= 0; ddr_waitrequest <= 0;
            rd_lat <= 0; rd_beats <= 0; rd_ptr <= 0;
        end else begin
            ddr_waitrequest <= 1'b0;
            if (!ddr_waitrequest && ddr_read) begin
                rd_ptr <= ddr_addr[21:0]; rd_beats <= ddr_burstcnt; rd_lat <= RD_LATENCY;
            end
            if (rd_beats > 0 && rd_lat > 0) begin
                rd_lat <= rd_lat - 1; ddr_readdatavalid <= 1'b0;
            end else if (rd_beats > 0 && rd_lat == 0) begin
                ddr_readdatavalid <= 1'b1; ddr_readdata <= {42'd0, rd_ptr};
                rd_ptr <= rd_ptr + 1; rd_beats <= rd_beats - 1;
            end else begin
                ddr_readdatavalid <= 1'b0;
            end
        end
    end

    // ---- helpers ----
    integer errors = 0;
    // run `mode` long enough to span >1 full 65536-cycle window, then sample.
    task run_phase(input integer mode, input [31:0] cycles);
        begin
            gen_mode = mode;
            repeat (cycles) @(posedge clk);
        end
    endtask
    task check(input [127:0] name, input [7:0] got, input [7:0] lo, input [7:0] hi);
        begin
            if (got < lo || got > hi) begin
                $display("  FAIL %0s: miss_pct=0x%02h (%0d), expected %0d..%0d",
                         name, got, got, lo, hi);
                errors = errors + 1;
            end else
                $display("  ok   %0s: miss_pct=0x%02h (%0d) in [%0d..%0d]",
                         name, got, got, lo, hi);
        end
    endtask

    localparam integer WIN = 65536;

    initial begin
        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1; @(posedge clk);

        // ---- A: PURE-HIT. Warm the 64-word region first (one window), then sample
        // the next full hit-only window => ~0% miss.
        run_phase(1, 2*WIN + 2000);
        check("A pure-hit ", dbg_missrate[15:8], 8'd0,   8'd6);
        $display("    (reads_hi=0x%02h)", dbg_missrate[7:0]);

        // ---- B: SEQUENTIAL. 1 miss per 8-word line => 12.5% = 0x20 (32). Allow a
        // band for the first partially-warmed window having drained already.
        gen_seq_reset;
        run_phase(2, 2*WIN + 2000);
        check("B sequential", dbg_missrate[15:8], 8'd26,  8'd38);   // 32 +/- ~6
        $display("    (reads_hi=0x%02h)", dbg_missrate[7:0]);

        // ---- C: PURE-MISS. Every read a fresh line => ~100% miss => 0xFF.
        gen_seq_reset;
        run_phase(3, 2*WIN + 2000);
        check("C pure-miss ", dbg_missrate[15:8], 8'd250, 8'd255);
        $display("    (reads_hi=0x%02h)", dbg_missrate[7:0]);

        $display("=================================================");
        if (errors == 0) $display("  RESULT: PASS");
        else             $display("  RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    // reset the running address counter between phases (force-fresh sets for B/C)
    task gen_seq_reset; begin gen_seq = 0; end endtask

    initial begin
        #20_000_000;
        $display("  RESULT: FAIL — global timeout. state=%0d missrate=0x%04h", dbg_state, dbg_missrate);
        $finish;
    end
endmodule
