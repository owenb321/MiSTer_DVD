// =============================================================================
// bench/dvd/mem_shim_ab_tb.sv — A/B gate: BRAM-tag mem_shim_burst vs the frozen
// flop-tag reference (mem_shim_burst_ref.sv)
// =============================================================================
// The tag/LRU-to-M10K rework (feature/mem-shim-tag-bram) must be DECISION-EXACT:
// same replacement policy, same victim choices, same hit/miss verdict for every
// read — "hit rate must be identical" means bit-exact LRU behaviour, not close.
//
// Both DUTs (REF = frozen pre-BRAM copy, NEW = dvd/mem_shim_burst.sv) run the
// SAME command trace at shipping geometry (NSETS=128, ASSOC=4), each through its
// own FIFO model and its own behavioral DDR model with INDEPENDENT random
// waitrequest + response-backpressure seeds. Decisions must be timing-invariant
// (strict in-order processing + deterministic LRU), so the two runs must agree
// even though every stall lands differently. Compared, element by element:
//   - the SEQUENCE of accepted read-burst addresses (one burst = one read miss:
//     equal sequences <=> identical miss decisions <=> identical LRU state), and
//   - the SEQUENCE of read-response data (both also checked against a reference
//     memory, so "equal" can't mean "equally wrong").
// The trace leans on the policy: same-set tag competition (6+ streams offset by
// NSETS*LINEW), write-hit LRU touches, random aliasing mixes, ADDR_ERR
// sprinkles, and dual-pairable / non-pairable miss runs.
// Combos: rerun with -DMSAB_CWF=0/1 x -DMSAB_DUAL=0/1 (see run_mem_shim.sh).
// =============================================================================
`timescale 1ns/1ps
module mem_shim_ab_tb;
    localparam CMD_NOOP  = 2'd0;
    localparam CMD_READ  = 2'd2;
    localparam CMD_WRITE = 2'd3;
    localparam [21:0] ADDR_ERR = 22'h077FFF;
    localparam NSETS = 128;
    localparam LINEW = 8;

`ifndef MSAB_CWF
 `define MSAB_CWF 1
`endif
`ifndef MSAB_DUAL
 `define MSAB_DUAL 1
`endif

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;   // 100 MHz

    // ---- shared command trace ----
    localparam MAXCMD = 8192;
    reg  [1:0]  q_cmd  [0:MAXCMD-1];
    reg  [21:0] q_addr [0:MAXCMD-1];
    reg  [63:0] q_dta  [0:MAXCMD-1];
    integer     q_count = 0;

    // reference memory (stream-order semantics; both DUTs are in-order)
    localparam MEMW = 22'h080000;
    reg [63:0] ref_mem [0:MEMW-1];
    reg [63:0] exp_dta [0:MAXCMD-1];
    integer    exp_count = 0;

    task enqueue_write(input [21:0] a, input [63:0] d);
        begin
            q_cmd[q_count] = CMD_WRITE; q_addr[q_count] = a; q_dta[q_count] = d;
            q_count = q_count + 1;
            if (a != ADDR_ERR) ref_mem[a] = d;
        end
    endtask
    task enqueue_read(input [21:0] a);
        begin
            q_cmd[q_count] = CMD_READ; q_addr[q_count] = a; q_dta[q_count] = 64'd0;
            q_count = q_count + 1;
            exp_dta[exp_count] = (a == ADDR_ERR) ? 64'd0 : ref_mem[a];
            exp_count = exp_count + 1;
        end
    endtask

    integer errors = 0;

    // =========================================================================
    // one complete harness per DUT: FIFO model + DDR model + capture arrays
    // (generate keeps the two rigs identical except for the random seeds)
    // =========================================================================
    // capture arrays, indexed [dut]: 0 = REF, 1 = NEW
    reg [21:0] cap_burst [0:1][0:MAXCMD-1];   // accepted read-burst word addrs, in order
    integer    cap_bn    [0:1];
    reg [63:0] cap_resp  [0:1][0:MAXCMD-1];   // read-response data, in order
    integer    cap_rn    [0:1];
    integer    cap_wn    [0:1];               // accepted write count

    genvar g;
    generate
    for (g = 0; g < 2; g = g + 1) begin : rig
        // ---- FIFO model (standard mode: valid the cycle after rd_en) ----
        integer     q_head = 0;
        reg  [1:0]  req_cmd;
        reg  [21:0] req_addr;
        reg  [63:0] req_dta;
        reg         req_valid;
        wire        req_en;
        wire        q_empty = (q_head >= q_count);

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
                req_valid <= 1'b0;
            end
        end

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
        wire [15:0] dbg_rd, dbg_wr, dbg_rsp, dbg_pend, dbg_mr;

        // ---- behavioral pipelined DDR model (as mem_shim_burst_tb) ----
        reg [63:0] ddr_mem [0:MEMW-1];
        localparam RD_LATENCY = 12;
        localparam BQD = 8;
        reg [21:0] bq_addr [0:BQD-1];
        integer    bq_cnt  [0:BQD-1];
        integer    bq_wr = 0, bq_rd = 0, bq_n = 0;
        integer    rd_lat = 0, rd_beats = 0;
        reg [21:0] rd_ptr = 0;
        integer    seed = (g == 0) ? 32'h0AB0_5EED : 32'h1CEB_00DA;  // per-rig seeds
        reg        stall_en = 1'b0;
        reg        pop;

        wire acc_rd = ddr_read  && !ddr_waitrequest;
        wire acc_wr = ddr_write && !ddr_waitrequest;

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
                ddr_waitrequest <= stall_en ? (($random(seed) % 4) == 0) : 1'b0;
                if (!ddr_waitrequest) begin
                    if (ddr_write) ddr_mem[ddr_addr[21:0]] <= ddr_writedata;
                    if (ddr_read) begin
                        bq_addr[bq_wr] <= ddr_addr[21:0];
                        bq_cnt [bq_wr] <= ddr_burstcnt;
                        bq_wr <= (bq_wr + 1) % BQD;
                    end
                end
                if (rd_beats == 0) begin
                    ddr_readdatavalid <= 1'b0;
                    if (bq_n > 0) begin
                        rd_ptr   <= bq_addr[bq_rd];
                        rd_beats <= bq_cnt [bq_rd];
                        rd_lat   <= RD_LATENCY;
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
                    if (rd_beats == 1) begin
                        if (bq_n > 0) begin
                            rd_ptr   <= bq_addr[bq_rd];
                            rd_beats <= bq_cnt [bq_rd];
                            rd_lat   <= 0;
                            bq_rd    <= (bq_rd + 1) % BQD;
                            pop = 1'b1;
                        end
                    end
                end
                bq_n <= bq_n + (acc_rd ? 1 : 0) - (pop ? 1 : 0);
            end
        end

        // ---- capture: burst sequence, write count, response sequence ----
        always @(posedge clk) if (rst_n) begin
            if (acc_rd) begin
                cap_burst[g][cap_bn[g]] <= ddr_addr[21:0];
                cap_bn[g] <= cap_bn[g] + 1;
            end
            if (acc_wr) cap_wn[g] <= cap_wn[g] + 1;
            if (res_en) begin
                cap_resp[g][cap_rn[g]] <= res_dta;
                cap_rn[g] <= cap_rn[g] + 1;
            end
        end
    end
    endgenerate

    // ---- the two DUTs (shipping geometry) ----
    mem_shim_burst_ref #(.NSETS(NSETS), .ASSOC(4), .LINEW(LINEW)) dut_ref (
        .clk(clk), .rst_n(rst_n), .hard_rst_n(rst_n),
        .cwf_en(1'b`MSAB_CWF), .dual_en(1'b`MSAB_DUAL),
        .mem_req_rd_cmd(rig[0].req_cmd), .mem_req_rd_addr(rig[0].req_addr),
        .mem_req_rd_dta(rig[0].req_dta),
        .mem_req_rd_en(rig[0].req_en), .mem_req_rd_valid(rig[0].req_valid),
        .mem_res_wr_dta(rig[0].res_dta), .mem_res_wr_en(rig[0].res_en),
        .mem_res_wr_almost_full(rig[0].res_almost_full),
        .ddr3_addr(rig[0].ddr_addr), .ddr3_burstcnt(rig[0].ddr_burstcnt),
        .ddr3_read(rig[0].ddr_read), .ddr3_write(rig[0].ddr_write),
        .ddr3_writedata(rig[0].ddr_writedata), .ddr3_byteenable(rig[0].ddr_byteenable),
        .ddr3_readdata(rig[0].ddr_readdata), .ddr3_readdatavalid(rig[0].ddr_readdatavalid),
        .ddr3_waitrequest(rig[0].ddr_waitrequest),
        .debug_state(rig[0].dbg_state), .debug_saved_cmd(rig[0].dbg_saved_cmd),
        .debug_sdram_busy(rig[0].dbg_busy), .debug_sdram_ack(rig[0].dbg_ack),
        .debug_rd_count(rig[0].dbg_rd), .debug_wr_count(rig[0].dbg_wr),
        .debug_rsp_count(rig[0].dbg_rsp), .debug_read_pend_cycles(rig[0].dbg_pend),
        .debug_cache_missrate(rig[0].dbg_mr)
    );
    mem_shim_burst #(.NSETS(NSETS), .ASSOC(4), .LINEW(LINEW)) dut_new (
        .clk(clk), .rst_n(rst_n), .hard_rst_n(rst_n),
        .cwf_en(1'b`MSAB_CWF), .dual_en(1'b`MSAB_DUAL),
        .mem_req_rd_cmd(rig[1].req_cmd), .mem_req_rd_addr(rig[1].req_addr),
        .mem_req_rd_dta(rig[1].req_dta),
        .mem_req_rd_en(rig[1].req_en), .mem_req_rd_valid(rig[1].req_valid),
        .mem_res_wr_dta(rig[1].res_dta), .mem_res_wr_en(rig[1].res_en),
        .mem_res_wr_almost_full(rig[1].res_almost_full),
        .ddr3_addr(rig[1].ddr_addr), .ddr3_burstcnt(rig[1].ddr_burstcnt),
        .ddr3_read(rig[1].ddr_read), .ddr3_write(rig[1].ddr_write),
        .ddr3_writedata(rig[1].ddr_writedata), .ddr3_byteenable(rig[1].ddr_byteenable),
        .ddr3_readdata(rig[1].ddr_readdata), .ddr3_readdatavalid(rig[1].ddr_readdatavalid),
        .ddr3_waitrequest(rig[1].ddr_waitrequest),
        .debug_state(rig[1].dbg_state), .debug_saved_cmd(rig[1].dbg_saved_cmd),
        .debug_sdram_busy(rig[1].dbg_busy), .debug_sdram_ack(rig[1].dbg_ack),
        .debug_rd_count(rig[1].dbg_rd), .debug_wr_count(rig[1].dbg_wr),
        .debug_rsp_count(rig[1].dbg_rsp), .debug_read_pend_cycles(rig[1].dbg_pend),
        .debug_cache_missrate(rig[1].dbg_mr)
    );

    // ---- stimulus ----
    integer j, k, base, ra;
    integer tseed = 32'h7EA_C0DE;
    initial begin
        cap_bn[0] = 0; cap_bn[1] = 0;
        cap_rn[0] = 0; cap_rn[1] = 0;
        cap_wn[0] = 0; cap_wn[1] = 0;
        for (k = 0; k < MEMW; k = k + 1) begin
            ref_mem[k] = 64'd0;
            rig[0].ddr_mem[k] = 64'd0;
            rig[1].ddr_mem[k] = 64'd0;
        end

        // Phase 1: warm + re-read (hit streaming with stage-B touches)
        base = 22'h001000;
        for (j = 0; j < 64; j = j + 1) enqueue_write(base + j, {32'hA100_0000 + j, j[31:0]});
        for (j = 0; j < 64; j = j + 1) enqueue_read (base + j);
        for (j = 0; j < 64; j = j + 1) enqueue_read (base + j);

        // Phase 2: 6-stream same-set interleave (the LRU stress: 6 tags compete
        // for 4 ways of the same sets, victim choice decides every future miss)
        for (j = 0; j < 6; j = j + 1)
            for (k = 0; k < 64; k = k + 1)
                enqueue_write(22'h010000 + j*(NSETS*LINEW) + k, {32'h5200_0000 + j, k[31:0]});
        for (k = 0; k < 64; k = k + 1)
            for (j = 0; j < 6; j = j + 1)
                enqueue_read(22'h010000 + j*(NSETS*LINEW) + k);

        // Phase 3: random aliasing mix — reads/writes confined to 8 tag-aliases
        // of a 2-set window so victim selection churns constantly; write hits
        // exercise the S_WR_CMD touch path.
        for (j = 0; j < 1200; j = j + 1) begin
            ra = 22'h020000 + ($random(tseed) % (2*LINEW))            // 2 sets
                           + (($random(tseed) % 8) * (NSETS*LINEW));  // 8 aliases
            if (($random(tseed) % 3) == 0) enqueue_write(ra, {$random(tseed), $random(tseed)});
            else                           enqueue_read (ra);
        end

        // Phase 4: ADDR_ERR sprinkled into a hit/miss mix
        enqueue_read(ADDR_ERR);
        for (j = 0; j < 8; j = j + 1) begin
            enqueue_read (base + j);
            enqueue_read (ADDR_ERR);
            enqueue_write(ADDR_ERR, 64'hFFFF_FFFF_FFFF_FFFF);
            enqueue_read (22'h030000 + j*LINEW);
            enqueue_write(22'h030000 + j*LINEW, {32'h4400_0000 + j, j[31:0]});
            enqueue_read (22'h030000 + j*LINEW);
        end

        // Phase 5: dual-outstanding shapes — pairable (different-set) miss runs,
        // then same-set miss runs (never pairable), then miss->hit->miss->write.
        base = 22'h040000;
        for (j = 0; j < 48*LINEW; j = j + 1) enqueue_write(base + j, {32'h6600_0000 + j, j[31:0]});
        for (j = 0; j < 48; j = j + 1) enqueue_read(base + j*LINEW);
        for (j = 0; j < 12; j = j + 1)
            enqueue_write(22'h050000 + j*(NSETS*LINEW), {32'h5A00_0000 + j, j[31:0]});
        for (j = 0; j < 12; j = j + 1) enqueue_read(22'h050000 + j*(NSETS*LINEW));
        for (j = 0; j < 8; j = j + 1) begin
            enqueue_read (base + j*LINEW);        // hit (warmed above)
            enqueue_read (22'h060000 + j*LINEW);  // fresh miss
            enqueue_write(22'h060000 + j*LINEW, {32'h7700_0000 + j, j[31:0]});
            enqueue_read (22'h060000 + j*LINEW);  // read-after-write
        end

        // Phase 6: broad random mix (final policy soak)
        for (j = 0; j < 2000; j = j + 1) begin
            ra = ($random(tseed) % 4000) & 22'h3FFFF;
            if (($random(tseed) % 4) == 0) enqueue_write(ra, {$random(tseed), $random(tseed)});
            else                           enqueue_read (ra);
        end

        // go (random stalls active from the start on BOTH rigs, different seeds)
        rig[0].stall_en = 1'b1;
        rig[1].stall_en = 1'b1;
        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1;

        // wait until both rigs have consumed + answered everything
        for (j = 0; j < 400000; j = j + 1) begin
            @(posedge clk);
            if ((cap_rn[0] >= exp_count) && (cap_rn[1] >= exp_count)) j = 400000;
        end
        repeat (50) @(posedge clk);

        // ---- compare ----
        $display("=================================================");
        $display("mem_shim_ab_tb (cwf=%0d dual=%0d): %0d cmds, %0d reads",
                 `MSAB_CWF, `MSAB_DUAL, q_count, exp_count);
        $display("  REF: bursts=%0d resp=%0d writes=%0d | NEW: bursts=%0d resp=%0d writes=%0d",
                 cap_bn[0], cap_rn[0], cap_wn[0], cap_bn[1], cap_rn[1], cap_wn[1]);

        if (cap_rn[0] !== exp_count || cap_rn[1] !== exp_count) begin
            $display("  ERROR: response counts (exp %0d)", exp_count);
            errors = errors + 1;
        end
        if (cap_bn[0] !== cap_bn[1]) begin
            $display("  ERROR: miss counts differ (REF %0d vs NEW %0d)", cap_bn[0], cap_bn[1]);
            errors = errors + 1;
        end
        if (cap_wn[0] !== cap_wn[1]) begin
            $display("  ERROR: write counts differ (REF %0d vs NEW %0d)", cap_wn[0], cap_wn[1]);
            errors = errors + 1;
        end
        for (j = 0; j < ((cap_bn[0] < cap_bn[1]) ? cap_bn[0] : cap_bn[1]); j = j + 1)
            if (cap_burst[0][j] !== cap_burst[1][j]) begin
                if (errors < 12)
                    $display("  ERROR burst#%0d: REF %h vs NEW %h", j, cap_burst[0][j], cap_burst[1][j]);
                errors = errors + 1;
            end
        for (j = 0; j < exp_count; j = j + 1) begin
            if (j < cap_rn[0] && cap_resp[0][j] !== exp_dta[j]) begin
                if (errors < 12)
                    $display("  ERROR REF resp#%0d: got %h exp %h", j, cap_resp[0][j], exp_dta[j]);
                errors = errors + 1;
            end
            if (j < cap_rn[1] && cap_resp[1][j] !== exp_dta[j]) begin
                if (errors < 12)
                    $display("  ERROR NEW resp#%0d: got %h exp %h", j, cap_resp[1][j], exp_dta[j]);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("  RESULT: PASS — burst sequences identical (%0d misses), all responses correct", cap_bn[0]);
        else
            $display("  RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("  RESULT: FAIL — global timeout. REF state=%0d %0d/%0d, NEW state=%0d %0d/%0d",
                 rig[0].dbg_state, cap_rn[0], exp_count, rig[1].dbg_state, cap_rn[1], exp_count);
        $finish;
    end
endmodule
