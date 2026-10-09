// =============================================================================
// bench/dvd/mem_req_prefetch_tb.sv — contract bench for dvd/mem_req_prefetch.sv
// =============================================================================
// The queue between framestore's request FIFO and the DDR3 bridge must keep the
// FIFO's standard read contract exactly, because the bridge's speculative pop and
// skid are built on it. Real xilinx_fifo_dc in front, written at 54 MHz and read
// at 90 MHz like the decoder's (clk_dec -> clk_mem), the queue behind it, and a
// consumer that pops at random. Every word carries a sequence number and an epoch
// (bumped at each reset). Scored arms, each with its own counter:
//   ORDER      every delivered word is the next one written, in its epoch (no drop,
//              no dup, no reorder), checked with !==.
//   EAGER      dn_valid only on the cycle after a dn_rd_en (the bridge parks or
//              consumes exactly the words it popped; an unrequested word is lost).
//   TPUT       a primed queue under continuous dn_rd_en delivers >= 39 words in the
//              40 cycles after the first (one word per cycle on a hit stream).
//   STALE      after a mid-stream reset (FIFO and queue together, as framestore
//              wires them) no word written before the reset is ever delivered.
//   COUNT      after the final drain every post-reset word was delivered.
// -DMRP_RST_POR puts the queue on a power-on-only reset (the wiring mistake): STALE.
// Mutations (bench/dvd/run_mem_prefetch.sh --red) must each fail their own arm.
//
// Build: see bench/dvd/run_mem_prefetch.sh.
// =============================================================================
`timescale 1ns/1ps
module mem_req_prefetch_tb;
`ifndef MRP_D
 `define MRP_D 4
`endif
    localparam W = 88;

    reg wclk = 0, rclk = 0;
    always #9.259 wclk = ~wclk;     // 54 MHz
    always #5.555 rclk = ~rclk;     // 90 MHz

    reg rst = 0;                    // active low, like framestore's rst

    // ---- producer (wr side) ----
    reg  [W-1:0] din = 0;
    reg          wr_en = 0;
    wire         full, prog_full;
    // ---- FIFO -> queue ----
    wire [W-1:0] f_dout;
    wire         f_rd_en, f_valid;
    // ---- queue -> consumer ----
    reg          dn_rd_en = 0;
    wire         dn_valid;
    wire [W-1:0] dn_dout;

    xilinx_fifo_dc #(.dta_width(9'd88), .addr_width(9'd6), .prog_thresh(9'd8)) fifo (
        .rst(rst), .wr_clk(wclk), .din(din), .wr_en(wr_en), .full(full),
        .wr_ack(), .overflow(), .prog_full(prog_full),
        .rd_clk(rclk), .dout(f_dout), .rd_en(f_rd_en), .empty(), .valid(f_valid),
        .underflow(), .prog_empty());

    // The queue shares the FIFO's reset, as framestore wires it. -DMRP_RST_POR models
    // the wiring mistake the design rules out: the queue on a power-on-only reset
    // (emu's reset_n), which a soft/watchdog reset of the decoder does not reach.
    reg rst_por = 0;
`ifdef MRP_RST_POR
    wire dut_rst = rst_por;
`else
    wire dut_rst = rst;
`endif
    mem_req_prefetch #(.W(W), .D(`MRP_D)) dut (
        .clk(rclk), .rst(dut_rst),
        .up_rd_en(f_rd_en), .up_valid(f_valid), .up_dout(f_dout),
        .dn_rd_en(dn_rd_en), .dn_valid(dn_valid), .dn_dout(dn_dout));

    // word = {epoch[1:0] in the cmd field, 22'h0, seq[63:0]} — the seq is the payload
    function automatic [W-1:0] word(input [1:0] ep, input [63:0] seq);
        word = {ep, 22'h15A5A ^ seq[21:0], seq ^ 64'h0F0F_0000_0000_0000};
    endfunction

    // ---- producer process ----
    integer      gap_pct = 50;      // % of wclk cycles with no write attempt
    reg          produce = 0;
    reg   [1:0]  epoch = 0;
    reg  [63:0]  wseq  = 0;         // next seq to write in this epoch
    integer      written [0:3];
    integer      pseed = 32'h51DE_0001;
    always @(posedge wclk) begin
        if (!rst) begin
            wr_en <= 1'b0;
        end else if (produce && !prog_full && (($urandom(pseed) % 100) >= gap_pct)) begin
            // throttle on prog_full (8 free slots of margin), as framestore does on its
            // almost_full: `full` is registered, so a wr_en raised off a stale !full
            // can be refused while the sequence number has already advanced.
            din   <= word(epoch, wseq);
            wr_en <= 1'b1;
            wseq  <= wseq + 1;
            written[epoch] = written[epoch] + 1;
        end else begin
            wr_en <= 1'b0;
        end
    end

    // ---- consumer + scoreboard (rd side) ----
    integer pop_pct = 50;           // % of rclk cycles asserting dn_rd_en
    reg     consume = 0;
    reg     force_pop = 0;          // continuous pop (TPUT / drain)
    integer cseed = 32'h0C0F_FEE1;
    reg     prev_rd_en = 0;
    reg  [63:0] rseq [0:3];         // next expected seq per epoch
    integer delivered [0:3];
    integer err_order = 0, err_eager = 0, err_tput = 0, err_stale = 0, err_count = 0;
    reg  [1:0] min_epoch = 0;       // epochs below this were reset away
    integer i;

    always @(posedge rclk) begin
        // contract checks on what the queue presents THIS cycle
        if (rst && dn_valid) begin
            if (!prev_rd_en) begin
                if (err_eager < 4) $display("  EAGER: dn_valid without a dn_rd_en the cycle before (t=%0t)", $time);
                err_eager = err_eager + 1;
            end
            if (dn_dout[87:86] < min_epoch) begin
                if (err_stale < 4) $display("  STALE: epoch %0d word delivered after its reset (t=%0t)", dn_dout[87:86], $time);
                err_stale = err_stale + 1;
            end else if (dn_dout !== word(dn_dout[87:86], rseq[dn_dout[87:86]])) begin
                if (err_order < 4) $display("  ORDER: got %h, expected epoch %0d seq %0d (t=%0t)",
                                            dn_dout, dn_dout[87:86], rseq[dn_dout[87:86]], $time);
                err_order = err_order + 1;
                rseq[dn_dout[87:86]] = (dn_dout[63:0] ^ 64'h0F0F_0000_0000_0000) + 1;   // resync
            end else begin
                rseq[dn_dout[87:86]] = rseq[dn_dout[87:86]] + 1;
            end
            delivered[dn_dout[87:86]] = delivered[dn_dout[87:86]] + 1;
        end
        // next cycle's pop
        if (!rst) dn_rd_en <= 1'b0;
        else      dn_rd_en <= force_pop || (consume && (($urandom(cseed) % 100) < pop_pct));
        prev_rd_en <= rst ? dn_rd_en : 1'b0;
    end

    // ---- throughput measurement ----
    task automatic measure_tput;
        integer c, n, started;
        begin
            n = 0; started = 0;
            for (c = 0; c < 200 && n < 40; c = c + 1) begin
                @(posedge rclk);
                if (dn_valid) started = 1;
                if (started) n = n + 1;           // cycles since the first word
                if (started && !dn_valid) err_tput = err_tput + 1;   // a bubble
            end
            if (!started) err_tput = err_tput + 100;
        end
    endtask

    integer tput_bubbles;
    initial begin
        for (i = 0; i < 4; i = i + 1) begin written[i] = 0; delivered[i] = 0; rseq[i] = 0; end

        rst = 0; repeat (5) @(posedge wclk); rst = 1; rst_por = 1;
        repeat (5) @(posedge rclk);

        // P1: random supply, random demand
        produce = 1; consume = 1; gap_pct = 50; pop_pct = 50;
        repeat (6000) @(posedge rclk);
        gap_pct = 10; pop_pct = 20;               // backlog: queue full, FIFO backing up
        repeat (2000) @(posedge rclk);
        gap_pct = 70; pop_pct = 95;               // starved: queue runs dry repeatedly
        repeat (2000) @(posedge rclk);

        // P2: throughput — prime (consumer off), then pop every cycle
        consume = 0; gap_pct = 0;
        repeat (400) @(posedge rclk);
        produce = 0;
        repeat (20) @(posedge rclk);
        @(posedge rclk) force_pop = 1;
        measure_tput;
        tput_bubbles = err_tput;
        force_pop = 0;
        $display("  TPUT: %0d bubble(s) in the 40 cycles after the first word (D=%0d)", tput_bubbles, `MRP_D);
        if (tput_bubbles > 1) err_tput = tput_bubbles; else err_tput = 0;

        // P3: reset mid-stream with words in BOTH the FIFO and the queue
        produce = 1; gap_pct = 0; consume = 0;
        repeat (100) @(posedge rclk);             // queue full (consumer off), FIFO filling
        consume = 1; pop_pct = 30;
        repeat (17) @(posedge rclk);              // some popped, some in flight
        @(posedge wclk) begin produce = 0; end
        @(posedge wclk) rst = 0;                  // framestore's rst: wr-clock synchronous
        min_epoch = epoch + 1;
        repeat (3) @(posedge wclk);
        epoch = epoch + 1; wseq = 0;
        @(posedge wclk) rst = 1;
        produce = 1; consume = 1; gap_pct = 40; pop_pct = 60;
        repeat (5000) @(posedge rclk);

        // P4: drain
        produce = 0;
        repeat (20) @(posedge wclk);
        force_pop = 1;
        repeat (400) @(posedge rclk);
        force_pop = 0;
        repeat (10) @(posedge rclk);

        if (delivered[epoch] != written[epoch]) begin
            $display("  COUNT: epoch %0d wrote %0d, delivered %0d", epoch, written[epoch], delivered[epoch]);
            err_count = err_count + 1;
        end
        if (delivered[0] < 1000) begin
            $display("  COUNT: epoch 0 delivered only %0d words (vacuous)", delivered[0]);
            err_count = err_count + 1;
        end

        $display("=================================================");
        $display("mem_req_prefetch_tb (D=%0d): epoch0 wrote %0d delivered %0d | epoch1 wrote %0d delivered %0d",
                 `MRP_D, written[0], delivered[0], written[1], delivered[1]);
        $display("  ARM ORDER: %s (%0d)", err_order == 0 ? "PASS" : "FAIL", err_order);
        $display("  ARM EAGER: %s (%0d)", err_eager == 0 ? "PASS" : "FAIL", err_eager);
        $display("  ARM TPUT: %s (%0d)", err_tput  == 0 ? "PASS" : "FAIL", err_tput);
        $display("  ARM STALE: %s (%0d)", err_stale == 0 ? "PASS" : "FAIL", err_stale);
        $display("  ARM COUNT: %s (%0d)", err_count == 0 ? "PASS" : "FAIL", err_count);
        if (err_order + err_eager + err_tput + err_stale + err_count == 0) begin
            $display("  RESULT: PASS");
            $finish;
        end
        $fatal(1, "  RESULT: FAIL");
    end

    initial begin
        #20_000_000;
        $fatal(1, "  RESULT: FAIL -- global timeout");
    end
endmodule
