// =============================================================================
// bench/dvd/mem_shim_burst_tb.sv — chain test for dvd/mem_shim_burst.sv
// =============================================================================
// Drives mem_shim_burst through:
//   - a faithful STANDARD-mode request FIFO model (valid = registered rd_en &
//     !empty, dout meaningful only when valid — matches rtl/mpeg2/wrappers.v
//     fifo_dc), and
//   - a behavioral Avalon-MM f2sdram model (internal memory, burst reads with
//     latency + back-to-back beats, single-beat writes, optional waitrequest
//     stalls).
// A reference memory mirrors the command stream; every READ response emitted by
// the DUT (mem_res_wr_en) is checked, IN ORDER, against the reference. Exercises
// sequential reads (burst-fill + hits), strided reads, read-after-write
// coherence (write-invalidate), ADDR_ERR, and waitrequest backpressure.
// =============================================================================
`timescale 1ns/1ps
module mem_shim_burst_tb;
    localparam CMD_READ  = 2'd2;
    localparam CMD_WRITE = 2'd3;
    localparam [21:0] ADDR_ERR = 22'h077FFF;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;   // 100 MHz

    // ---- request FIFO model (standard mode) ----
    localparam MAXCMD = 4096;
    reg  [1:0]  q_cmd  [0:MAXCMD-1];
    reg  [21:0] q_addr [0:MAXCMD-1];
    reg  [63:0] q_dta  [0:MAXCMD-1];
    integer     q_count = 0;     // number enqueued
    integer     q_head  = 0;     // next to present

    reg  [1:0]  req_cmd;
    reg  [21:0] req_addr;
    reg  [63:0] req_dta;
    reg         req_valid;
    wire        req_en;
    wire        q_empty = (q_head >= q_count);

    // standard-mode: a pop (rd_en & !empty) presents the word + valid NEXT cycle
    always @(posedge clk) begin
        if (!rst_n) begin
            req_valid <= 1'b0; q_head <= 0;
            req_cmd <= 0; req_addr <= 0; req_dta <= 0;
        end else if (req_en) begin
            if (!q_empty) begin
                req_cmd   <= q_cmd[q_head];
                req_addr  <= q_addr[q_head];
                req_dta   <= q_dta[q_head];
                req_valid <= 1'b1;
                q_head    <= q_head + 1;
            end else begin
                req_valid <= 1'b0;
            end
        end else begin
            // rd_en low: hold nothing valid (data only valid the cycle after rd_en)
            req_valid <= 1'b0;
        end
    end

    // ---- expected read-response queue (in order) ----
    reg  [63:0] exp_dta [0:MAXCMD-1];
    integer     exp_count = 0;
    integer     exp_head  = 0;
    integer     errors    = 0;

    // ---- reference memory (sparse via large array, word-addressed) ----
    // MP@ML tops out < 0x078000 words; size the model to that.
    localparam MEMW = 22'h080000;
    reg [63:0] ref_mem [0:MEMW-1];

    task enqueue_write(input [21:0] a, input [63:0] d);
        begin
            q_cmd[q_count]  = CMD_WRITE; q_addr[q_count] = a; q_dta[q_count] = d;
            q_count = q_count + 1;
            if (a != ADDR_ERR) ref_mem[a] = d;
        end
    endtask
    task enqueue_read(input [21:0] a);
        begin
            q_cmd[q_count]  = CMD_READ; q_addr[q_count] = a; q_dta[q_count] = 64'd0;
            q_count = q_count + 1;
            exp_dta[exp_count] = (a == ADDR_ERR) ? 64'd0 : ref_mem[a];
            exp_count = exp_count + 1;
        end
    endtask

    // ---- DUT wires ----
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
    wire [15:0] dbg_rd, dbg_wr, dbg_rsp, dbg_pend;

`ifndef MSB_ASSOC
 `define MSB_ASSOC 4
`endif
`ifndef MSB_NSETS
 `define MSB_NSETS 256
`endif
`ifndef MSB_CWF
 `define MSB_CWF 1
`endif
`ifndef MSB_DUAL
 `define MSB_DUAL 0
`endif
    mem_shim_burst #(.ASSOC(`MSB_ASSOC), .NSETS(`MSB_NSETS)) dut (
        .clk(clk), .rst_n(rst_n), .hard_rst_n(rst_n),
        .cwf_en(1'b`MSB_CWF),
        .dual_en(1'b`MSB_DUAL),
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
        .debug_rsp_count(dbg_rsp), .debug_read_pend_cycles(dbg_pend)
    );

    // ---- behavioral Avalon DDR model (PIPELINED: multiple outstanding read bursts) --
    // memory indexed by ddr_addr[21:0] (DENSE formula => bits[24:22]=0). Read commands
    // are queued (FIFO); data returns IN COMMAND ORDER. A burst pays RD_LATENCY only
    // when started from an IDLE pipeline; a burst already queued when the current one
    // finishes chains back-to-back with NO added latency — modeling a real pipelined
    // DDR controller where a 2nd command's row-activate overlaps the 1st's data burst.
    // => single-outstanding pays latency per miss; depth-2 (B queued while A streams)
    // hides B's latency. Writes apply immediately (DUT never writes mid-read-burst).
    reg [63:0] ddr_mem [0:MEMW-1];
    localparam RD_LATENCY = 12;
    localparam BQD = 8;                 // pending-burst queue depth (>= max outstanding)
    reg [21:0] bq_addr [0:BQD-1];
    integer    bq_cnt  [0:BQD-1];
    integer    bq_wr, bq_rd, bq_n;      // queue write/read ptrs + count (registered)
    integer    rd_lat;                  // latency countdown for the burst being served
    integer    rd_beats;                // beats remaining in the burst being served
    reg [21:0] rd_ptr;                  // current beat word address
    integer    seed = 32'hC0FFEE;
    reg        stall_en = 0;            // enable random waitrequest stalls

    wire acc_rd = ddr_read  && !ddr_waitrequest;   // a read burst accepted this cycle
    reg  pop;                                       // a queued burst started this cycle

    // random response backpressure once stall_en is on
    always @(posedge clk) begin
        if (!rst_n) res_almost_full <= 1'b0;
        else if (stall_en) res_almost_full <= (($random(seed) % 4) == 0);
        else res_almost_full <= 1'b0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            ddr_readdatavalid <= 0; ddr_readdata <= 0; ddr_waitrequest <= 0;
            rd_lat <= 0; rd_beats <= 0; rd_ptr <= 0;
            bq_wr <= 0; bq_rd <= 0; bq_n <= 0;
        end else begin
            pop = 1'b0;
            // waitrequest: a registered RANDOM stall, INDEPENDENT of the command.
            ddr_waitrequest <= stall_en ? (($random(seed) % 4) == 0) : 1'b0;

            // accept the held command when not stalling: writes apply now; read
            // bursts are pushed onto the pending-burst queue (available next cycle).
            if (!ddr_waitrequest) begin
                if (ddr_write) ddr_mem[ddr_addr[21:0]] <= ddr_writedata;
                if (ddr_read) begin
                    bq_addr[bq_wr] <= ddr_addr[21:0];
                    bq_cnt [bq_wr] <= ddr_burstcnt;
                    bq_wr <= (bq_wr + 1) % BQD;
                end
            end

            // response engine
            if (rd_beats == 0) begin
                ddr_readdatavalid <= 1'b0;          // idle: start next queued burst
                if (bq_n > 0) begin
                    rd_ptr   <= bq_addr[bq_rd];
                    rd_beats <= bq_cnt [bq_rd];
                    rd_lat   <= RD_LATENCY;          // idle start pays full latency
                    bq_rd    <= (bq_rd + 1) % BQD;
                    pop = 1'b1;
                end
            end else if (rd_lat > 0) begin
                rd_lat <= rd_lat - 1; ddr_readdatavalid <= 1'b0;
            end else begin
                ddr_readdatavalid <= 1'b1;
                ddr_readdata      <= ddr_mem[rd_ptr];
                rd_ptr            <= rd_ptr + 1;
                rd_beats          <= rd_beats - 1;
                if (rd_beats == 1) begin             // last beat: chain next (overlap)
                    if (bq_n > 0) begin
                        rd_ptr   <= bq_addr[bq_rd];
                        rd_beats <= bq_cnt [bq_rd];
                        rd_lat   <= 0;               // queued during stream => no latency
                        bq_rd    <= (bq_rd + 1) % BQD;
                        pop = 1'b1;
                    end
                end
            end

            bq_n <= bq_n + (acc_rd ? 1 : 0) - (pop ? 1 : 0);
        end
    end

    // pre-load ddr model memory to match the reference (unwritten = 0)
    integer k;
    task sync_ddr_mem;
        begin
            for (k = 0; k < MEMW; k = k + 1) ddr_mem[k] = ref_mem[k];
        end
    endtask

    // ---- throughput meter ----
    // A free-running cycle counter + a measurement window [meas_lo, meas_hi) over
    // the in-order response index. The stimulus marks a PURE-HIT sequential phase
    // (re-reading an already-cached region, no backpressure) so cyc/response is the
    // true hit-path cost. Baseline ~4 cyc/hit; step-1 (crit-word-first) is unchanged
    // on pure hits but cuts the miss path; step-2 (pipelined hits) targets ~2.
    integer cyc = 0;
    always @(posedge clk) if (rst_n) cyc <= cyc + 1;
    integer meas_lo = -1, meas_hi = -1;
    integer meas_first_cyc = -1, meas_last_cyc = -1, meas_count = 0;
    // second window: PURE-MISS (every read a fresh line) — measures the miss-serve
    // cost that step-1 critical-word-first attacks.
    integer miss_lo = -1, miss_hi = -1;
    integer miss_first_cyc = -1, miss_last_cyc = -1, miss_count = 0;

    // ---- response checker (in order) ----
    always @(posedge clk) begin
        if (rst_n && res_en) begin
            if (exp_head >= exp_count) begin
                $display("  ERROR: unexpected response %h (no more expected)", res_dta);
                errors = errors + 1;
            end else begin
                if (res_dta !== exp_dta[exp_head]) begin
                    $display("  ERROR resp#%0d: got %h exp %h", exp_head, res_dta, exp_dta[exp_head]);
                    errors = errors + 1;
                end
                if (meas_lo >= 0 && exp_head >= meas_lo && exp_head < meas_hi) begin
                    if (meas_first_cyc < 0) meas_first_cyc = cyc;
                    meas_last_cyc = cyc;
                    meas_count = meas_count + 1;
                end
                if (miss_lo >= 0 && exp_head >= miss_lo && exp_head < miss_hi) begin
                    if (miss_first_cyc < 0) miss_first_cyc = cyc;
                    miss_last_cyc = cyc;
                    miss_count = miss_count + 1;
                end
                exp_head = exp_head + 1;
            end
        end
    end

    // ---- stimulus ----
    integer base, j, ra;
    initial begin
        for (k = 0; k < MEMW; k = k + 1) begin ref_mem[k] = 64'd0; ddr_mem[k] = 64'd0; end
        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1; @(posedge clk);

        // Phase M (THROUGHPUT METER): write a fresh 64-word region, read it once to
        // WARM the cache (1 miss + 7 hits per 8-word line), then re-read it — those
        // 64 reads are ALL HITS and run with no backpressure (stall_en still off), so
        // the measured cyc/response is the pure hit-path cost. Runs first, before any
        // stalls, so the window is clean. 64 words = 8 lines, each in its own set =>
        // no eviction between warm and measure.
        base = 22'h002000;
        for (j = 0; j < 64; j = j + 1) enqueue_write(base + j, {32'h7117_0000 + j, 32'h0002_0000 + j});
        for (j = 0; j < 64; j = j + 1) enqueue_read (base + j);   // warm
        meas_lo = exp_count;
        for (j = 0; j < 64; j = j + 1) enqueue_read (base + j);   // measure (all hits)
        meas_hi = exp_count;

        // Phase M2 (MISS METER): pre-write a fresh region, then read it strided by
        // LINEW (=8) so EVERY read lands on a different, uncached line => a pure miss
        // stream. Measures the miss-serve cost (latency + fill + serve) that step-1
        // critical-word-first shortens. Distinct sets so no eviction interference.
        base = 22'h004000;
        for (j = 0; j < 32*8; j = j + 1) enqueue_write(base + j, {32'h0FF5_0000 + j, 32'h0004_0000 + j});
        miss_lo = exp_count;
        for (j = 0; j < 32; j = j + 1) enqueue_read (base + j*8);  // each a fresh line
        miss_hi = exp_count;

        // Phase 0: write a contiguous region, then read it sequentially
        // (exercises burst-fill + hits — the display scan-out pattern).
        base = 22'h001000;
        for (j = 0; j < 64; j = j + 1) enqueue_write(base + j, {32'hA5A5_0000 + j, 32'h0001_0000 + j});
        for (j = 0; j < 64; j = j + 1) enqueue_read (base + j);

        // Phase 1: strided reads (every 5th word) across the same region
        for (j = 0; j < 12; j = j + 1) enqueue_read(base + j*5);

        // Phase 2: read-after-write coherence — write then immediately read same
        for (j = 0; j < 32; j = j + 1) begin
            enqueue_write(base + j, {32'hDEAD_0000 + j, 32'hBEEF_0000 + j});
            enqueue_read (base + j);
        end

        // Phase 3: ADDR_ERR read + write interleaved with normal traffic
        enqueue_read(ADDR_ERR);
        enqueue_write(ADDR_ERR, 64'hFFFF_FFFF_FFFF_FFFF);
        enqueue_read(base + 5);
        enqueue_read(ADDR_ERR);

        // Phase 4: pseudo-random read/write mix
        for (j = 0; j < 400; j = j + 1) begin
            ra = (($random(seed) % 2000) & 22'h3FFFF);
            if (($random(seed) % 3) == 0) enqueue_write(ra, {$random(seed), $random(seed)});
            else                          enqueue_read (ra);
        end

        // Phase 5: INTERLEAVED multi-stream reads — the real decoder pattern
        // (display scan-out + N motion-comp reference reads) that defeats a
        // direct-mapped cache. The 4 streams are offset by NSETS*LINEW = 1024
        // words, so every stream maps to the SAME set => a direct-mapped cache
        // misses on every access (thrash), but a 4-way set-associative cache
        // holds all four => 1 miss per 8-word line, then 7 hits. We record the
        // DDR read-burst count (= read misses) before/after to report hit rate.
        // NSTREAMS models MPEG-2's concurrent read streams during B-frame decode:
        // fwd-Y, fwd-C, bwd-Y, bwd-C, scan-out-Y, scan-out-C = up to 6 (Y and C
        // live in separate memory regions). 6 streams thrash a 4-way cache but fit
        // an 8-way one — the matrix hypothesis. All offset by NSETS*LINEW=1024 so
        // they map to the SAME set.
        for (j = 0; j < 6; j = j + 1)               // pre-write each stream region
            for (k = 0; k < 64; k = k + 1)
                enqueue_write(22'h010000 + j*1024 + k, {32'h5739_0000 + j, 32'h0000_0000 + k});
        for (k = 0; k < 64; k = k + 1)              // interleave word k of all 6 streams
            for (j = 0; j < 6; j = j + 1)
                enqueue_read(22'h010000 + j*1024 + k);

        // Phase 6: DUAL-OUTSTANDING stress (exercises the paired-fill paths).
        //  6a) long run of consecutive misses to DIFFERENT sets (stride = 1 line) =>
        //      the PAIRABLE case: A+B issued together, collected/served in order.
        base = 22'h020000;
        for (j = 0; j < 64*8; j = j + 1) enqueue_write(base + j, {32'h6A1B_0000 + j, 32'h0020_0000 + j});
        for (j = 0; j < 64; j = j + 1) enqueue_read(base + j*8);        // fresh line each => miss run
        //  6b) consecutive misses to the SAME set (stride = NSETS*LINEW words),
        //      different tags => every read misses the same set => must NOT pair
        //      (B.set==A.set gate) => pk-hold + single-A fallback, in order.
        for (j = 0; j < 16; j = j + 1)
            enqueue_write(22'h030000 + j*(`MSB_NSETS*8), {32'h5A3E_0000 + j, 32'h0030_0000 + j});
        for (j = 0; j < 16; j = j + 1) enqueue_read(22'h030000 + j*(`MSB_NSETS*8));
        //  6c) miss -> hit -> miss -> write pattern (exercises pk-hold of a hit and
        //      of a write following a miss, served strictly in order).
        for (j = 0; j < 8; j = j + 1) begin
            enqueue_read (base + j*8);          // hit (warmed in 6a) — but preceded by:
            enqueue_read (22'h040000 + j*8);    // fresh miss, next is the above hit
            enqueue_write(22'h040000 + j*8, {32'h7777_0000 + j, 32'h0040_0000 + j});
            enqueue_read (22'h040000 + j*8);    // read-after-write coherence
        end

        // NB: ddr_mem starts at 0 and is driven ONLY by the DUT's write-through.
        // ref_mem is updated at enqueue (= stream order), so the expected read
        // value is the most-recent prior write — which the in-order DUT will have
        // written through to ddr_mem before it processes the read. No preload.

        // turn on random waitrequest + response-backpressure stalls only AFTER the
        // pure-hit meter window has drained (so the meter sees no stalls).
        while (exp_head < miss_hi) @(posedge clk);
        stall_en = 1;

        // wait for all responses (with a generous timeout)
        for (j = 0; j < 200000; j = j + 1) begin
            @(posedge clk);
            if (exp_head >= exp_count) j = 200000; // done
        end

        repeat (20) @(posedge clk);
        $display("=================================================");
        $display("mem_shim_burst_tb: enqueued %0d cmds, %0d reads", q_count, exp_count);
        $display("  responses checked: %0d / %0d", exp_head, exp_count);
        $display("  ddr burst-cmds=%0d beats=%0d writes=%0d", dbg_rd, dbg_rsp, dbg_wr);
        if (meas_count > 1)
            $display("  THROUGHPUT (pure-hit seq): %0d responses over %0d cycles = %0d.%0d cyc/resp",
                     meas_count, (meas_last_cyc - meas_first_cyc),
                     (meas_last_cyc - meas_first_cyc) / (meas_count - 1),
                     ((100*(meas_last_cyc - meas_first_cyc)) / (meas_count - 1)) % 100);
        else
            $display("  THROUGHPUT: meter did not capture (meas_count=%0d)", meas_count);
        if (miss_count > 1)
            $display("  THROUGHPUT (pure-miss):    %0d responses over %0d cycles = %0d.%0d cyc/resp",
                     miss_count, (miss_last_cyc - miss_first_cyc),
                     (miss_last_cyc - miss_first_cyc) / (miss_count - 1),
                     ((100*(miss_last_cyc - miss_first_cyc)) / (miss_count - 1)) % 100);
        // read miss = one DDR burst-cmd; hit rate = 1 - misses/reads. A direct-
        // mapped cache thrashes phase 5 (~all-miss); 4-way should be well above.
        $display("  read hit rate: %0d%% (%0d reads, %0d misses)",
                 (exp_count > 0) ? (100*(exp_count - dbg_rd))/exp_count : 0,
                 exp_count, dbg_rd);
        if (errors == 0 && exp_head == exp_count)
            $display("  RESULT: PASS");
        else
            $display("  RESULT: FAIL (%0d errors, %0d/%0d responses)", errors, exp_head, exp_count);
        $finish;
    end

    // global watchdog
    initial begin
        #5_000_000;
        $display("  RESULT: FAIL — global timeout (deadlock?). state=%0d exp %0d/%0d",
                 dbg_state, exp_head, exp_count);
        $finish;
    end
endmodule
