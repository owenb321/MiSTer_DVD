//============================================================================
//  dvd/cdda_viz.sv -- audio-reactive visualizers for WAV / CD-DA playback.
//
//  An audio CD has no picture, so the screen used to be the bouncing idle logo.
//  This adds three demoscene-style alternatives, cycled with the Angle button
//  (which does nothing on a CD otherwise -- emu.sv owns the mode register):
//
//    mode 0  COPPER BARS -- five sine-driven gradient bars over a dark ramp,
//                           the Amiga "copper list" look
//    mode 1  XOR PATTERN -- scrolling (x ^ y) "munching squares"
//    mode 2  SCOPE       -- two oscilloscope traces, L above R, triggered on
//                           L's rising zero crossing so a steady tone stands still
//    mode 3  off         -- emu shows the idle logo instead
//
//  All three react to the music through ONE shared analysis: a peak envelope of
//  (|L|+|R|) with a per-frame decay, a slow average of it, and a "kick" timer
//  armed when the envelope jumps well above that average.
//
//  ★ THE BUDGET IS THE DESIGN (the core sits at ~98 % ALM):
//   - NO FRAMEBUFFER. Every pixel is a function of (x, y) and a few per-frame
//     registers, so nothing here scales with screen area.
//   - COPPER IS PER LINE, NOT PER PIXEL. When v_pos changes the five bars are
//     tested SERIALLY (one comparator, six clocks, all inside horizontal
//     blanking) and the colour is held for the whole line. Per-pixel cost: 0.
//   - Bar POSITIONS are serial too, once per FRAME, through ONE quarter-wave
//     sine table and shift-add amplitudes -- no multiplier, no DSP block.
//   - SCOPE stores precomputed SCREEN ROWS, not samples, so the display path
//     only compares; 360 x 20 bits fits one M10K.
//   - Three registered display stages, the same as idle_logo, so both share
//     emu's overlay slot with the same horizontal lead (VIZ_QX_LEAD).
//
//  ⚠ The scope decimates dec_audio_l/r to ~6.6 kHz with no anti-alias filter.
//  It is a picture, not a measurement: aliasing just makes bright material draw
//  a slightly busier trace.
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
    input  wire  [1:0] mode,                  // 0 copper, 1 xor, 2 scope, 3 off

    input  wire [15:0] audio_l,               // signed PCM, held between samples
    input  wire [15:0] audio_r,

    output reg         viz_on,
    output reg   [7:0] viz_r,
    output reg   [7:0] viz_g,
    output reg   [7:0] viz_b
);

    localparam [1:0] M_COPPER = 2'd0, M_XOR = 2'd1, M_SCOPE = 2'd2;

    wire [11:0] act_h = pal_mode ? 12'd576 : 12'd480;

    // =====================================================================
    // Shared audio analysis
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
                // silence: ~17 s per sine cycle; loud: ~1.3 s
                t <= t + 16'd16 + {8'd0, env};
            end
        end
    end

    wire [7:0] p8 = t[13:6];

    // =====================================================================
    // COPPER: bar positions, solved serially once per frame
    // =====================================================================
    reg  [2:0] pk;                             // bar being solved; 5 = idle
    reg  [9:0] y0, y1, y2, y3, y4;
    wire [7:0] bar_off = {1'b0, pk, 4'b0000} + {2'b00, pk, 3'b000};   // pk * 24
    wire [7:0] sn_ph   = p8 + bar_off;

    // quarter-wave sine magnitude, mirrored by phase bit 6, signed by bit 7
    wire [5:0] sq_i = sn_ph[6] ? ~sn_ph[5:0] : sn_ph[5:0];
    reg  [6:0] sq;
    always @(*) begin
        case (sq_i)
            6'd0: sq = 7'd2;
            6'd1: sq = 7'd5;
            6'd2: sq = 7'd8;
            6'd3: sq = 7'd11;
            6'd4: sq = 7'd14;
            6'd5: sq = 7'd17;
            6'd6: sq = 7'd20;
            6'd7: sq = 7'd23;
            6'd8: sq = 7'd26;
            6'd9: sq = 7'd29;
            6'd10: sq = 7'd32;
            6'd11: sq = 7'd35;
            6'd12: sq = 7'd38;
            6'd13: sq = 7'd41;
            6'd14: sq = 7'd44;
            6'd15: sq = 7'd47;
            6'd16: sq = 7'd50;
            6'd17: sq = 7'd53;
            6'd18: sq = 7'd56;
            6'd19: sq = 7'd58;
            6'd20: sq = 7'd61;
            6'd21: sq = 7'd64;
            6'd22: sq = 7'd67;
            6'd23: sq = 7'd69;
            6'd24: sq = 7'd72;
            6'd25: sq = 7'd74;
            6'd26: sq = 7'd77;
            6'd27: sq = 7'd79;
            6'd28: sq = 7'd82;
            6'd29: sq = 7'd84;
            6'd30: sq = 7'd86;
            6'd31: sq = 7'd89;
            6'd32: sq = 7'd91;
            6'd33: sq = 7'd93;
            6'd34: sq = 7'd95;
            6'd35: sq = 7'd97;
            6'd36: sq = 7'd99;
            6'd37: sq = 7'd101;
            6'd38: sq = 7'd103;
            6'd39: sq = 7'd105;
            6'd40: sq = 7'd106;
            6'd41: sq = 7'd108;
            6'd42: sq = 7'd110;
            6'd43: sq = 7'd111;
            6'd44: sq = 7'd113;
            6'd45: sq = 7'd114;
            6'd46: sq = 7'd115;
            6'd47: sq = 7'd117;
            6'd48: sq = 7'd118;
            6'd49: sq = 7'd119;
            6'd50: sq = 7'd120;
            6'd51: sq = 7'd121;
            6'd52: sq = 7'd122;
            6'd53: sq = 7'd123;
            6'd54: sq = 7'd124;
            6'd55: sq = 7'd124;
            6'd56: sq = 7'd125;
            6'd57: sq = 7'd125;
            6'd58: sq = 7'd126;
            6'd59: sq = 7'd126;
            6'd60: sq = 7'd127;
            6'd61: sq = 7'd127;
            6'd62: sq = 7'd127;
            6'd63: sq = 7'd127;
            default: sq = 7'd0;
        endcase
    end
    wire [8:0] sn   = sn_ph[7] ? (9'd0 - {2'b00, sq}) : {2'b00, sq};   // +/-127
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
            pk <= 3'd5;
            y0 <= 10'd120; y1 <= 10'd180; y2 <= 10'd240; y3 <= 10'd300; y4 <= 10'd360;
        end else if (frame_tick) begin
            pk <= 3'd0;
        end else if (pk < 3'd5) begin
            case (pk)
                3'd0:    y0 <= y_new;
                3'd1:    y1 <= y_new;
                3'd2:    y2 <= y_new;
                3'd3:    y3 <= y_new;
                default: y4 <= y_new;
            endcase
            pk <= pk + 3'd1;
        end
    end

    // =====================================================================
    // COPPER: line colour, solved serially once per LINE
    // =====================================================================
    reg [11:0] v_q;
    reg  [2:0] lk;                             // bar under test; 5 resolve, 6 done
    reg  [3:0] mr, mg, mb;                     // running max intensity per channel
    reg  [7:0] ln_r, ln_g, ln_b;               // this line's colour
    reg  [9:0] ly;
    reg  [2:0] lmask;                          // {r,g,b} the bar lights
    always @(*) begin
        case (lk)
            3'd0:    begin ly = y0; lmask = 3'b100; end   // red
            3'd1:    begin ly = y1; lmask = 3'b110; end   // yellow
            3'd2:    begin ly = y2; lmask = 3'b010; end   // green
            3'd3:    begin ly = y3; lmask = 3'b011; end   // cyan
            default: begin ly = y4; lmask = 3'b101; end   // magenta
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
            v_q <= 12'd0; lk <= 3'd6;
            mr <= 4'd0; mg <= 4'd0; mb <= 4'd0;
            ln_r <= 8'd0; ln_g <= 8'd0; ln_b <= 8'd0;
        end else if (v_pos != v_q) begin
            v_q <= v_pos; lk <= 3'd0;
            mr <= 4'd0; mg <= 4'd0; mb <= 4'd0;
        end else if (lk < 3'd5) begin
            if (lhit) begin
                if ((lmask[2] | lcore) && (lint > mr)) mr <= lint;
                if ((lmask[1] | lcore) && (lint > mg)) mg <= lint;
                if ((lmask[0] | lcore) && (lint > mb)) mb <= lint;
            end
            lk <= lk + 3'd1;
        end else if (lk == 3'd5) begin
            ln_r <= ({mr, mr} > bg_r) ? {mr, mr} : bg_r;
            ln_g <= ({mg, mg} > bg_g) ? {mg, mg} : bg_g;
            ln_b <= ({mb, mb} > bg_b) ? {mb, mb} : bg_b;
            lk   <= 3'd6;
        end
    end

    // =====================================================================
    // XOR: per-frame scroll + colour phase
    // =====================================================================
    reg [8:0] sx, sy;
    reg [7:0] tc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sx <= 9'd0; sy <= 9'd0; tc <= 8'd0;
        end else if (frame_tick) begin
            sx <= sx + 9'd1;
            sy <= sy + 9'd1 + {6'd0, env[7:5]};
            tc <= tc + 8'd2 + {4'd0, env[7:4]};
        end
    end
    wire [7:0] thr = p8;                       // munching threshold sweeps

    // =====================================================================
    // SCOPE: triggered capture of screen rows
    // =====================================================================
    localparam [8:0] CAP_N = 9'd360;           // one sample per 2-px column
    (* ramstyle = "M10K, no_rw_check" *) reg [19:0] sc_ram [0:511];

    wire [9:0] c_l = pal_mode ? 10'd136 : 10'd112;
    wire [9:0] c_r = pal_mode ? 10'd316 : 10'd262;
    // +/-96 rows at full scale = s>>9 + s>>10, sign-extended
    wire [9:0] off_l = {{3{audio_l[15]}}, audio_l[15:9]} + {{4{audio_l[15]}}, audio_l[15:10]};
    wire [9:0] off_r = {{3{audio_r[15]}}, audio_r[15:9]} + {{4{audio_r[15]}}, audio_r[15:10]};
    wire [9:0] row_l = c_l + off_l;
    wire [9:0] row_r = c_r + off_r;

    reg  [8:0] wa;
    reg        cap, l_neg_q;
    reg [10:0] trig_to;
    wire       sc_we = s_tick && cap;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wa <= 9'd0; cap <= 1'b1; l_neg_q <= 1'b0; trig_to <= 11'd0;
        end else if (s_tick) begin
            l_neg_q <= audio_l[15];
            if (cap) begin
                if (wa == CAP_N - 9'd1) begin
                    wa <= 9'd0; cap <= 1'b0; trig_to <= 11'd0;
                end else
                    wa <= wa + 9'd1;
            end else begin
                trig_to <= trig_to + 11'd1;
                // L rising through zero -- or give up, so silence still draws
                if ((l_neg_q && !audio_l[15]) || (trig_to == 11'h7FF))
                    cap <= 1'b1;
            end
        end
    end

    reg  [8:0] ra;
    reg [19:0] sc_q;
    always @(posedge clk) begin                // sync RAM, no reset (M10K)
        if (sc_we) sc_ram[wa] <= {row_l, row_r};
        sc_q <= sc_ram[ra];
    end

    // =====================================================================
    // Display pipeline: A (region, coords) -> B (RAM read, xor) -> C (resolve)
    // =====================================================================
    wire [11:0] hq     = h_pos - VIZ_QX_LEAD;
    wire        in_act = (hq < 12'd720) && (v_pos < act_h);

    reg        a_in, b_in;
    reg [11:0] a_v, b_v;
    reg  [8:0] a_xv, a_yv, b_m, b_ci;
    reg  [8:0] c_ci_last;
    reg [19:0] col_cur, col_prev;

    // scope span: each column is 2 px wide, so the trace joins this column's
    // row to the previous column's -- a line, not a dotted plot
    wire        new_col = (b_ci != c_ci_last);
    wire [19:0] s_now   = new_col ? sc_q : col_cur;
    wire [19:0] s_prv   = (b_ci == 9'd0) ? s_now : (new_col ? col_cur : col_prev);
    wire  [9:0] nl = s_now[19:10], pl = s_prv[19:10];
    wire  [9:0] nr = s_now[9:0],   pr = s_prv[9:0];
    wire  [9:0] lo_l = (nl < pl) ? nl : pl;
    wire  [9:0] hi_l = (nl < pl) ? pl : nl;
    wire  [9:0] lo_r = (nr < pr) ? nr : pr;
    wire  [9:0] hi_r = (nr < pr) ? pr : nr;
    wire        vok  = (b_v[11:10] == 2'b00);
    wire        on_l = vok && (b_v[9:0] >= lo_l) && (b_v[9:0] <= hi_l);
    wire        on_r = vok && (b_v[9:0] >= lo_r) && (b_v[9:0] <= hi_r);
    wire        on_g = vok && b_ci[1] && ((b_v[9:0] == c_l) || (b_v[9:0] == c_r));

    wire [7:0] xc   = b_m[7:0] + tc;
    wire       xlit = (b_m[7:0] < thr) ^ kick[3];
    wire [7:0] xr   = xc;
    wire [7:0] xg   = {xc[5:0], xc[7:6]};
    wire [7:0] xb   = ~xc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_in <= 1'b0; a_v <= 12'd0; a_xv <= 9'd0; a_yv <= 9'd0; ra <= 9'd0;
            b_in <= 1'b0; b_v <= 12'd0; b_m <= 9'd0; b_ci <= 9'd0;
            c_ci_last <= 9'h1FF; col_cur <= 20'd0; col_prev <= 20'd0;
            viz_on <= 1'b0; viz_r <= 8'd0; viz_g <= 8'd0; viz_b <= 8'd0;
        end else begin
            // A
            a_in <= vis && in_act && (mode != 2'd3);
            a_v  <= v_pos;
            a_xv <= hq[9:1] + sx;
            a_yv <= v_pos[9:1] + sy;
            ra   <= hq[9:1];
            // B (sc_q lands here, read at ra)
            b_in <= a_in;
            b_v  <= a_v;
            b_m  <= a_xv ^ a_yv;
            b_ci <= ra;
            // C
            if (new_col) begin
                c_ci_last <= b_ci;
                col_prev  <= col_cur;
                col_cur   <= sc_q;
            end
            viz_on <= 1'b0;
            if (b_in) begin
                case (mode)
                    M_COPPER: begin
                        viz_on <= 1'b1;
                        viz_r <= ln_r; viz_g <= ln_g; viz_b <= ln_b;
                    end
                    M_XOR: begin
                        viz_on <= 1'b1;
                        if (xlit) begin viz_r <= xr; viz_g <= xg; viz_b <= xb; end
                        else begin
                            viz_r <= {3'b000, xr[7:3]};
                            viz_g <= {3'b000, xg[7:3]};
                            viz_b <= {3'b000, xb[7:3]};
                        end
                    end
                    M_SCOPE: begin
                        viz_on <= on_l | on_r | on_g;
                        if (on_l && on_r)  begin viz_r <= 8'hFF; viz_g <= 8'hFF; viz_b <= 8'hFF; end
                        else if (on_l)     begin viz_r <= 8'h40; viz_g <= 8'hFF; viz_b <= 8'h60; end
                        else if (on_r)     begin viz_r <= 8'hFF; viz_g <= 8'hB0; viz_b <= 8'h30; end
                        else               begin viz_r <= 8'h38; viz_g <= 8'h38; viz_b <= 8'h38; end
                    end
                    default: ;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
