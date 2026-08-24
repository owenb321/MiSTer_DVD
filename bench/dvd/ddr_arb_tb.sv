// ddr_arb_tb.sv — testbench for dvd/ddr_arb.sv
//
// Verifies the two-master DDRAM arbiter: audio writes land, the decoder keeps
// priority, decoder burst reads return correct data, and — the key case — an
// audio write CANNOT interleave into a GAPPED decoder write burst.
//
//   iverilog -g2012 -o bench/dvd/ddr_arb_sim dvd/ddr_arb.sv bench/dvd/ddr_arb_tb.sv
//   vvp bench/dvd/ddr_arb_sim

`timescale 1ns/1ps
`default_nettype none

module ddr_arb_tb;

    localparam AUD_BASE = 29'h0700000;   // word address of the audio window

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // decoder master
    logic [28:0] dec_address = 0;
    logic  [7:0] dec_burstcount = 1;
    logic        dec_read = 0, dec_write = 0;
    logic [63:0] dec_writedata = 0;
    logic  [7:0] dec_byteenable = 8'hFF;
    wire         dec_waitrequest;
    wire  [63:0] dec_readdata;
    wire         dec_readdatavalid;

    // audio master (driven by the clocked server below)
    logic [28:0] aud_address = 0;
    logic  [7:0] aud_burstcount = 1;
    logic        aud_write = 0;
    logic [63:0] aud_writedata = 0;
    logic  [7:0] aud_byteenable = 8'hFF;
    wire         aud_waitrequest;

    // slave side
    wire [28:0] ddr_address;
    wire  [7:0] ddr_burstcount;
    wire        ddr_read, ddr_write;
    wire [63:0] ddr_writedata;
    wire  [7:0] ddr_byteenable;
    logic       ddr_waitrequest = 0;   // TB-controlled backpressure
    logic [63:0] ddr_readdata = 0;
    logic        ddr_readdatavalid = 0;

    integer errors = 0;

    ddr_arb dut (
        .clk(clk), .rst_n(rst_n),
        .dec_address(dec_address), .dec_burstcount(dec_burstcount),
        .dec_read(dec_read), .dec_write(dec_write),
        .dec_writedata(dec_writedata), .dec_byteenable(dec_byteenable),
        .dec_waitrequest(dec_waitrequest), .dec_readdata(dec_readdata),
        .dec_readdatavalid(dec_readdatavalid),
        .aud_address(aud_address), .aud_burstcount(aud_burstcount),
        .aud_write(aud_write), .aud_writedata(aud_writedata),
        .aud_byteenable(aud_byteenable), .aud_waitrequest(aud_waitrequest),
        .ddr_address(ddr_address), .ddr_burstcount(ddr_burstcount),
        .ddr_read(ddr_read), .ddr_write(ddr_write),
        .ddr_writedata(ddr_writedata), .ddr_byteenable(ddr_byteenable),
        .ddr_waitrequest(ddr_waitrequest), .ddr_readdata(ddr_readdata),
        .ddr_readdatavalid(ddr_readdatavalid)
    );

    // ---------------- behavioral DDR slave model ----------------
    // sparse memory as a small key/value store (iverilog has no assoc arrays)
    logic [28:0] kv_key [0:255];
    logic [63:0] kv_val [0:255];
    integer      kv_n = 0;
    integer      wb;                       // remaining write-burst beats (slave view)
    logic [28:0] waddr;                    // running write address within a burst

    function automatic [63:0] mem_rd(input [28:0] a);
        integer i; begin
            mem_rd = 64'bx;
            for (i = 0; i < kv_n; i = i + 1) if (kv_key[i] == a) mem_rd = kv_val[i];
        end
    endfunction

    task automatic mem_wr(input [28:0] a, input [63:0] d);
        integer i; logic found; begin
            found = 0;
            for (i = 0; i < kv_n; i = i + 1) if (kv_key[i] == a) begin kv_val[i] = d; found = 1; end
            if (!found) begin kv_key[kv_n] = a; kv_val[kv_n] = d; kv_n = kv_n + 1; end
        end
    endtask

    // write log (for ordering checks)
    logic [28:0] wlog_addr [0:255];
    logic [63:0] wlog_data [0:255];
    integer      wlog_n = 0;

    // single-outstanding burst-read response
    logic [63:0] rq [0:255];
    integer      rq_n = 0, rq_i = 0, rq_lat = 0;
    localparam   RD_LAT = 3;

    task automatic apply_write(input [28:0] a, input [63:0] d);
        begin
            mem_wr(a, d);
            wlog_addr[wlog_n] = a;
            wlog_data[wlog_n] = d;
            wlog_n = wlog_n + 1;
        end
    endtask

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb <= 0; rq_n <= 0; rq_i <= 0; rq_lat <= 0; ddr_readdatavalid <= 0;
        end else begin
            // ---- command acceptance ----
            if (!ddr_waitrequest) begin
                if (ddr_write) begin
                    if (wb != 0 && ddr_read) begin
                        $display("  FAIL: read issued mid write-burst"); errors = errors + 1;
                    end
                    if (wb == 0) begin                  // first beat of a (possibly 1-beat) burst
                        apply_write(ddr_address, ddr_writedata);
                        waddr <= ddr_address + 29'd1;
                        wb    <= (ddr_burstcount > 8'd1) ? (ddr_burstcount - 8'd1) : 8'd0;
                    end else begin                      // continuation beat
                        apply_write(waddr, ddr_writedata);
                        waddr <= waddr + 29'd1;
                        wb    <= wb - 8'd1;
                    end
                end else if (ddr_read) begin
                    if (wb != 0) begin
                        $display("  FAIL: read accepted mid write-burst"); errors = errors + 1;
                    end
                    for (k = 0; k < ddr_burstcount; k = k + 1)
                        rq[k] = mem_rd(ddr_address + k[28:0]);
                    rq_n   <= ddr_burstcount;
                    rq_i   <= 0;
                    rq_lat <= RD_LAT;
                end
            end

            // ---- read response delivery ----
            ddr_readdatavalid <= 0;
            if (rq_n != 0) begin
                if (rq_lat != 0) rq_lat <= rq_lat - 1;
                else begin
                    ddr_readdata      <= rq[rq_i];
                    ddr_readdatavalid <= 1;
                    rq_i <= rq_i + 1;
                    rq_n <= rq_n - 1;
                end
            end
        end
    end

    // ---------------- audio master server ----------------
    // Hold aud_write while a request is pending; clear when the arbiter accepts.
    logic        aud_pending = 0;
    logic [28:0] aud_req_addr;
    logic [63:0] aud_req_data;
    integer      aud_landed = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aud_write <= 0; aud_pending <= 0; aud_landed <= 0;
        end else begin
            if (aud_pending) begin
                aud_write      <= 1;
                aud_address    <= aud_req_addr;
                aud_writedata  <= aud_req_data;
                aud_burstcount <= 8'd1;
                aud_byteenable <= 8'hFF;
                if (aud_write && !aud_waitrequest) begin  // accepted this cycle
                    aud_pending <= 0;
                    aud_write   <= 0;
                    aud_landed  <= aud_landed + 1;
                end
            end
        end
    end

    task automatic aud_post(input [28:0] a, input [63:0] d);
        begin
            @(negedge clk);
            aud_req_addr = a;
            aud_req_data = d;
            aud_pending  = 1;
        end
    endtask

    // ---------------- decoder master tasks ----------------
    task automatic dec_idle_cyc(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                dec_read = 0; dec_write = 0;
            end
        end
    endtask

    task automatic dec_write1(input [28:0] a, input [63:0] d);
        begin
            @(negedge clk);
            dec_address = a; dec_writedata = d; dec_burstcount = 8'd1;
            dec_write = 1; dec_read = 0;
            @(posedge clk);
            while (dec_waitrequest) @(posedge clk);  // wait until accepted
            @(negedge clk);
            dec_write = 0;
        end
    endtask

    // 4-beat write burst with a 1-cycle gap after beat 2 (stresses no-interleave)
    task automatic dec_burst4_gapped(input [28:0] a);
        integer beat;
        begin
            for (beat = 0; beat < 4; beat = beat + 1) begin
                @(negedge clk);
                dec_address    = a;                 // address only matters on beat 0
                dec_writedata  = 64'hD00D_0000 + beat;
                dec_burstcount = 8'd4;
                dec_write      = 1; dec_read = 0;
                @(posedge clk);
                while (dec_waitrequest) @(posedge clk);
                if (beat == 1) begin                // GAP after beat 2
                    @(negedge clk);
                    dec_write = 0;
                    @(negedge clk);                 // one idle cycle mid-burst
                    @(negedge clk);                 // (audio is pending here)
                end
            end
            @(negedge clk);
            dec_write = 0;
        end
    endtask

    task automatic dec_read_burst(input [28:0] a, input integer n);
        integer got;
        begin
            @(negedge clk);
            dec_address = a; dec_burstcount = n[7:0]; dec_read = 1; dec_write = 0;
            @(posedge clk);
            while (dec_waitrequest) @(posedge clk);
            @(negedge clk);
            dec_read = 0;
            // collect n response beats and verify
            got = 0;
            while (got < n) begin
                @(posedge clk);
                if (dec_readdatavalid) begin
                    if (dec_readdata !== mem_rd(a + got[28:0])) begin
                        $display("  FAIL: read beat %0d got %h exp %h",
                                 got, dec_readdata, mem_rd(a + got[28:0]));
                        errors = errors + 1;
                    end
                    got = got + 1;
                end
            end
        end
    endtask

    // ---------------- helper checks ----------------
    function automatic integer find_wlog(input [28:0] a);
        integer i; begin
            find_wlog = -1;
            for (i = 0; i < wlog_n; i = i + 1)
                if (wlog_addr[i] == a) find_wlog = i;  // last match
        end
    endfunction

    integer i0, i1, i2, i3, ia, base_idx;

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ===== TEST 1: audio write lands when the bus is idle =====
        $display("[TEST 1] lone audio write");
        aud_post(AUD_BASE, 64'hAAAA_BBBB_CCCC_DDDD);
        dec_idle_cyc(8);
        if (aud_landed != 1) begin $display("  FAIL: audio not accepted"); errors=errors+1; end
        if (mem_rd(AUD_BASE) !== 64'hAAAA_BBBB_CCCC_DDDD) begin
            $display("  FAIL: audio data wrong: %h", mem_rd(AUD_BASE)); errors=errors+1;
        end else $display("  audio landed OK");

        // ===== TEST 2: decoder single writes proceed; audio waits its turn =====
        $display("[TEST 2] decoder priority + audio interleave at idle");
        aud_post(AUD_BASE + 1, 64'h1111_2222_3333_4444);
        dec_write1(29'h0001000, 64'hDEAD_0001);
        dec_write1(29'h0001001, 64'hDEAD_0002);
        dec_idle_cyc(6);
        if (mem_rd(29'h0001000) !== 64'hDEAD_0001 || mem_rd(29'h0001001) !== 64'hDEAD_0002) begin
            $display("  FAIL: decoder writes wrong"); errors=errors+1;
        end
        if (aud_landed != 2 || mem_rd(AUD_BASE+1) !== 64'h1111_2222_3333_4444) begin
            $display("  FAIL: 2nd audio write missing"); errors=errors+1;
        end else $display("  decoder + audio both landed OK");

        // ===== TEST 3: GAPPED decoder write burst, audio pending — NO interleave =====
        $display("[TEST 3] gapped decoder write burst with audio pending");
        base_idx = wlog_n;
        aud_post(AUD_BASE + 2, 64'hFEED_FACE_0000_0001);  // pending before/through burst
        dec_burst4_gapped(29'h0002000);
        dec_idle_cyc(8);

        // decoder beats must be 4 contiguous writes to 0x2000..0x2003
        i0 = find_wlog(29'h0002000);
        i1 = find_wlog(29'h0002001);
        i2 = find_wlog(29'h0002002);
        i3 = find_wlog(29'h0002003);
        ia = find_wlog(AUD_BASE + 2);
        if (i0 < 0 || i1 != i0+1 || i2 != i0+2 || i3 != i0+3) begin
            $display("  FAIL: decoder burst not contiguous (idx %0d %0d %0d %0d)", i0,i1,i2,i3);
            errors = errors + 1;
        end else $display("  decoder burst contiguous at log idx %0d..%0d", i0, i3);
        if (ia <= i3) begin
            $display("  FAIL: audio write (idx %0d) interleaved into/ before burst end (idx %0d)", ia, i3);
            errors = errors + 1;
        end else $display("  audio write landed AFTER full burst (idx %0d)", ia);
        if (mem_rd(29'h0002003) !== 64'hD00D_0003) begin
            $display("  FAIL: burst beat 4 data wrong: %h", mem_rd(29'h0002003)); errors=errors+1;
        end
        if (mem_rd(AUD_BASE+2) !== 64'hFEED_FACE_0000_0001) begin
            $display("  FAIL: audio data wrong: %h", mem_rd(AUD_BASE+2)); errors=errors+1;
        end

        // ===== TEST 4: decoder burst read returns correct data =====
        $display("[TEST 4] decoder burst read");
        dec_read_burst(29'h0002000, 4);
        $display("  burst read verified");

        if (errors == 0) $display("\nALL TESTS PASSED");
        else             $display("\n%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
