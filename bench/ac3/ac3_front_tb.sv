//============================================================================
//  ac3_front_tb.sv — self-checking chain TB for the AC-3 front-end:
//  FIFO -> bit_reader -> sync_crc -> bsi_parse -> body skip -> resync.
//
//  Synthetic stream (no ffmpeg/liba52 dependency): two back-to-back AC-3
//  frames, each 768 bytes (frmsizcod=20 -> 384 words @ 48 kHz).  Each frame
//  carries a real syncinfo header AND a real BSI for acmod==2 / lfeon==0; the
//  rest of the body is zero (so no false 0x0B77 sync inside a frame).
//
//  Per frame:
//    0B 77        sync word
//    12 34        crc1
//    14           fscod=00, frmsizcod=010100=20
//    40 43 E1     BSI: bsid=8 bsmod=0 acmod=2 dsurmod=0 lfeon=0 dialnorm=31,
//                 all optional flags clear, origbs=1 (27 BSI bits).  These are
//                 byte-for-byte the bytes ffmpeg emits for a 48k stereo frame.
//    760x 00      zero body
//
//  Checks:
//    - frame 0 header: words=384, fscod=0, frmsizcod=20, crc1=0x1234,
//      sync_bitpos=16 (just past the 2 sync bytes).
//    - frame 0 BSI: bsid=8, bsmod=0, acmod=2, dsurmod=0, lfeon=0, dialnorm=31,
//      err_unsupported=0.
//    - frame 1 header is found at sync_bitpos = 6160 (= 768*8 + 16), which only
//      happens if (header parse + BSI parse + body skip) advanced by exactly one
//      frame.  This is the end-to-end proof of the parse+skip accounting.
//============================================================================

`timescale 1ns/1ps

module ac3_front_tb;

    localparam int FB = 768;          // bytes per frame
    localparam int NF = 2;
    localparam int N  = NF * FB;

    logic        clk = 0;
    logic        rst = 1;
    logic        wr_en;
    logic [7:0]  wr_data;
    logic        full;

    logic        synced, frame_hdr_valid, err_unsupported;
    logic [15:0] frame_words, frame_bytes, crc1;
    logic [1:0]  fscod;
    logic [5:0]  frmsizcod;
    logic [31:0] sync_bitpos;

    logic        bsi_valid;
    logic [4:0]  bsid, dialnorm;
    logic [2:0]  bsmod, acmod;
    logic [1:0]  dsurmod;
    logic        lfeon;

    logic        block_side_valid;
    logic [31:0] blk_bits;

    always #5 clk = ~clk;

    // Synthetic stream
    logic [7:0] stream [0:N-1];
    integer i, f;
    initial begin
        for (i = 0; i < N; i = i + 1) stream[i] = 8'h00;
        for (f = 0; f < NF; f = f + 1) begin
            stream[f*FB + 0] = 8'h0B;     // sync hi
            stream[f*FB + 1] = 8'h77;     // sync lo
            stream[f*FB + 2] = 8'h12;     // crc1 hi
            stream[f*FB + 3] = 8'h34;     // crc1 lo
            stream[f*FB + 4] = 8'h14;     // fscod=00, frmsizcod=010100=20
            stream[f*FB + 5] = 8'h40;     // BSI: bsid=8, bsmod=0, acmod=2...
            stream[f*FB + 6] = 8'h43;     //      ...dsurmod=0, lfeon=0, dialnorm=31
            stream[f*FB + 7] = 8'hE1;     //      compre/lang/audprod=0, origbs=1, tc=0
        end
    end

    // Combinational feed: write whenever there is data and the FIFO has room.
    integer fed = 0;
    assign wr_en   = (!rst) && (fed < N) && !full;
    assign wr_data = (fed < N) ? stream[fed] : 8'h00;
    always_ff @(posedge clk)
        if (rst) fed <= 0;
        else if (wr_en) fed <= fed + 1;

    // DUT (small FIFO so backpressure is exercised)
    ac3_front #(.FIFO_DEPTH(64)) dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_data(wr_data), .full(full),
        .synced(synced), .frame_hdr_valid(frame_hdr_valid),
        .frame_words(frame_words), .frame_bytes(frame_bytes),
        .fscod(fscod), .frmsizcod(frmsizcod), .crc1(crc1),
        .sync_bitpos(sync_bitpos),
        .bsi_valid(bsi_valid),
        .bsid(bsid), .bsmod(bsmod), .acmod(acmod), .dsurmod(dsurmod),
        .lfeon(lfeon), .dialnorm(dialnorm),
        .block_side_valid(block_side_valid), .blk_bits(blk_bits),
        .chincpl(), .cplstrtmant(), .cplendmant(), .ncplbnd(), .cplstrtbnd(),
        .phsflginu(), .rematflg(), .cplco_rd_addr(6'd0), .cplco_rd_data(),
        .exp_done(), .dexp_rd_addr(10'd0), .dexp_rd_data(),
        .pcm_done(1'b1),               // no output stage: never stall metering
        .err_unsupported(err_unsupported)
    );

    // Checker
    integer errors     = 0;
    integer seen       = 0;
    integer bsi_seen   = 0;
    integer block_seen = 0;

    task automatic chk(input cond, input [255:0] msg);
        if (!cond) begin errors = errors + 1; $display("  FAIL  %0s", msg); end
    endtask

    always @(posedge clk) begin
        if (!rst && frame_hdr_valid) begin
            if (seen == 0) begin
                $display("  frame 0: words=%0d fscod=%0d frmsizcod=%0d crc1=0x%04h bitpos=%0d",
                         frame_words, fscod, frmsizcod, crc1, sync_bitpos);
                chk(frame_words === 16'd384, "frame0 words != 384");
                chk(frame_bytes === 16'd768, "frame0 bytes != 768");
                chk(fscod       === 2'd0,    "frame0 fscod != 0");
                chk(frmsizcod   === 6'd20,   "frame0 frmsizcod != 20");
                chk(crc1        === 16'h1234,"frame0 crc1 != 0x1234");
                chk(sync_bitpos === 32'd16,  "frame0 sync_bitpos != 16");
                chk(err_unsupported === 1'b0,"frame0 err set");
            end else if (seen == 1) begin
                $display("  frame 1: words=%0d bitpos=%0d", frame_words, sync_bitpos);
                chk(frame_words === 16'd384,  "frame1 words != 384");
                chk(sync_bitpos === 32'd6160, "frame1 sync_bitpos != 6160");
            end
            seen = seen + 1;
        end

        if (!rst && bsi_valid) begin
            $display("  bsi %0d: bsid=%0d bsmod=%0d acmod=%0d dsurmod=%0d lfeon=%0d dialnorm=%0d",
                     bsi_seen, bsid, bsmod, acmod, dsurmod, lfeon, dialnorm);
            chk(bsid     === 5'd8,  "bsi bsid != 8");
            chk(bsmod    === 3'd0,  "bsi bsmod != 0");
            chk(acmod    === 3'd2,  "bsi acmod != 2");
            chk(dsurmod  === 2'd0,  "bsi dsurmod != 0");
            chk(lfeon    === 1'b0,  "bsi lfeon != 0");
            chk(dialnorm === 5'd31, "bsi dialnorm != 31");
            chk(err_unsupported === 1'b0, "bsi err_unsupported set");
            bsi_seen = bsi_seen + 1;
        end

        // audblk_parse runs all 6 blocks of each frame.  The synthetic body is
        // all zero -> 6 degenerate long blocks (both channels reuse, all flags
        // clear, no params): 15 side-info bits each, no out-of-scope field.  The
        // block loop (ac3_parse) advances through them, then length-skips the
        // remaining body and resyncs — so block_seen reaches NF*6.
        if (!rst && block_side_valid) begin
            $display("  block %0d: blk_bits=%0d", block_seen, blk_bits);
            chk(blk_bits === 32'd15, "audblk blk_bits != 15 (zero-body block)");
            chk(err_unsupported === 1'b0, "audblk err_unsupported set");
            block_seen = block_seen + 1;
        end
    end

    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("ac3_front_tb.vcd");
            $dumpvars(0, ac3_front_tb);
        end
        rst = 1;
        repeat (4) @(negedge clk);
        rst = 0;

        // run until both frames' header, BSI, AND all 6 blocks' side info are
        // parsed (or timeout).  block_side_valid follows bsi_valid each frame, so
        // waiting on the block counter implies header + BSI were seen first.
        wait (block_seen >= NF*6);
        repeat (4) @(negedge clk);

        $display("ac3_front_tb: %0d headers, %0d BSI, %0d blocks, %0d errors",
                 seen, bsi_seen, block_seen, errors);
        $display("RESULT: %0s",
                 (errors == 0 && seen == NF && bsi_seen == NF && block_seen == NF*6)
                 ? "PASS" : "FAIL");
        if (errors != 0 || seen != NF || bsi_seen != NF || block_seen != NF*6)
            $fatal(1, "ac3_front_tb FAILED");
        $finish;
    end

    initial begin
        #2000000;
        $display("RESULT: FAIL (timeout, seen=%0d)", seen);
        $fatal(1, "ac3_front_tb timeout");
    end

endmodule
