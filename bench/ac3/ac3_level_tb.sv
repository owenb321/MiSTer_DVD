//============================================================================
//  ac3_level_tb.sv -- END-TO-END OUTPUT LEVEL measurement for the AC-3 path.
//
//  Feeds a REAL .ac3 elementary stream through ac3_front -> pcm_out and dumps
//  the s16 stereo samples, so run_ac3_level.sh can compare the peak against
//  a52dec's decode of the SAME file.
//
//  ★ Why this exists.  Every other AC-3 gate compares pcm_mem, which sits
//    BEFORE pcm_out's level scalar, so none of them can see an output-level
//    error -- which is exactly how this fork shipped 6.02 dB below every normal
//    decoder without a single red test.  The reference here is an INDEPENDENT
//    DECODER (a52dec), not our own arithmetic, so it cannot agree with the RTL
//    by construction.
//
//  Plusargs:
//    +hex=<file>   one byte per line, hex -- the .ac3 elementary stream
//    +out=<file>   output: "<L> <R>" per line, decimal signed
//    +n=<count>    max sample pairs to emit (default 200000)
//============================================================================
`timescale 1ns/1ps

module ac3_level_tb;

    localparam int MAXB = 1 << 21;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    // ---- stream feed ----
    logic [7:0] mem [0:MAXB-1];
    integer     nbytes, wp;
    logic       wr_en;
    logic [7:0] wr_data;
    wire        fifo_full;

    // ---- ac3_front <-> pcm_out ----
    wire [10:0] pcm_rd_addr11;
    wire [8:0]  pcm_rd_addr9;
    wire signed [31:0] pcm_rd_data;
    wire [15:0] lvl_q_dut;
    // +lvl=<n> forces the scalar, so the PRE-FIX baseline (16384 == 1.0) can be
    // measured against the same reference without rebuilding the RTL.
    integer lvl_force;
    wire [15:0] lvl_q = (lvl_force != 0) ? lvl_force[15:0] : lvl_q_dut;
    wire        imdct_done, pcm_done_w, ac3_err;
    wire [2:0]  acmod;
    wire        mono = (acmod == 3'd1);

    assign pcm_rd_addr11 = {2'b00, pcm_rd_addr9};

    ac3_front #(.FIFO_DEPTH(2048)) front (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_data(wr_data), .full(fifo_full),
        .acmod(acmod),
        .imdct_done(imdct_done),
        .pcm_rd_addr(pcm_rd_addr11),
        .pcm_rd_data(pcm_rd_data),
        .lvl_q(lvl_q_dut),
        .pcm_done(pcm_done_w),
        .err_unsupported(ac3_err)
    );

    wire signed [15:0] audio_l, audio_r;
    wire        aud_valid;
    logic       aud_ce = 0;

    pcm_out #(.FIFO_AW(11)) pcm (
        .clk(clk), .rst(rst),
        .start(imdct_done), .mono(mono), .lvl_q(lvl_q),
        .pcm_rd_addr(pcm_rd_addr9), .pcm_rd_data(pcm_rd_data),
        .busy(), .done(pcm_done_w),
        .aud_clk(clk), .aud_rst(rst), .aud_ce(aud_ce),
        .audio_l(audio_l), .audio_r(audio_r), .aud_valid(aud_valid)
    );

    // drain at roughly one pair per 32 clocks -- fast enough to keep up, slow
    // enough that pcm_out's FIFO governs rather than the feed
    integer cediv = 0;
    always @(posedge clk) begin
        cediv <= (cediv == 31) ? 0 : cediv + 1;
        aud_ce <= (cediv == 31);
    end

    integer fout, npairs, nmax, peak, idle;
    // ★ The pair budget is counted from the FIRST NON-SILENT sample, not from
    // reset.  bbb_mono.ac3 opens with ~4200 samples of digital silence, so a
    // budget counted from zero stopped the capture before any audio arrived and
    // the gate measured peak=0.  Every pair is still WRITTEN, silence included,
    // because level_cmp.py aligns the two captures by index.
    integer nactive; reg started;
    reg [1023:0] hexf, outf;

    initial begin
        if (!$value$plusargs("hex=%s", hexf)) begin
            $display("FAIL: +hex=<file> required"); $fatal;
        end
        if (!$value$plusargs("out=%s", outf)) outf = "ac3_level_out.txt";
        if (!$value$plusargs("n=%d", nmax))   nmax = 4096;
        if (!$value$plusargs("lvl=%d", lvl_force)) lvl_force = 0;

        $readmemh(hexf, mem);
        nbytes = MAXB;
        while (nbytes > 0 && mem[nbytes-1] === 8'hxx) nbytes = nbytes - 1;

        fout = $fopen(outf, "w");
        peak = 0; npairs = 0; wp = 0; wr_en = 0; idle = 0;
        nactive = 0; started = 1'b0;

        repeat (10) @(posedge clk);
        rst = 0;
    end

    // feed bytes whenever the input FIFO has room
    always @(posedge clk) begin
        wr_en <= 1'b0;
        if (!rst && wp < nbytes && !fifo_full) begin
            wr_data <= mem[wp];
            wr_en   <= 1'b1;
            wp      <= wp + 1;
        end
    end

    // collect output
    always @(posedge clk) begin
        // No nmax guard here on purpose: the budget is owned by the finish
        // condition below, which counts from the first non-silent pair.  Guarding
        // the collector instead truncated the capture during the leading silence,
        // so `started` never set and the budget could never begin.
        if (!rst && aud_valid) begin
            $fwrite(fout, "%0d %0d\n", $signed(audio_l), $signed(audio_r));
            if ($signed(audio_l)  > peak) peak =  $signed(audio_l);
            if (-$signed(audio_l) > peak) peak = -$signed(audio_l);
            if ($signed(audio_r)  > peak) peak =  $signed(audio_r);
            if (-$signed(audio_r) > peak) peak = -$signed(audio_r);
            npairs = npairs + 1;
            if (!started && (audio_l !== 16'sd0 || audio_r !== 16'sd0)) started = 1'b1;
            if (started) nactive = nactive + 1;
        end
    end

    // Finish as soon as enough pairs are captured, or the feed has drained and
    // output has gone quiet.  ★ The pair cap matters: a 5.1 stream is five IMDCTs
    // per block and decoding a whole file takes minutes of wall clock, but a few
    // thousand pairs already give a solid median ratio -- so the cap is what makes
    // this gate usable rather than something nobody runs.
    always @(posedge clk) begin
        if (!rst) begin
            if (aud_valid) idle = 0;
            else           idle = idle + 1;
            if ((started && nactive >= nmax) || (wp >= nbytes && idle > 400000)) begin
                $display("ac3_level: acmod=%0d lvl_q=%0d (dut %0d) pairs=%0d active=%0d peak=%0d err=%0d",
                         acmod, lvl_q, lvl_q_dut, npairs, nactive, peak, ac3_err);
                $fclose(fout);
                $finish;
            end
        end
    end

    initial begin
        #2000000000;
        $display("ac3_level: TIMEOUT (pairs=%0d peak=%0d)", npairs, peak);
        $fclose(fout);
        $finish;
    end

endmodule
