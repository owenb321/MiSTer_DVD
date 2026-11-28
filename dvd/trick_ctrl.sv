// ============================================================================
// dvd/trick_ctrl.sv -- hold Fast Fwd / Rewind = trick play (docs/trick_play.md)
// ============================================================================
// Decision 1 (maintainer, 2026-11-22): in a DVD title, holding FF/REW plays the
// title forwards or backwards at speed, showing one I-frame every 250 ms, instead of
// dvd/scrub_ctrl.sv's freeze-and-seek-on-release. scrub_ctrl keeps .mpg/VCD and any
// DVD state where trick play is not allowed (`allowed` low: menu, still, buttons).
//
//   IDLE --press, allowed--> ENTER: trick_en/aud_drop/cadence/filter up, ONE seek to
//          the playhead. The seek's flush throws away the seconds of normal video
//          buffered ahead in the VBUF, so the first trick frame comes at once, and
//          the reader (trick_en already high) arms at the landing's first NAV pack.
//   RUN   tier from hold time (16x, 40x, 120x, 480x after 0 / T1 / T2 / T3), trick_go
//          every GO_PERIOD (250 ms: the cadence gate, decision 4).
//   EXIT  on release, a change of direction, `allowed` falling, or the reader at the
//          PGC's edge: ONE seek to the VOBU whose time the HUD shows, then idle until
//          both buttons are released (so a held button cannot re-enter at once). At the
//          edge it is the edge VOBU itself: forward, the title then ends normally and
//          POST runs; back, play resumes at its start.
//
// ★ THE EXIT GOES WHERE THE HUD CLOCK SAYS (maintainer's decision, 2026-11-27). The HUD
// clock is the cell start plus the c_eltm of the last NAV pack the demux parsed, and
// `cur_rbn` (dsi_nv_pck_lbn) is that same pack's sector, so seeking to cur_rbn resumes
// play at exactly the time on the clock. The trick picture on screen lags it: the
// decoder and its cadence slot hold pictures the demux has already passed (two rungs,
// ~44 s, on The Matrix at 120x). dev-trickplay9/10 exited to the picture on screen
// instead (a queue of armed VOBUs popped by display pickups), which made the clock
// step BACK at every release; the maintainer chose the clock as the reference, so the
// picture now steps forward to it. The queue, its pickup/skip inputs and its overflow
// fallback are gone. Released before the demux parsed any trick NAV pack, cur_rbn is
// still the landing of the entry seek: the entry point.
//
// ★ THE TAIL. Between the exit seek and the flush it causes, the stream already past
// the reader still reaches the demux and the decoder. With trick play off at once that
// tail played unfiltered: the rest of the VOBU's pictures leaked onto the screen for
// ~80 ms, unpinned, before the landing (white-rabbit frames between Neo and the club,
// same capture). `tail` holds from the exit seek to the reader's `flush` (its seek_ack)
// so dvd/emu.sv keeps the ES filter, audio drop and cadence up through it. A seek that
// never acks would hold the filter for ever: TAIL_MAX ends it regardless.
//
// The seek pulses go to the reader's raw-RBN seek port (arbitrated with scrub_ctrl in
// dvd/emu.sv). `active` drops in the SAME cycle as the exit seek: the reader clears its
// trick state on a seek, and audio must be back on before the landing arrives.
// ============================================================================
`default_nettype none
module trick_ctrl #(
    parameter integer GO_PERIOD = 6_750_000,    // 250 ms at 27 MHz: one VOBU per period
    parameter integer T1        = 54_000_000,   // 2.0 s held -> 40x
    parameter integer T2        = 121_500_000,  // 4.5 s held -> 120x
    parameter integer T3        = 216_000_000,  // 8.0 s held -> 480x
    parameter integer TAIL_MAX  = 54_000_000    // 2.0 s: the tail ends even with no flush
) (
    input  wire        clk,                // clk_sys
    input  wire        rst_n,

    input  wire        held_ff,            // Fast Fwd held (level)
    input  wire        held_rew,           // Rewind held (level)
    input  wire        allowed,            // a DVD title playing: no menu, still or buttons
    input  wire [31:0] cur_rbn,            // the demux's last NAV pack = the HUD's time (entry and exit target)

    input  wire        trick_vobu,         // reader: a VOBU was armed
    input  wire [31:0] trick_nav,          // ...its NAV pack
    input  wire        trick_edge,         // reader: the PGC's edge, holding
    input  wire        flush,              // one clk: the reader executed a seek (seek_ack)

    output reg         active,             // trick play on: the reader, aud_drop, cadence, filter
    output reg  [1:0]  tier,               // 0..3 = 16x / 40x / 120x / 480x
    output reg         rev,                // 1 = backwards
    output reg         go,                 // one clk: the next jump may fire
    output reg         seek_pulse,         // one clk: a raw-RBN seek (entry or exit)
    output reg  [31:0] seek_rbn,
    output reg  [15:0] n_entries,          // trick-play sessions (telemetry)
    output reg         tail,               // exited, the exit seek not yet flushed
    // The gesture is trick play's: active, or exited and waiting for the release.
    // dvd/emu.sv keeps scrub_ctrl off FF/REW while this is high, so a button still
    // held after an exit does not start a scrub.
    output wire        owns
);
    reg [27:0] held_cnt;
    reg [22:0] go_cnt;
    reg [31:0] nav_last;                   // the latest armed VOBU (the edge exit)
    reg        need_rel;                   // exited: both buttons must be let go first
    reg [27:0] tail_cnt;

    assign owns = active || need_rel;
    wire held_dir = rev ? held_rew : held_ff;
    wire other    = rev ? held_ff  : held_rew;

    // The latest armed VOBU as of THIS clock, an arm arriving now included (the edge exit).
    wire [31:0] ex_last = trick_vobu ? trick_nav : nav_last;

    always @(posedge clk) begin
        go         <= 1'b0;
        seek_pulse <= 1'b0;
        if (!rst_n) begin
            active    <= 1'b0;
            tier      <= 2'd0;
            rev       <= 1'b0;
            held_cnt  <= 28'd0;
            go_cnt    <= 23'd0;
            nav_last  <= 32'd0;
            seek_rbn  <= 32'd0;
            n_entries <= 16'd0;
            need_rel  <= 1'b0;
            tail      <= 1'b0;
            tail_cnt  <= 28'd0;
        end else if (!active) begin
            if (tail) begin
                if (flush || tail_cnt >= TAIL_MAX - 1) tail <= 1'b0;
                tail_cnt <= tail_cnt + 28'd1;
            end
            // A press enters (a level: holding through `allowed` rising also enters;
            // pressing both at once is not a gesture and does nothing). After an exit
            // the buttons must be released first: still holding Rewind at the PGC's
            // start would otherwise re-enter, hit the edge and seek again, for ever.
            if (!held_ff && !held_rew) need_rel <= 1'b0;
            if (allowed && !need_rel && (held_ff ^ held_rew)) begin
                active     <= 1'b1;
                rev        <= held_rew;
                tier       <= 2'd0;
                held_cnt   <= 28'd0;
                go_cnt     <= 23'd0;
                tail       <= 1'b0;
                seek_rbn   <= cur_rbn;
                seek_pulse <= 1'b1;
                n_entries  <= n_entries + 16'd1;
            end
        end else begin
            if (trick_vobu) begin
                nav_last <= trick_nav;
            end
            if (!held_dir || other || !allowed || trick_edge) begin
                // EXIT: one seek to the VOBU whose time the HUD shows (see the header).
                // ★ The reader arms the edge VOBU and raises trick_edge in the SAME
                // clock, and a release can land on an arm's clock too: the exit must
                // see that arm (ex_*), not the registers it is updating. Exiting on the
                // stale nav_last stopped a rewind on TFA one VOBU short of the start
                // (sector 1339 = 0:07, not 0; 2026-11-24 HW, trick_ctrl_tb [10]/[11]).
                active     <= 1'b0;
                need_rel   <= 1'b1;
                tail       <= 1'b1;
                tail_cnt   <= 28'd0;
                seek_pulse <= 1'b1;
                seek_rbn   <= trick_edge ? ex_last : cur_rbn;
            end else begin
                if (held_cnt != 28'hFFFFFFF) held_cnt <= held_cnt + 28'd1;
                tier <= (held_cnt >= T3) ? 2'd3 : (held_cnt >= T2) ? 2'd2 :
                        (held_cnt >= T1) ? 2'd1 : 2'd0;
                if (go_cnt >= GO_PERIOD - 1) begin
                    go_cnt <= 23'd0;
                    go     <= 1'b1;
                end else begin
                    go_cnt <= go_cnt + 23'd1;
                end
            end
        end
    end
endmodule
`default_nettype wire
