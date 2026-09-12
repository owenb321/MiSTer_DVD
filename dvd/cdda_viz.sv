//============================================================================
//  dvd/cdda_viz.sv -- the audio-reactive visualizer for WAV / CD-DA playback.
//
//  An audio CD has no picture, so the screen is either this or the bouncing
//  idle logo. Angle cycles the two (it does nothing else on a CD -- the angle
//  switch needs cell_ready; dvd/cdda_screen.sv owns the mode register):
//
//    mode 0  off         -- emu shows the bouncing idle logo. THIS IS THE
//                           DEFAULT (user decision 2026-09-12): a CD boots to
//                           the logo and Angle is what opts INTO the visualizer,
//                           rather than the visualizer being something to
//                           dismiss. An OSD Reset returns here.
//    mode 1  COPPER BARS -- three TRIANGLE-driven gradient bars over a dark
//                           ramp, the Amiga "copper list" look
//
//  It reacts to the music through a peak envelope of (|L|+|R|) with a per-frame
//  decay, a slow average of it, and a "kick" timer armed when the envelope
//  jumps well above that average.
//
//  ⛔ TWO VISUALIZERS WERE BUILT AND THEN DROPPED, both on logic-budget grounds
//  (user decisions). Measured by synthesising this module alone with `mode` tied
//  to each constant, so Quartus prunes the other arms:
//    * SCOPE  (2026-09-11) -- two traces, L above R, triggered on L's rising
//      zero crossing, storing precomputed screen ROWS: ~105 ALMs AND a whole
//      M10K. With RAM at 90 % the memory block was the expensive half.
//    * XOR    (2026-09-12) -- scrolling (x ^ y) "munching squares": ~60 ALMs,
//      but it was the ONLY per-PIXEL consumer, so dropping it also retired the
//      a_xv/a_yv/b_m coordinate pipeline and the sx/sy/tc scroll registers.
//  Do not re-add either without that budget in hand.
//
//  ★ THE BUDGET IS THE DESIGN:
//   - NO FRAMEBUFFER. Every pixel is a function of (x, y) and a few per-frame
//     registers, so nothing here scales with screen area.
//   - COPPER IS PER LINE, NOT PER PIXEL. When v_pos changes the three bars are
//     tested SERIALLY (one comparator, four clocks, all inside horizontal
//     blanking) and the colour is held for the whole line. Per-pixel cost: 0.
//   - Bar POSITIONS are serial too, once per FRAME.
//   - ★ The oscillator is a TRIANGLE, not a sine (2026-09-12, user decision):
//     the bars bounce LINEARLY instead of easing at the ends. The quarter-wave
//     mirror was already there, so the 64-entry sine LUT collapsed to a single
//     shift -- `sq = {sq_i, 1'b0}` -- which is a wire, not logic. That is the
//     largest single saving in this file.
//   - Three registered display stages, the same as idle_logo, so both share
//     emu's overlay slot with the same horizontal lead (VIZ_QX_LEAD).
//
//  ⚠ No `function`s and no N'(expr) casts anywhere in this file -- both have
//  been silently miscompiled by Quartus 17 in this project (see CLAUDE.md).
//============================================================================

`timescale 1ns/1ps
`default_nettype none

module cdda_viz #(
    parameter [11:0] VIZ_QX_LEAD = 12'd12,   // subtracted, = idle_logo's lead
    parameter        SDIV_W      = 12        // sample tick = clk / 2^SDIV_W
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [11:0] h_pos,                 // ov_h_gen
    input  wire [11:0] v_pos,                 // core_v_pos (absolute frame line)
    input  wire        pal_mode,
    input  wire        frame_tick,            // av_refresh_tick
    input  wire        vis,                   // emu's viz_vis gate
    input  wire  [1:0] mode,                  // 0 logo (off, default), 1 copper

    input  wire [15:0] audio_l,               // signed PCM, held between samples
    input  wire [15:0] audio_r,

    output reg         viz_on,
    output reg   [7:0] viz_r,
    output reg   [7:0] viz_g,
    output reg   [7:0] viz_b
);

    localparam [1:0] M_COPPER = 2'd1;   // 0 is the logo, which is the default

    wire [11:0] act_h = pal_mode ? 12'd576 : 12'd480;

    // =====================================================================
    // Audio analysis
    // =====================================================================
    reg [SDIV_W-1:0] sdiv;
    wire s_tick = (sdiv == {SDIV_W{1'b0}});

    // one's-complement magnitude is plenty for a picture
    wire [14:0] mag_l = audio_l[15] ? ~audio_l[14:0] : audio_l[14:0];
    wire [14:0] mag_r = audio_r[15] ? ~audio_r[14:0] : audio_r[14:0];
    wire [15:0] mag_s = {1'b0, mag_l} + {1'b0, mag_r};
    wire  [7:0] mag   = mag_s[15:8];

    reg   [7:0] env, avg;
    reg   [3:0] kick;
    reg  [15:0] t;                            // phase accumulator
    wire  [9:0] kick_lvl = {2'b00, avg} + {4'b0000, avg[7:2]} + 10'd12;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sdiv <= {SDIV_W{1'b0}};
            env <= 8'd0; avg <= 8'd0; kick <= 4'd0; t <= 16'd0;
        end else begin
            sdiv <= sdiv + 1'b1;
            if (s_tick && (mag > env))
                env <= mag;                                        // instant attack
            else if (frame_tick)
                env <= env - {3'b000, env[7:3]} - {7'd0, (env != 8'd0)};
            if (frame_tick) begin
                avg <= avg - {4'b0000, avg[7:4]} + {4'b0000, env[7:4]};
                if (({2'b00, env} > kick_lvl) && (kick < 4'd8))
                    kick <= 4'd15;
                else if (kick != 4'd0)
                    kick <= kick - 4'd1;
                // silence: ~17 s per cycle; loud: ~1.3 s
                t <= t + 16'd16 + {8'd0, env};
            end
        end
    end

    wire [7:0] p8 = t[13:6];

    // =====================================================================
    // Bar positions, solved serially once per frame
    // =====================================================================
    reg  [1:0] pk;                             // bar being solved; 3 = idle
    reg  [9:0] y0, y1, y2;
    // pk * 48 -> phases 0 / 48 / 96, the same total spread the five-bar
    // version had at pk * 24, so the group still reads as one wave
    wire [7:0] bar_off = {1'b0, pk, 5'b00000} + {2'b00, pk, 4'b0000};
    wire [7:0] sn_ph   = p8 + bar_off;

    // TRIANGLE: mirror on phase bit 6, sign on bit 7. The mirror already
    // existed for the quarter-wave sine, so the magnitude is now just a
    // doubled ramp (0..126) instead of a 64-entry table.
    wire [5:0] sq_i = sn_ph[6] ? ~sn_ph[5:0] : sn_ph[5:0];
    wire [6:0] sq   = {sq_i, 1'b0};
    wire [8:0] sn   = sn_ph[7] ? (9'd0 - {2'b00, sq}) : {2'b00, sq};   // +/-126
    wire [8:0] sn_h = {sn[8], sn[8:1]};                               // >>> 1
    wire [8:0] sn_q = {sn[8], sn[8], sn[8:2]};                        // >>> 2
    // louder = wider swing: x0.5 / x0.75 / x1 / x1.25, shift-adds only
    wire [8:0] sn_a = (env[7:6] == 2'd0) ? sn_h :
                      (env[7:6] == 2'd1) ? (sn - sn_q) :
                      (env[7:6] == 2'd2) ? sn : (sn + sn_q);
    wire [9:0] y_ctr = pal_mode ? 10'd288 : 10'd240;
    wire [9:0] y_new = y_ctr + {sn_a[8], sn_a};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pk <= 2'd3;
            y0 <= 10'd160; y1 <= 10'd240; y2 <= 10'd320;
        end else if (frame_tick) begin
            pk <= 2'd0;
        end else if (pk < 2'd3) begin
            case (pk)
                2'd0:    y0 <= y_new;
                2'd1:    y1 <= y_new;
                default: y2 <= y_new;
            endcase
            pk <= pk + 2'd1;
        end
    end

    // =====================================================================
    // Line colour, solved serially once per LINE
    // =====================================================================
    reg [11:0] v_q;
    reg  [2:0] lk;                             // bar under test; 3 resolve, 4 done
    reg  [3:0] mr, mg, mb;                     // running max intensity per channel
    reg  [7:0] ln_r, ln_g, ln_b;               // this line's colour
    reg  [9:0] ly;
    reg  [2:0] lmask;                          // {r,g,b} the bar lights
    always @(*) begin
        case (lk)
            3'd0:    begin ly = y0; lmask = 3'b100; end   // red
            3'd1:    begin ly = y1; lmask = 3'b110; end   // yellow
            default: begin ly = y2; lmask = 3'b011; end   // cyan
        endcase
    end
    wire [11:0] ld    = v_q - {2'b00, ly};
    wire [11:0] lad   = ld[11] ? (12'd0 - ld) : ld;
    wire        lhit  = (lad < 12'd16);                   // 31-line bar
    wire  [3:0] lint  = 4'd15 - lad[3:0];
    wire        lcore = (lad < 12'd2);                    // white-hot centre
    // dark blue->purple ramp down the screen, lifted on every kick
    wire  [7:0] kbump = {2'b00, kick, 2'b00};
    wire  [7:0] bg_r  = {3'b000, v_q[8:4]} + kbump;
    wire  [7:0] bg_g  = kbump;
    wire  [7:0] bg_b  = {2'b00, v_q[8:3]} + kbump;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_q <= 12'd0; lk <= 3'd4;
            mr <= 4'd0; mg <= 4'd0; mb <= 4'd0;
            ln_r <= 8'd0; ln_g <= 8'd0; ln_b <= 8'd0;
        end else if (v_pos != v_q) begin
            v_q <= v_pos; lk <= 3'd0;
            mr <= 4'd0; mg <= 4'd0; mb <= 4'd0;
        end else if (lk < 3'd3) begin
            if (lhit) begin
                if ((lmask[2] | lcore) && (lint > mr)) mr <= lint;
                if ((lmask[1] | lcore) && (lint > mg)) mg <= lint;
                if ((lmask[0] | lcore) && (lint > mb)) mb <= lint;
            end
            lk <= lk + 3'd1;
        end else if (lk == 3'd3) begin
            ln_r <= ({mr, mr} > bg_r) ? {mr, mr} : bg_r;
            ln_g <= ({mg, mg} > bg_g) ? {mg, mg} : bg_g;
            ln_b <= ({mb, mb} > bg_b) ? {mb, mb} : bg_b;
            lk   <= 3'd4;
        end
    end

    // =====================================================================
    // Display pipeline: A (region) -> B -> C (emit). Copper's colour is a
    // per-LINE register, so no coordinate rides the pipeline any more -- the
    // two stages exist purely to match idle_logo's 3-cycle output latency.
    // =====================================================================
    wire [11:0] hq     = h_pos - VIZ_QX_LEAD;
    wire        in_act = (hq < 12'd720) && (v_pos < act_h);

    reg a_in, b_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_in <= 1'b0; b_in <= 1'b0;
            viz_on <= 1'b0; viz_r <= 8'd0; viz_g <= 8'd0; viz_b <= 8'd0;
        end else begin
            a_in   <= vis && in_act && (mode == M_COPPER);
            b_in   <= a_in;
            viz_on <= b_in;
            if (b_in) begin
                viz_r <= ln_r; viz_g <= ln_g; viz_b <= ln_b;
            end
        end
    end

endmodule

`default_nettype wire
