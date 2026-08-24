`timescale 1ns/1ps
//============================================================================
//  ps_demux_yield_tb.sv — AUDIO YIELD audit of ps_demux against an ffmpeg
//  reference, over a multi-MB extract of a REAL DVD VOB.
//
//  Motivation (2026-07-02): NTSC film audio starves on HW (audio_ring parks at
//  0) even though the mux carries full-rate audio and the governor's video rate
//  is sim-exact (2.500 refreshes/frame). One remaining hypothesis: ps_demux
//  silently LOSES a fraction of the selected audio track (masked before the
//  film-3:2 fix by the 25% over-speed delivery). This tb measures the demux's
//  audio yield byte count directly against ffmpeg's for the same input span.
//
//  Reference (scratchpad vob8m.bin, first 8 MiB of VTS_02_6.VOB):
//     ffmpeg -map 0:3 (id 0x80, 6ch 384k) -c copy  => 633,024 bytes (~13.19 s)
//     video (0x1e0)                                => 6,743,538 bytes (307 frames)
//  Expect the demuxed audio byte count within ~2 AC-3 frames (edge partials) of
//  the reference; video likewise close (demux strips PES headers only).
//
//  Build:
//    iverilog -g2012 -o bench/dvd/ps_demux_yield_sim \
//        dvd/ps_demux.sv bench/dvd/ps_demux_yield_tb.sv
//    vvp bench/dvd/ps_demux_yield_sim +hex=<path>/vob8m.hex
//============================================================================

module ps_demux_yield_tb;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n;

    logic [7:0] src [$];

    function automatic bit load_hex_file(input string path);
        int fd, code, b;
        fd = $fopen(path, "r");
        if (fd == 0) return 0;
        src.delete();
        forever begin
            code = $fscanf(fd, "%h", b);
            if (code != 1) break;
            src.push_back(b[7:0]);
        end
        $fclose(fd);
        return (src.size() > 0);
    endfunction

    logic [7:0] in_byte;
    logic       in_valid;
    wire        in_ready;
    wire [7:0]  vid_byte;  wire vid_valid;
    wire [7:0]  aud_byte;  wire aud_valid; wire [1:0] aud_type; wire aud_frame_start;
    wire [32:0] vid_pts, aud_pts, aud_frame_pts;
    wire        vid_pts_valid, aud_pts_valid, aud_frame_pts_valid;

    ps_demux dut (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(3'd0),                        // substream 0x80 (the 384k 5.1)
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(1'b1),
        .aud_byte(aud_byte), .aud_valid(aud_valid), .aud_type(aud_type),
        .aud_frame_start(aud_frame_start), .aud_ready(1'b1),
        .vid_pts(vid_pts), .vid_pts_valid(vid_pts_valid),
        .aud_pts(aud_pts), .aud_pts_valid(aud_pts_valid),
        .aud_frame_pts(aud_frame_pts), .aud_frame_pts_valid(aud_frame_pts_valid)
    );

    // yield counters (ready is tied high, so every valid cycle is one byte)
    longint aud_bytes = 0, vid_bytes = 0, aud_frames = 0;
    always_ff @(posedge clk) if (rst_n) begin
        if (aud_valid) aud_bytes  = aud_bytes + 1;
        if (vid_valid) vid_bytes  = vid_bytes + 1;
        if (aud_valid && aud_frame_start) aud_frames = aud_frames + 1;
    end

    // reference numbers for the default chunk
    localparam longint REF_AUD = 633024;
    localparam longint REF_VID = 6743538;
    localparam longint TOL_AUD = 2*1536;      // 2 AC-3 frames of edge slack

    integer i, errs = 0;
    string  hexpath;
    real    aud_pct, vid_pct;

    initial begin
        if (!$value$plusargs("hex=%s", hexpath))
            hexpath = "bench/dvd/test_vobs/vob8m.hex";
        if (!load_hex_file(hexpath)) begin
            $display("FAIL: cannot load %s", hexpath); $finish;
        end
        $display("loaded %0d bytes", src.size());

        in_valid = 0; in_byte = 0; rst_n = 0;
        repeat (5) @(posedge clk); rst_n = 1;

        // held valid+ready handshake (like ps_stream_fifo feeding ps_demux)
        i = 0;
        while (i < src.size()) begin
            @(negedge clk);
            in_byte  = src[i];
            in_valid = 1'b1;
            @(posedge clk);
            if (in_ready) i = i + 1;
        end
        @(negedge clk); in_valid = 0;
        repeat (100) @(posedge clk);

        aud_pct = 100.0 * $itor(aud_bytes) / $itor(REF_AUD);
        vid_pct = 100.0 * $itor(vid_bytes) / $itor(REF_VID);
        $display("aud_bytes=%0d (ref %0d -> %.2f%%)  frames=%0d", aud_bytes, REF_AUD, aud_pct, aud_frames);
        $display("vid_bytes=%0d (ref %0d -> %.2f%%)", vid_bytes, REF_VID, vid_pct);

        if (aud_bytes < REF_AUD - TOL_AUD || aud_bytes > REF_AUD + TOL_AUD) begin
            $display("FAIL: audio yield off by %0d bytes (%.2f%%) — demux is LOSING audio",
                     REF_AUD - aud_bytes, 100.0 - aud_pct);
            errs = errs + 1;
        end
        if (vid_bytes < REF_VID - 65536) begin
            $display("WARN/FAIL: video yield low by %0d bytes", REF_VID - vid_bytes);
            errs = errs + 1;
        end
        if (errs == 0) $display("==== PASS: demux audio yield byte-accurate vs ffmpeg ====");
        else           $display("==== FAIL: %0d error(s) ====", errs);
        $finish;
    end

    initial begin #400_000_000 $display("TIMEOUT (aud=%0d vid=%0d)", aud_bytes, vid_bytes); $finish; end
endmodule
