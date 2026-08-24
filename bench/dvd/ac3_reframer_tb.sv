//============================================================================
//  ac3_reframer_tb.sv — unit TB for dvd/ac3_reframer.sv (v2, length-locked)
//
//  Checks:
//   1. Byte stream is forwarded byte-for-byte (transparent passthrough).
//   2. For AC-3, out_frame_start pulses at each REAL AC-3 frame boundary and a
//      SPURIOUS in-payload 0x0B77 is REJECTED (frame-length lock).
//   3. A PES PTS is carried to the next regenerated AC-3 frame_start.
//   4. For non-AC-3 (type 2), in_frame_start passes through unchanged.
//
//  Frames are 128 bytes (fscod=0/48kHz, frmsizcod=0 -> 64 words = 128 bytes), the
//  smallest 48 kHz AC-3 frame: header [0]=0B [1]=77 [2..3]=crc [4]={fscod,frmsizcod}.
//============================================================================
`timescale 1ns/1ps

module ac3_reframer_tb;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n;

    logic [7:0]  in_byte;
    logic        in_valid;
    logic [1:0]  in_type;
    logic        in_frame_start;
    logic [32:0] in_frame_pts;
    logic        in_frame_pts_valid;

    wire [7:0]  out_byte;
    wire        out_valid;
    wire [1:0]  out_type;
    wire        out_frame_start;
    wire [32:0] out_frame_pts;
    wire        out_frame_pts_valid;

    ac3_reframer dut (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_type(in_type),
        .in_frame_start(in_frame_start),
        .in_frame_pts(in_frame_pts), .in_frame_pts_valid(in_frame_pts_valid),
        .out_byte(out_byte), .out_valid(out_valid), .out_type(out_type),
        .out_frame_start(out_frame_start),
        .out_frame_pts(out_frame_pts), .out_frame_pts_valid(out_frame_pts_valid)
    );

    localparam int CAP = 600;
    logic [7:0]  cb [0:CAP-1];
    logic        cs [0:CAP-1];
    logic        cpv[0:CAP-1];
    logic [32:0] cp [0:CAP-1];
    integer ncap = 0;

    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            cb[ncap]=out_byte; cs[ncap]=out_frame_start;
            cpv[ncap]=out_frame_pts_valid; cp[ncap]=out_frame_pts;
            ncap = ncap + 1;
        end
    end

    integer errs = 0, i;

    task send(input [7:0] b, input [1:0] ty, input fs, input pv, input [32:0] pts);
        begin
            @(posedge clk); #1;
            in_byte=b; in_type=ty; in_frame_start=fs; in_frame_pts=pts;
            in_frame_pts_valid=pv; in_valid=1'b1;
        end
    endtask

    // build the AC-3 stimulus: two 128-byte frames, spurious 0B77 at frame0[40..41]
    localparam [32:0] AA = 33'h0_0000_00AA;
    localparam [32:0] BB = 33'h0_0000_00BB;
    logic [7:0] seq [0:255];
    // per-input-byte side signals
    logic       fsv [0:255];
    logic       pvv [0:255];
    logic [32:0] ptv [0:255];

    initial begin
        for (i=0;i<256;i=i+1) begin seq[i]=8'hAA; fsv[i]=0; pvv[i]=0; ptv[i]=0; end
        // frame 0 header @0
        seq[0]=8'h0B; seq[1]=8'h77; seq[2]=8'h12; seq[3]=8'h34; seq[4]=8'h00;
        // spurious sync inside frame 0 payload (must be rejected)
        seq[40]=8'h0B; seq[41]=8'h77;
        // frame 1 header @128
        seq[128]=8'h0B; seq[129]=8'h77; seq[130]=8'h12; seq[131]=8'h34; seq[132]=8'h00;
        // PES boundaries: at stream start (PTS AA) and mid frame0 @60 (PTS BB)
        fsv[0]=1;  pvv[0]=1;  ptv[0]=AA;
        fsv[60]=1; pvv[60]=1; ptv[60]=BB;
    end

    initial begin
        in_valid=0; in_byte=0; in_type=0; in_frame_start=0;
        in_frame_pts=0; in_frame_pts_valid=0;
        rst_n=0; repeat(4) @(posedge clk); rst_n=1;

        // Phase 1: AC-3 stream (256 bytes) + one flush byte
        for (i=0;i<256;i=i+1) send(seq[i], 2'd0, fsv[i], pvv[i], ptv[i]);
        send(8'h00, 2'd0, 1'b0, 1'b0, 0);   // flush last held byte
        @(posedge clk); #1; in_valid=0; in_frame_start=0; in_frame_pts_valid=0;
        repeat(4) @(posedge clk);

        // checks: expect 256 emitted bytes == seq[0..255]
        if (ncap < 256) begin $display("FAIL: only %0d bytes emitted (<256)", ncap); errs=errs+1; end
        for (i=0;i<256 && i<ncap;i=i+1)
            if (cb[i] !== seq[i]) begin
                $display("FAIL byte %0d: got %02x exp %02x", i, cb[i], seq[i]); errs=errs+1;
            end
        // frame_start ONLY at emitted idx 0 and 128 (spurious @40 rejected)
        for (i=0;i<256 && i<ncap;i=i+1) begin
            logic exp_s; exp_s = (i==0) || (i==128);
            if (cs[i] !== exp_s) begin
                $display("FAIL frame_start idx %0d: got %0b exp %0b", i, cs[i], exp_s); errs=errs+1;
            end
        end
        // PTS: AA @0, BB @128
        for (i=0;i<256 && i<ncap;i=i+1) begin
            logic exp_pv; logic [32:0] exp_p;
            exp_pv = (i==0) || (i==128);
            exp_p  = (i==0) ? AA : (i==128) ? BB : 33'd0;
            if (cpv[i] !== exp_pv) begin
                $display("FAIL pts_valid idx %0d: got %0b exp %0b", i, cpv[i], exp_pv); errs=errs+1;
            end
            if (exp_pv && (cp[i] !== exp_p)) begin
                $display("FAIL pts idx %0d: got %h exp %h", i, cp[i], exp_p); errs=errs+1;
            end
        end

        // Phase 2: non-AC-3 (LPCM type 2) passthrough of frame_start
        ncap = 0;
        rst_n=0; repeat(3) @(posedge clk); rst_n=1;
        send(8'hA0, 2'd2, 1'b1, 1'b0, 0);   // LPCM frame_start
        send(8'hB1, 2'd2, 1'b0, 1'b0, 0);
        send(8'h0B, 2'd2, 1'b0, 1'b0, 0);   // 0B77 in LPCM data must NOT reframe
        send(8'h77, 2'd2, 1'b0, 1'b0, 0);
        send(8'hC2, 2'd2, 1'b1, 1'b0, 0);   // next LPCM frame_start
        send(8'h00, 2'd2, 1'b0, 1'b0, 0);   // flush
        @(posedge clk); #1; in_valid=0; in_frame_start=0;
        repeat(4) @(posedge clk);
        if (ncap < 5) begin $display("FAIL: LPCM phase only %0d bytes", ncap); errs=errs+1; end
        for (i=0;i<5 && i<ncap;i=i+1) begin
            logic exp_s; exp_s = (i==0) || (i==4);
            if (cs[i] !== exp_s) begin
                $display("FAIL LPCM frame_start idx %0d: got %0b exp %0b", i, cs[i], exp_s); errs=errs+1;
            end
        end

        if (errs == 0) $display("PASS: ac3_reframer v2 (length-locked reframing, spurious 0B77 rejected, PTS carry, LPCM passthrough)");
        else           $display("FAIL: %0d error(s)", errs);
        $finish;
    end
endmodule
