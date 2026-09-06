//============================================================================
//  av_sync.sv — the clk_sys view of the presentation clock, plus A/V telemetry.
//
//  THE STC IS A CLOCK (docs/stc_freerun.md). The System Time Clock is a free-
//  running 90 kHz counter that lives with the display scheduler in the decoder
//  clock (dvd/disp_sched.sv, inside mpeg2video): it ticks off the same 27 MHz
//  crystal as the raster and the audio NCO, so its RATE is the crystal's and
//  only its PHASE is ever set -- once per discontinuity, at a pickup of a
//  picture that carries a PTS. Audio, subtitles, the STD mux-lead hold and the
//  highlight scheduler all read the one clock; nothing here re-anchors it,
//  slews anything, or counts refreshes.
//
//  This module is the MIRROR of that clock in clk_sys: the scheduler sends
//  {anchored, stc} across on every tick (pts_cdc, ~11 us apart -- far longer
//  than the synchroniser, so no value is ever lost), and each re-anchor's
//  signed delta arrives on its own crossing so the audio side can re-base a
//  sample-continuous stream across a PTS jump. The mirrored stc is at most one
//  tick (11 us) stale. Its reset is the core reset only: a keep_vbuf menu hop
//  must not blank the clock the ring is draining against.
//
//  What was here before -- a refresh-counted STC anchored on the parse-front
//  PTS, the retired NCO PI loop, the asymmetric seek detector, the stc_disp
//  proxy clock -- is documented in docs/av_sync.md as history.
//============================================================================

`default_nettype none

module av_sync (
    input  wire        clk,               // clk_sys
    input  wire        rst_n,             // core reset (NOT the pipe reset)

    // the clock, mirrored from disp_sched: {anchored, stc} on every tick
    input  wire [33:0] mirror_data,
    input  wire        mirror_valid,
    // a (re)anchor: its signed delta (new - old), once per event
    input  wire signed [33:0] delta_data,
    input  wire        delta_valid,

    // telemetry references
    input  wire [32:0] vid_pts,           // parse-front video PTS (buf_lag)
    input  wire        vid_pts_valid,
    input  wire [32:0] dispatch_pts,      // audio frame handed to the decoder (drift)
    input  wire        dispatch_pts_valid,

    output logic [32:0] stc,
    output logic        stc_anchored,
    output logic        anchor_pulse,     // one clk: stc just jumped by anchor_delta
    output logic signed [33:0] anchor_delta,
    output wire  signed [31:0] drift,     // dispatched audio PTS - stc
    output wire  signed [31:0] buf_lag,   // parse-front video PTS - stc
    output logic [15:0] reanchor_count
);

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            stc            <= '0;
            stc_anchored   <= 1'b0;
            anchor_pulse   <= 1'b0;
            anchor_delta   <= '0;
            reanchor_count <= '0;
        end else begin
            anchor_pulse <= 1'b0;
            if (mirror_valid) begin
                stc          <= mirror_data[32:0];
                stc_anchored <= mirror_data[33];
            end
            if (delta_valid) begin
                anchor_pulse   <= 1'b1;
                anchor_delta   <= delta_data;
                reanchor_count <= reanchor_count + 1'b1;
            end
        end

    logic [32:0] disp_pts_l, vid_pts_l;
    always_ff @(posedge clk) begin
        if (dispatch_pts_valid) disp_pts_l <= dispatch_pts;
        if (vid_pts_valid)      vid_pts_l  <= vid_pts;
    end
    wire signed [33:0] drift_w  = $signed({1'b0, disp_pts_l}) - $signed({1'b0, stc});
    wire signed [33:0] buflag_w = $signed({1'b0, vid_pts_l})  - $signed({1'b0, stc});
    assign drift   = drift_w[31:0];
    assign buf_lag = buflag_w[31:0];

endmodule

`default_nettype wire
