// aud_extract_tb.sv — dump ps_demux's audio-substream output for a real VOB so it
// can be diffed against the reference (ffmpeg) AC-3 elementary stream.
//
// Purpose: the in-fabric AC-3 decoder self-heal-resets ("static pops") on hardware
// after audio_ring overflow drops, yet the liba52 co-sim (fed the clean ffmpeg
// extract) decodes perfectly. This TB isolates whether ps_demux's *audio output*
// itself is byte-clean for the selected substream, by feeding a real VOB chunk
// through mpg_streamer-model -> ps_stream_fifo -> ps_demux and writing every
// forwarded audio byte to a raw file.
//
// Run:
//   iverilog -g2012 -o bench/dvd/aud_extract_sim \
//       dvd/ps_demux.sv dvd/ps_stream_fifo.sv bench/dvd/aud_extract_tb.sv
//   vvp bench/dvd/aud_extract_sim +VOB=/tmp/matrix_ac3/matrix_vob.hex \
//       +TRACK=2 +OUT=/tmp/matrix_ac3/psdemux_0x82.bin
//   cmp <(head -c <N> /tmp/matrix_ac3/psdemux_0x82.bin) \
//       <(head -c <N> /tmp/matrix_ac3/matrix_0x82_5p1.ac3)

`timescale 1ns/1ps
`default_nettype none

module aud_extract_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [7:0] src [$];
    int unsigned track = 0;
    string vob_path, out_path;
    int outfd;

    function automatic bit load_hex_file(input string path);
        int fd, code; logic [7:0] b;
        fd = $fopen(path, "r");
        if (fd == 0) return 0;
        forever begin
            code = $fscanf(fd, "%h", b);
            if (code != 1) break;
            src.push_back(b);
        end
        $fclose(fd);
        return 1;
    endfunction

    // ---- producer: model mpg_streamer's 1-byte read_valid pipe into ps_stream_fifo
    logic [7:0] p_pd; logic p_pv; wire p_full;
    wire [7:0]  inb; wire inv, inr;
    int p_idx; logic p_rvp; logic [7:0] p_pend;

    ps_stream_fifo u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_data(p_pd), .wr_en(p_pv), .almost_full(p_full),
        .out_byte(inb), .out_valid(inv), .out_ready(inr));

    wire [7:0] ab; wire av; wire [1:0] at; wire afs;
    ps_demux dut (
        .clk(clk), .rst_n(rst_n),
        .in_byte(inb), .in_valid(inv), .in_ready(inr), .aud_track(track[2:0]),
        .vid_byte(), .vid_valid(), .vid_ready(1'b1),
        .aud_byte(ab), .aud_valid(av), .aud_type(at),
        .aud_frame_start(afs), .aud_ready(1'b1),
        .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid());

    int aud_bytes, aud_frames, frame_len, prev_len, bad_first;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            p_pv <= 0; p_pd <= 0; p_idx <= 0; p_rvp <= 0; p_pend <= 0;
            aud_bytes <= 0; aud_frames <= 0; frame_len <= 0; bad_first <= 0;
        end else begin
            p_pv <= 0;
            if (p_rvp) begin p_pd <= p_pend; p_pv <= 1; p_rvp <= 0; end
            if (!p_full && !p_rvp && p_idx < src.size()) begin
                p_pend <= src[p_idx]; p_idx <= p_idx + 1; p_rvp <= 1;
            end
            if (av) begin
                $fwrite(outfd, "%c", ab);
                aud_bytes <= aud_bytes + 1;
                if (afs) begin
                    // report the just-completed frame's length (deferred)
                    if (aud_frames != 0) prev_len <= frame_len;
                    aud_frames <= aud_frames + 1;
                    frame_len  <= 1;
                end else begin
                    frame_len <= frame_len + 1;
                end
            end
        end
    end

    initial begin
        if (!$value$plusargs("TRACK=%d", track)) track = 0;
        if (!$value$plusargs("OUT=%s", out_path)) out_path = "/tmp/psdemux_aud.bin";
        outfd = $fopen(out_path, "wb");
        if (outfd == 0) begin $display("FAIL: cannot open OUT %s", out_path); $finish; end
        if ($value$plusargs("VOB=%s", vob_path)) begin
            if (!load_hex_file(vob_path)) begin $display("FAIL: cannot read VOB %s", vob_path); $finish; end
        end else begin $display("FAIL: need +VOB="); $finish; end
        $display("loaded %0d VOB bytes, track=%0d -> %s", src.size(), track, out_path);
        rst_n = 0; repeat(4) @(posedge clk); rst_n = 1;
        // run until producer drained + a tail with no new audio bytes
        begin int idle; idle = 0;
            forever begin
                @(posedge clk);
                if (p_idx >= src.size()) idle = idle + 1; else idle = 0;
                if (idle > 2000) break;
            end
        end
        $fclose(outfd);
        $display("DONE: audio frames=%0d bytes=%0d", aud_frames, aud_bytes);
        $finish;
    end
endmodule
`default_nettype wire
