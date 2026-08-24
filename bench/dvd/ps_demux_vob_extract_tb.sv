//============================================================================
//  ps_demux_vob_extract_tb.sv — feed a real VOB through ps_demux and dump the
//  extracted AC-3 audio bytes, to compare against ffmpeg's ground-truth AC-3.
//
//  Diagnostic for the choppy-AC-3 bring-up: proves whether ps_demux's AC-3
//  extraction is byte-correct (the fabric AC-3 decoder is already proven correct
//  by the liba52 cosim). Reads $VOB_IN (binary), writes AC-3 output to $AC3_OUT.
//    iverilog -g2012 -o sim dvd/ps_demux.sv bench/dvd/ps_demux_vob_extract_tb.sv
//    vvp sim +VOB_IN=/tmp/bbb_head.vob +AC3_OUT=/tmp/bbb_psdemux.ac3
//============================================================================
`timescale 1ns/1ps

module ps_demux_vob_extract_tb;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n;

    logic [7:0] in_byte;
    logic       in_valid;
    wire        in_ready;

    wire [7:0]  vid_byte;  wire vid_valid;
    wire [7:0]  aud_byte;  wire aud_valid;  wire [1:0] aud_type;
    wire        aud_frame_start;

    ps_demux dut (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(3'd0),
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(1'b1),
        .aud_byte(aud_byte), .aud_valid(aud_valid), .aud_type(aud_type),
        .aud_frame_start(aud_frame_start), .aud_ready(1'b1),
        .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid()
    );

    integer fin, fout, c;
    integer vid_bytes = 0, ac3_bytes = 0, other_aud = 0, frames = 0;
    reg [1023:0] vin, vout;

    // capture AC-3 audio output bytes (aud_type==0) to the output file
    always @(posedge clk) begin
        if (rst_n && aud_valid) begin
            if (aud_type == 2'd0) begin
                $fwrite(fout, "%c", aud_byte);
                ac3_bytes = ac3_bytes + 1;
                if (aud_frame_start) frames = frames + 1;
            end else other_aud = other_aud + 1;
        end
        if (rst_n && vid_valid) vid_bytes = vid_bytes + 1;
    end

    initial begin
        if (!$value$plusargs("VOB_IN=%s", vin))  vin  = "/tmp/bbb_head.vob";
        if (!$value$plusargs("AC3_OUT=%s", vout)) vout = "/tmp/bbb_psdemux.ac3";
        fin  = $fopen(vin,  "rb");
        fout = $fopen(vout, "wb");
        if (fin == 0)  begin $display("FAIL: cannot open %0s", vin);  $finish; end
        if (fout == 0) begin $display("FAIL: cannot open %0s", vout); $finish; end

        in_valid = 0; in_byte = 0; rst_n = 0;
        repeat (8) @(negedge clk);
        rst_n = 1;

        // stream the whole file, respecting in_ready backpressure
        c = $fgetc(fin);
        while (c != -1) begin
            @(negedge clk);
            in_byte  = c[7:0];
            in_valid = 1;
            @(posedge clk);          // present byte; consumed if in_ready
            while (!in_ready) @(posedge clk);
            c = $fgetc(fin);
        end
        @(negedge clk); in_valid = 0;

        // drain
        repeat (2000) @(posedge clk);

        $display("RESULT: vid_bytes=%0d  ac3_bytes=%0d  ac3_frames=%0d  other_aud=%0d",
                 vid_bytes, ac3_bytes, frames, other_aud);
        $fclose(fout);
        $fclose(fin);
        $finish;
    end

    initial begin #2000000000 $display("FAIL: timeout"); $finish; end
endmodule
