//============================================================================
//  aud_pts_chain_tb.sv — WHERE DOES THE AUDIO PTS DIE? (lip-sync HW diagnosis)
//
//  HW overlay (DVD_avlead6) showed the drain gate releasing only via the
//  fallback timer: play_pts never latches because dispatch_pts_valid never
//  pulses — i.e. no audio frame reaches dvd_audio_decode with a valid PTS on a
//  REAL VOB, even though every stage passes its own synthetic-PES testbench.
//
//  This bench feeds the real Matrix VOB extract (bench/dvd/test_vobs/sample.hex)
//  through ps_demux -> ac3_reframer and counts, per stage:
//    A. ps_demux video PTS pulses (vid_pts_valid)
//    B. ps_demux audio frame starts (aud_frame_start) and how many of those
//       coincide with aud_frame_pts_valid=1
//    C. reframer output frame starts and how many carry out_frame_pts_valid
//
//  iverilog -g2012 -o bench/dvd/aud_pts_chain_sim \
//      dvd/ps_demux.sv dvd/ac3_reframer.sv bench/dvd/aud_pts_chain_tb.sv
//  vvp bench/dvd/aud_pts_chain_sim
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module aud_pts_chain_tb;

logic clk = 0, rst_n;
always #18 clk = ~clk;

// ---- source: real VOB (binary via +VOB=<path>, capped by +MB=<n>, default 4) --
logic [7:0] src [$];
string      vob_path;
integer     load_fd, load_i, load_n, cap_mb;
logic [7:0] load_buf [0:4095];
initial begin
    if (!$value$plusargs("VOB=%s", vob_path)) vob_path = "tools/streams/MATRIX.VOB";
    if (!$value$plusargs("MB=%d", cap_mb)) cap_mb = 4;
    load_fd = $fopen(vob_path, "rb");
    if (load_fd == 0) begin $display("FATAL: cannot open %0s", vob_path); $finish; end
    while (src.size() < cap_mb*1048576) begin
        load_n = $fread(load_buf, load_fd);
        if (load_n <= 0) break;
        for (load_i = 0; load_i < load_n; load_i = load_i + 1) src.push_back(load_buf[load_i]);
    end
    $fclose(load_fd);
    $display("loaded %0d bytes from %0s", src.size(), vob_path);
end

// ---- DUT chain -------------------------------------------------------------
logic [7:0] in_byte;
logic       in_valid;
wire        in_ready;

wire [7:0]  vid_byte;   wire vid_valid;
wire [7:0]  aud_byte;   wire aud_valid;
wire [1:0]  aud_type;   wire aud_frame_start;
wire [32:0] vid_pts;    wire vid_pts_valid;
wire [32:0] aud_pts;    wire aud_pts_valid;
wire [32:0] aud_frame_pts;
wire        aud_frame_pts_valid;

ps_demux ps_demux_inst (
    .clk(clk), .rst_n(rst_n),
    .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
    .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(1'b1),
    .aud_byte(aud_byte), .aud_valid(aud_valid), .aud_ready(1'b1),
    .aud_type(aud_type), .aud_frame_start(aud_frame_start),
    .aud_track(3'd0),
    .vid_pts(vid_pts), .vid_pts_valid(vid_pts_valid),
    .aud_pts(aud_pts), .aud_pts_valid(aud_pts_valid),
    .aud_frame_pts(aud_frame_pts), .aud_frame_pts_valid(aud_frame_pts_valid)
);

wire [7:0]  rf_byte;  wire rf_valid;
wire [1:0]  rf_type;  wire rf_start;
wire [32:0] rf_pts;   wire rf_pts_valid;

ac3_reframer reframer (
    .clk(clk), .rst_n(rst_n),
    .in_byte(aud_byte), .in_valid(aud_valid),   // aud_ready tied 1 => every valid is a transfer
    .in_type(aud_type), .in_frame_start(aud_frame_start),
    .in_frame_pts(aud_frame_pts), .in_frame_pts_valid(aud_frame_pts_valid),
    .out_byte(rf_byte), .out_valid(rf_valid), .out_type(rf_type),
    .out_frame_start(rf_start),
    .out_frame_pts(rf_pts), .out_frame_pts_valid(rf_pts_valid)
);

// ---- SEQUENCE-HEADER ANCHOR PROTOTYPE ----------------------------------------
// Watch the demuxed VIDEO payload for 00 00 01 B3 (sequence header). The PES
// carrying it also carried the first-displayable picture's PTS (held in
// ps_demux.vid_pts by then) — report what the STC would anchor to, vs the naive
// first-parsed vid_pts, vs the first audio pts.
logic [23:0] vshift = 0;
integer n_seq = 0;
logic [32:0] first_anchor = 0, first_vid = 0, first_aud = 0;
logic        have_anchor = 0, have_vid = 0, have_aud = 0;
always @(posedge clk) if (rst_n && vid_valid) begin
    if (vshift == 24'h000001 && vid_byte == 8'hB3) begin
        n_seq = n_seq + 1;
        if (!have_anchor) begin
            first_anchor = vid_pts; have_anchor = 1;
            $display("  ANCHOR: first seq-header; pending vid_pts = %0d ticks (%0d ms)",
                     vid_pts, vid_pts/90);
        end
    end
    vshift <= {vshift[15:0], vid_byte};
end

// ---- counters ---------------------------------------------------------------
integer n_vid_pts = 0;
integer n_aud_bytes = 0;
integer n_ps_starts = 0, n_ps_starts_pts = 0;
integer n_rf_starts = 0, n_rf_starts_pts = 0;
integer shown = 0;

always @(posedge clk) if (rst_n) begin
    if (vid_pts_valid) begin
        n_vid_pts = n_vid_pts + 1;
        if (!have_vid) begin first_vid = vid_pts; have_vid = 1; end
        if (n_vid_pts <= 3) $display("  vid_pts[%0d] = %0d ticks (%0d ms)", n_vid_pts, vid_pts, vid_pts/90);
    end
    if (aud_pts_valid && !have_aud) begin first_aud = aud_pts; have_aud = 1; end
    if (aud_valid) begin
        n_aud_bytes = n_aud_bytes + 1;
        if (aud_frame_start) begin
            n_ps_starts = n_ps_starts + 1;
            if (aud_frame_pts_valid) n_ps_starts_pts = n_ps_starts_pts + 1;
            if (n_ps_starts <= 3)
                $display("  ps aud start[%0d]: pts_valid=%b pts=%0d ticks (%0d ms)",
                         n_ps_starts, aud_frame_pts_valid, aud_frame_pts, aud_frame_pts/90);
        end
    end
    if (rf_valid && rf_start) begin
        n_rf_starts = n_rf_starts + 1;
        if (rf_pts_valid) n_rf_starts_pts = n_rf_starts_pts + 1;
        if (shown < 3) begin
            $display("  reframer start[%0d]: pts_valid=%b pts=%0d ticks (%0d ms)",
                     n_rf_starts, rf_pts_valid, rf_pts, rf_pts/90);
            shown = shown + 1;
        end
    end
end

// ---- drive -------------------------------------------------------------------
integer idx = 0;
initial begin
    rst_n = 0; in_valid = 0; in_byte = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
    while (idx < src.size()) begin
        in_byte  <= src[idx];
        in_valid <= 1'b1;
        @(posedge clk);
        if (in_ready) idx = idx + 1;
    end
    in_valid <= 1'b0;
    repeat (100) @(posedge clk);

    $display("---------------------------------------------------------");
    $display("sequence headers seen   : %0d", n_seq);
    if (have_vid && have_aud)
        $display("first vid_pts - first aud_pts = %0d ms", ($signed({1'b0,first_vid}) - $signed({1'b0,first_aud}))/90);
    if (have_anchor && have_aud)
        $display("seq-anchor    - first aud_pts = %0d ms", ($signed({1'b0,first_anchor}) - $signed({1'b0,first_aud}))/90);
    if (have_anchor && have_vid)
        $display("seq-anchor    - first vid_pts = %0d ms  <- the old anchor error", ($signed({1'b0,first_anchor}) - $signed({1'b0,first_vid}))/90);
    $display("video PTS pulses        : %0d", n_vid_pts);
    $display("audio bytes forwarded   : %0d", n_aud_bytes);
    $display("ps_demux frame starts   : %0d  (with PTS: %0d)", n_ps_starts, n_ps_starts_pts);
    $display("reframer frame starts   : %0d  (with PTS: %0d)", n_rf_starts, n_rf_starts_pts);
    if (n_rf_starts_pts > 0 && n_vid_pts > 0)
        $display("VERDICT: PTS chain ALIVE end-to-end on the real VOB");
    else if (n_ps_starts_pts > 0)
        $display("VERDICT: PTS dies in the REFRAMER");
    else if (n_vid_pts > 0)
        $display("VERDICT: audio PTS dies in PS_DEMUX (video PTS ok)");
    else
        $display("VERDICT: NO PTS parsed at all (ps_demux PES header parse)");
    $finish;
end

initial begin #400000000; $display("TIMEOUT"); $finish; end

endmodule
`default_nettype wire
