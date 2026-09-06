//============================================================================
//  disp_sched.sv — the display scheduler: present each picture at its PTS
//  against a free-running STC. docs/stc_freerun.md.
//
//  THE MODEL (a set-top box): one 90 kHz clock that just runs, derived from the
//  same 27 MHz crystal as the raster and the 48 kHz audio NCO (tick = clk_sys/300,
//  crossed into clk_dec). Rate is therefore locked by construction; this module
//  owns PHASE: it anchors the clock once per discontinuity and decides, at every
//  pickup opportunity the display offers, whether the picture waiting at
//  picbuf's output is due. Buffer depth between the demux and the screen becomes
//  latency, not A/V offset -- which is the whole point.
//
//  ANCHORS.  stc := pts happens (a) provisionally, on the first parse-front PTS
//  after a flush (prov_*), frozen until video_live -- the STD mux-lead hold and
//  audio priming in emu/dvd_audio_decode work against that value exactly as
//  they always have; (b) at any pickup of a TAGGED picture while unanchored
//  or on a DISCONTINUITY; (c) at the first pickup of an UNTAGGED picture on a
//  stream that never showed a PTS (bare .m2v), at 0. Every anchor exports its
//  signed delta (anchor_delta) so the audio side can re-base a sample-continuous
//  stream across a PTS jump instead of misreading it as a phase error.
//
//  THE TIMELINE.  next_pts is the PTS the NEXT picture should carry: the last
//  displayed picture's PTS plus its content duration -- a field count from the
//  same rff/tff/progressive rules the image build uses (2/3/4/6 fields; MPEG-1
//  = 2) times the field period from frame_rate_code -- plus the durations of
//  every picture the vld DROPPED (skip_*: governor B-drops AND post-flush
//  realign drops). Ordering for the depth-1 display queue: an ack that lands
//  while a picture is waiting at the output belongs AFTER that picture, so it
//  is deferred until that pickup; otherwise it is added now. An anchoring
//  pickup clears the deferred amount (realign drops all precede the anchor).
//  A tagged picture RESYNCS the timeline; an untagged one takes next_pts.
//  Durations are kept in eighth-ticks (Q3) so 23.976 fps is exact (a field is
//  1876.875 ticks = 15015 Q3).
//
//  DUE.  A picture is due when stc >= pic_pts - half_scan, half_scan being half
//  the raster's IMAGE-SCAN period (750 ticks at 480p/480i-field, 900 PAL, 1877
//  film24, 1800 film25) -- the opportunity grid, not the content period: on
//  480i a frame's opportunity comes after two or three FIELD scans. Pickup
//  opportunities and due times both sit on the raster grid once anchored at a
//  pickup, so the half-period rounding is what makes the compare robust.
//
//  DISCONTINUITY.  A tagged picture more than one frame BEHIND the timeline or
//  more than FWD_MAX (0.5 s) ahead of it re-anchors (a cell/PGC boundary, a
//  menu loop, an authored gap too long to wait out); a picture more than
//  LATE_MAX behind the clock re-anchors too (a reader-held still or a cell PTS
//  reset would otherwise leave every later picture late forever). Small gaps
//  are waited out; small lateness is displayed now and recovered by the frame
//  drop governor, which makes the decoder run early so later pictures WAIT --
//  the loop that a refresh-counting ledger could only approximate.
//
//  RESET DOMAIN.  rst_n is the decoder reset; `flush` is the VBUF flush
//  (seek/mount). Deliberately NOT the keep_vbuf menu hop's pipe reset: across a
//  menu->menu hop the display keeps its timeline, old-timeline audio in the
//  ring becomes due and drains, and the new menu's first picture re-anchors as
//  a discontinuity -- which is what dissolves the menu exemptions.
//
//  No `function`, no N'(expr) cast: Quartus 17 miscompiles both silently.
//============================================================================

`default_nettype none

module disp_sched #(
    parameter signed [33:0] FWD_MAX_TICKS  = 34'sd45000,   // wait out gaps shorter than this (0.5 s)
    parameter signed [33:0] LATE_MAX_TICKS = 34'sd31500    // re-anchor past this much lateness (350 ms)
) (
    input  wire        clk,                   // clk_dec
    input  wire        rst_n,                 // sync_rst
    input  wire        flush,                 // VBUF flush level: timeline restarts
    input  wire        sched_en,              // 0 = free-run (every picture due at once)

    input  wire        tick,                  // 90 kHz, one clk pulse
    input  wire        video_live,            // the display has shown a decoded picture
    input  wire        pause,

    // provisional anchor: the parse-front PTS, first one after a flush
    input  wire [32:0] prov_pts,
    input  wire        prov_valid,

    // the picture waiting at picbuf's output
    input  wire        pic_valid,
    input  wire        pic_pts_valid,
    input  wire [32:0] pic_pts,
    input  wire        pic_pts_2nd,
    input  wire        pic_ps,                // progressive_sequence
    input  wire        pic_pf,                // progressive_frame
    input  wire        pic_tff,
    input  wire        pic_rff,
    input  wire  [3:0] frame_rate_code,
    input  wire        pickup,                // one clk: the display took pic_*

    // dropped pictures (either reason)
    input  wire        skip_ack,
    input  wire        skip_field,
    input  wire        skip_ps,
    input  wire        skip_pf,
    input  wire        skip_tff,
    input  wire        skip_rff,

    input  wire [15:0] half_scan,             // ticks, per raster mode

    output wire        pic_due,               // the waiting picture may be picked up now
    output wire        next_due,              // the timeline has reached the next picture (starvation = late)
    output reg  [32:0] stc,
    output reg         anchored,
    output reg         anchor_req,            // one clk: stc was (re)anchored
    output reg  signed [33:0] anchor_delta,   // new - old
    output reg         disp_lag_valid,        // one clk at a pickup
    output reg  signed [33:0] disp_lag        // pic_pts - stc at that pickup
);

    // ---- PIPELINE NOTE (2026-09-06, the first Stage 1 fit) -------------------
    // Fully combinational, this module's cone from frame_rate_code (a vld
    // register) through the field-period mux, the field-count multiply and the
    // four-operand add into next_q3 measured 13.3 ns against clk_dec's 12.3 ns
    // (tools/timing_paths.sh: clk_dec fell 87.7 -> 73.8 MHz), and the same cone
    // fed pic_due into the display FSM. Nothing here needs to be decided in one
    // cycle -- a picture waits at the output for thousands of cycles, the STC
    // moves once per ~1000, and the pickup pulse arrives a cycle after the FSM's
    // decision -- so every stage below is REGISTERED: period, products, the
    // differences, then the compares. The outputs lag their inputs by 3-4 clocks
    // (~40 ns against an 11 us tick), which the bench cannot even see.

    // ---- stage A: field period in Q3 (eighth) ticks, from frame_rate_code ----
    //   1 23.976 -> 15015   2 24 -> 15000   3 25 -> 14400   4 29.97 -> 12012
    //   5 30     -> 12000   6 50 -> 7200    7 59.94 -> 6006 8 60 -> 6000
    reg [14:0] field_q3;
    always_ff @(posedge clk)
        field_q3 <= (frame_rate_code == 4'd1) ? 15'd15015 :
                    (frame_rate_code == 4'd2) ? 15'd15000 :
                    (frame_rate_code == 4'd3) ? 15'd14400 :
                    (frame_rate_code == 4'd5) ? 15'd12000 :
                    (frame_rate_code == 4'd6) ? 15'd7200  :
                    (frame_rate_code == 4'd7) ? 15'd6006  :
                    (frame_rate_code == 4'd8) ? 15'd6000  : 15'd12012;
    wire [15:0] frame_ticks = {3'b0, field_q3[14:2]};       // field_q3/4 = 2 fields in ticks (floor)
    wire [32:0] field_ticks = {21'd0, field_q3[14:3]};

    // content field count, the image-build rules
    wire [2:0] pic_fields  = pic_ps  ? (pic_rff  ? (pic_tff  ? 3'd6 : 3'd4) : 3'd2)
                                     : ((pic_pf  && pic_rff)  ? 3'd3 : 3'd2);
    wire [2:0] skip_fields = skip_field ? 3'd1 :
                             skip_ps    ? (skip_rff ? (skip_tff ? 3'd6 : 3'd4) : 3'd2)
                                        : ((skip_pf && skip_rff) ? 3'd3 : 3'd2);

    // ---- stage B: products and the effective picture PTS (registered) --------
    reg  [17:0] pic_dur_q3;
    reg  [17:0] skip_dur_q3;
    reg         skip_ack_r;                  // the ack, delayed to meet its product
    reg  [32:0] pic_pts_eff;
    always_ff @(posedge clk) begin
        pic_dur_q3  <= field_q3 * pic_fields;
        skip_dur_q3 <= field_q3 * skip_fields;
        skip_ack_r  <= skip_ack;
        // a second-field tag names the second field: one field period after the frame
        pic_pts_eff <= pic_pts - (pic_pts_2nd ? field_ticks : 33'd0);
    end

    // ---- the timeline -----------------------------------------------------
    reg  [35:0] next_q3;                     // PTS of the next picture, Q3
    reg         next_valid;                  // a picture has been displayed since the anchor
    reg  [35:0] defer_q3;                    // skipped durations belonging after the waiting picture
    reg         prov_seen;                   // a parse-front PTS has been seen since the flush
    wire [32:0] next_pts = next_q3[35:3];

    // ---- stage C: the differences (registered) -----------------------------
    wire has_tag = pic_valid && pic_pts_valid;
    reg  signed [33:0] d_pic_next, d_stc_pic, d_stc_next, d_stc_want;
    reg  [32:0] want_pts;
    reg  [35:0] want_dur_q3;                 // {want_pts, 3'b0} + pic_dur_q3, precomputed
    wire [32:0] want_pts_w = has_tag ? pic_pts_eff : (next_valid ? next_pts : stc);
    always_ff @(posedge clk) begin
        d_pic_next  <= $signed({1'b0, pic_pts_eff}) - $signed({1'b0, next_pts});
        d_stc_pic   <= $signed({1'b0, stc}) - $signed({1'b0, pic_pts_eff});
        d_stc_next  <= $signed({1'b0, stc}) - $signed({1'b0, next_pts});
        d_stc_want  <= $signed({1'b0, stc}) - $signed({1'b0, want_pts_w});
        want_pts    <= want_pts_w;
        want_dur_q3 <= {want_pts, 3'd0} + {18'd0, pic_dur_q3};
    end
    wire signed [33:0] half_s     = $signed({18'd0, half_scan});
    wire signed [33:0] fwd_max_s  = FWD_MAX_TICKS;          // pre-sized parameters (no runtime casts)
    wire signed [33:0] late_max_s = LATE_MAX_TICKS;
    wire signed [33:0] frame_s    = $signed({18'd0, frame_ticks});

    // ---- stage D: the decisions (registered) --------------------------------
    // a tagged picture that does not belong to the current timeline
    reg  disc, anchor_now, pic_due_r, next_due_r;
    wire disc_w = has_tag && anchored && next_valid &&
                  ((d_pic_next < -frame_s) || (d_pic_next > fwd_max_s) || (d_stc_pic > late_max_s));
    wire anchor_now_w = pic_valid && (!anchored || (has_tag && (!next_valid || disc_w)));
    always_ff @(posedge clk) begin
        disc       <= disc_w;
        anchor_now <= anchor_now_w;
        pic_due_r  <= !sched_en || !pic_valid || anchor_now_w || (d_stc_want >= -half_s);
        next_due_r <= !sched_en || (anchored && next_valid && (d_stc_next >= -half_s));
    end
    wire [32:0] anchor_val = has_tag ? pic_pts_eff : (prov_seen ? stc : 33'd0);
    assign pic_due  = pic_due_r;
    assign next_due = next_due_r;

    always_ff @(posedge clk) begin
        anchor_req     <= 1'b0;
        disp_lag_valid <= 1'b0;
        if (!rst_n || flush) begin
            stc          <= 33'd0;
            anchored     <= 1'b0;
            next_q3      <= 36'd0;
            next_valid   <= 1'b0;
            defer_q3     <= 36'd0;
            prov_seen    <= 1'b0;
            anchor_delta <= 34'sd0;
            disp_lag     <= 34'sd0;
        end else begin
            // the clock
            if (tick && anchored && video_live && !pause) stc <= stc + 33'd1;

            // provisional anchor: the first parse-front PTS after a flush
            if (prov_valid && !anchored) begin
                stc       <= prov_pts;
                anchored  <= 1'b1;
                prov_seen <= 1'b1;
            end else if (prov_valid) prov_seen <= 1'b1;

            // dropped pictures (the delayed ack meets its registered product)
            if (skip_ack_r) begin
                if (pic_valid) defer_q3 <= defer_q3 + {18'd0, skip_dur_q3};
                else           next_q3  <= next_q3  + {18'd0, skip_dur_q3};
            end

            // a pickup
            if (pickup) begin
                disp_lag_valid <= 1'b1;
                disp_lag       <= $signed({1'b0, want_pts}) - $signed({1'b0, stc});
                if (anchor_now) begin
                    anchor_req   <= 1'b1;
                    anchor_delta <= $signed({1'b0, anchor_val}) - $signed({1'b0, stc});
                    stc          <= anchor_val;
                    anchored     <= 1'b1;
                    next_q3      <= {anchor_val, 3'd0} + {18'd0, pic_dur_q3};   // realign drops precede the anchor
                    defer_q3     <= 36'd0;
                end else begin
                    next_q3      <= want_dur_q3 + defer_q3
                                  + (skip_ack_r && pic_valid ? {18'd0, skip_dur_q3} : 36'd0);
                    defer_q3     <= 36'd0;
                end
                next_valid <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
