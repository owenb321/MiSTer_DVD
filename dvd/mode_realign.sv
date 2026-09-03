/*
 * mode_realign.sv — a live raster-mode change must RE-ALIGN THE READER, not flush in place
 *
 * DVD-FORK (2026-09-03, issue #42). Fixes: changing `Video Output` mid-title could freeze
 * the decoder on a malformed frame, with no self-recovery, on either standard. A chapter
 * seek cleared it.
 *
 * ★ THE MECHANISM. A mode switch fired the full flush trio through dvd/flush_ctl.sv
 * (load_flush + aud_flush + seek_flush) but DID NOT MOVE THE READER, so the decoder
 * resumed mid-VOBU with no GOP boundary to re-lock on. That a chapter seek cured it is
 * the whole diagnosis: a seek is the same trio PLUS a reader jump to a boundary. Same
 * trap the reverted film-engage flush died of (docs/film_24p_plan.md §13): "each flap
 * flushed at an arbitrary mid-stream position (no reader jump = no VOBU re-alignment),
 * garbage seq headers ... flipped pal_eff ... = a self-feeding corruption loop".
 *
 * So: don't synthesize the trio here. Issue a SEEK and let the reader's seek_ack drive
 * the trio, which makes a mode switch byte-identical to a chapter jump — the contract
 * that is HW-proven to re-sync cleanly.
 *
 * ★ THE TARGET IS THE CURRENT VOBU, AND THAT IS WHY IT IS CHEAP. dsi_nv_pck_lbn IS the
 * RBN of the NAV pack of the VOBU being demuxed, in the same VTSTT_VOBS space seek_rbn
 * uses. The reader arms its VOBU-snap probe at the target and tests that sector first
 * (dvd_iso_reader.sv S_NAV_SEEK), so the snap HITS on candidate #1 and moves nowhere:
 * ONE 2048-byte sector read. Targeting the NEXT VOBU instead would walk forward a sector
 * at a time up to NAV_CAP=1024 reads. Restarting the VOBU being parsed also re-supplies
 * roughly what the VBUF flush discards, so no content is skipped.
 *
 * ★ EDGES ARE COALESCED, AND THAT IS A CORRECTNESS PROPERTY, NOT AN OPTIMISATION. il_eff
 * is a LEVEL: the modeline walk always converges on its final value, so N toggles need
 * exactly ONE re-align. Absorbing further edges while an arm is open is what makes the
 * "repeated mid-parse flush" loop class — the thing that killed the film edge —
 * structurally unreachable from this path. A future filmp_eff edge belongs here for
 * exactly that reason, and must never go straight into flush_ctl.
 *
 * ★ THE FALLBACK IS THE OLD BEHAVIOUR, ON PURPOSE. Where no re-align is possible (a disc
 * menu, a raw .m2v elementary stream, a still, no trustworthy playhead yet) or where the
 * reader does not acknowledge within WDOG, mode_switch pulses and the in-place trio fires
 * exactly as before. A mode change can therefore never silently lose its flush, and there
 * is no toggle to add for it (a CONF_STR string edit alone re-rolls the pinned fitter
 * seed — see DVD.qsf's ledger).
 *
 * ⚠ THE STALE-PLAYHEAD TRAP (dvd/dpad_seek.sv hit this first; its header is the long
 * version). nav_dsi's reset is pipe_rst_n, so ANY load_flush clears dsi_nv_pck_lbn to 0 —
 * including the one this module's own seek causes. Re-sampling the playhead later reads 0
 * and the reader's clamp turns that into a jump to the start of the title. Hence
 * dsi_fresh, and hence tgt_rbn is latched exactly ONCE, on the issuing cycle.
 *
 * ⚠ A keep_vbuf ack is NOT a completion. A menu->menu hop fires load_flush only (audio
 * continuity, docs/dvd_menu_refinements.md §5d), so it does not give the mode switch the
 * trio it needs. Such an ack leaves the arm open; the watchdog then fires the fallback,
 * which is right — by then we are in a menu, where a re-align is not possible anyway.
 *
 * ★ THE SWITCH BLANK (2026-09-03, user request after the issue #42 HW round). Fixing the
 * freeze left the ~1 s transient visible, and it is ugly: switching TO Interlaced shows a
 * full-screen rolling image flashing between black frames (the display losing vertical
 * lock across the raster change), and switching TO Progressive squishes the picture into
 * the top half (field-height content in a frame-height DE window). Both are inherent to
 * changing the raster under in-flight content, so the fix is cosmetic: hold the picture
 * BLACK until the first frame of the new mode is actually on screen.
 *
 * ★ The window needs no new measurement — `video_live` already IS that signal. The
 * re-align's own load_flush re-arms it (via pickup_hold in resample_addrgen), so it goes
 * LOW at the flush and HIGH again when the governor picks up the first frame for display.
 * So: blank on the edge, and clear on the first `video_live` HIGH *after* observing it go
 * LOW. Requiring the drop first is what makes it robust — at the edge itself video_live is
 * still high from the OLD content (the flush lands a few ms later), so a naive "clear when
 * video_live" would clear immediately and blank nothing.
 *
 * ⚠ BLANK_MAX is not a nicety, it is load-bearing twice over. (1) In the MENU domain
 * `video_live` never drops — emu forces the STD mux-lead hold off while `menu_active`
 * (menus aren't lip-synced), so pickup_hold never rises and nothing re-arms video_live.
 * The timeout is the ONLY exit there. (2) It bounds the cosmetic fix so it can only ever
 * hide a TRANSIENT: if the roll or the squish ever outlived the window, the artifact must
 * come back into view rather than be masked forever.
 *
 * ⚠ blank_en (emu wires it to `media_seen`) keeps the blank off until the user has mounted
 * something. Without it the boot-time mode_edge — il_eff_q resets to 0, so an
 * Interlaced/Auto-analog rig pulses one at reset release — would black out the idle
 * screen for the whole timeout, and "nothing on screen after the core loads" is exactly
 * what the launch-feedback work exists to prevent (docs/idle_screen.md).
 *
 * ⛔ "REPEAT THE LAST GOOD FRAME" WAS THE OTHER CANDIDATE AND IS WEAKER, despite the
 * machinery already existing (the governor's persistence re-scan, repeat_frame=31, as used
 * by pause and hold_freeze). Three reasons: the Interlaced symptom is a ROLL, i.e. the
 * display has lost lock, so a held frame rolls too — a rolling still is no better than a
 * rolling picture, whereas rolling BLACK is invisible; the re-scan goes back through the
 * same mode-dependent scan path that produces the Progressive squish, and the held image
 * was built for the OLD mode, so it is not obviously immune to the artifact it is meant to
 * hide; and it needs the coordinated hold set (watchdog suppression et al.), where
 * freezing video without audio for ~1 s diverges the timelines the flush just re-anchored.
 * Blanking acts at the PIN, after every mode-dependent path, so it is immune by
 * construction. See docs/single_raster_analog.md §7.
 *
 * ⚠ emu blanks RGB ONLY, never sync. That is the re_interlace S_HUNT defect
 * (docs/single_raster_analog.md §3.2): it emitted no sync at all while hunting, costing
 * 33-67 ms of dead CRT sync per event. Killing sync across a raster change lengthens the
 * lock-up instead of hiding it.
 *
 * NOTE ON THE DEFERRAL WINDOW. il_eff is combinational off the OSD bits, so the raster
 * (and VGA_F1, CE_PIXEL, the pixrep overlay inverses) still changes the instant the user
 * commits, exactly as before — only the FLUSH moves, to the moment it can land on a GOP
 * boundary. For those few ms the new raster shows the old timeline's already-decoded
 * frames, which is strictly less perturbing than flushing mid-parse. If a hardware round
 * ever shows the freeze surviving this, the remaining suspect is the RASTER RESTART, and
 * the next step is to gate il_out on ~realign_pend so the walk and the flush land
 * together — one behavioural delta at a time (docs/single_raster_analog.md §3.9).
 */

`default_nettype none

module mode_realign #(
    parameter [23:0] WDOG      = 24'd13_500_000, // ~0.5 s @ 27 MHz clk_sys
    parameter [25:0] BLANK_MAX = 26'd40_500_000  // ~1.5 s: the blank's hard ceiling
) (
    input  wire        clk,              // clk_sys (27 MHz)
    input  wire        rst_n,            // core reset_n — NOT pipe_rst_n: the arm has to
                                         // survive the very load_flush it causes

    input  wire        mode_edge,        // 1-cyc: a live raster-regime change (il_switch)

    // ---- context: is a re-align possible at all? -------------------------------------
    input  wire        in_title,         // title-domain playback (not a disc menu)
    input  wire        dvd_mode,         // cell mode: the DSI playhead is the base
    input  wire        lin_mode,         // linear file: the linear block is the base
    input  wire        still_active,     // reader parked on a still — nothing to re-align
    input  wire        hold_freeze,      // a Fast Fwd / Rewind gesture owns the playhead

    // ---- the base, and whether it can be trusted -------------------------------------
    input  wire        nav_flush,        // load_flush: nav_dsi scalars cleared => STALE
    input  wire        dsi_commit,       // 1-cyc: a DSI packet finished parsing
    input  wire        dsi_stream,       // DSI bytes are rewriting nav_dsi right now
    input  wire [31:0] dsi_nv_pck_lbn,   // VOBU NAV-pack RBN (the demux front)
    input  wire [31:0] lin_blk,          // linear playhead block

    // ---- reader feedback -------------------------------------------------------------
    input  wire        seek_ack,         // reader executed a transport seek
    input  wire        jump_ack,         // reader executed a VM jump
    input  wire        keep_vbuf,        // valid on the ack: 1 = menu hop, load_flush only
    input  wire        start_streaming,  // a new file was mounted => cancel

    // ---- switch blank ----------------------------------------------------------------
    input  wire        video_live,       // "the display is showing a decoded frame"
                                         // (re-armed by our own flush, see the header)
    input  wire        blank_en,         // media_seen: never blank the boot idle screen

    // ---- the other producer of the reader's single RBN-seek port ---------------------
    input  wire        scrub_pulse,      // dvd/scrub_ctrl.sv seek_rbn_pulse
    input  wire [31:0] scrub_rbn,        // dvd/scrub_ctrl.sv seek_rbn

    // ---- outputs ---------------------------------------------------------------------
    output wire        seek_rbn_pulse,   // -> dvd_iso_reader (the arbitrated port)
    output wire [31:0] seek_rbn,
    output reg         mode_switch,      // -> flush_ctl: THE IN-PLACE FALLBACK ONLY
    output wire        realign_pend,     // level: an arm is open (debug readout / gating)
    output wire        sw_blank          // level: hold the picture black (RGB only!)
);

localparam [1:0] S_IDLE = 2'd0,   // nothing pending
                 S_ARM  = 2'd1,   // waiting for a trustworthy base
                 S_ACK  = 2'd2;   // a seek is in flight

reg  [1:0]  state;
reg  [23:0] tmr;                  // watchdog countdown (frozen while hold_freeze)
reg  [31:0] tgt_rbn;              // the base, latched ONCE on the issuing cycle
reg         issue_p;              // 1-cyc: our seek
reg         dsi_fresh;            // dsi_nv_pck_lbn belongs to a parsed DSI, not to a flush

// Can a re-align be attempted at all? The reader only latches an RBN seek in cell mode or
// on a seekable linear file, and its VOBU-snap probe is bypassed in the menu domain, so
// this mirrors the reader's own preconditions rather than inventing new ones. A raw .m2v
// needs no special case: lin_seek_ok is already low for a bare elementary stream.
wire possible  = in_title && (dvd_mode || lin_mode) && ~still_active;

// ⚠ dvd_mode is checked FIRST: on a DVD title the linear block is meaningless.
wire [31:0] base = dvd_mode ? dsi_nv_pck_lbn : lin_blk;
wire        base_ok  = (dvd_mode && dsi_fresh && ~dsi_stream && ~dsi_commit) || lin_mode;
wire        can_issue = possible && base_ok && ~hold_freeze;

// An ack only completes the arm if it carried the full trio. A keep_vbuf menu hop did not.
wire        ack_done = (seek_ack || jump_ack) && ~keep_vbuf;

always @(posedge clk) begin
    if (~rst_n) begin
        state       <= S_IDLE;
        tmr         <= 24'd0;
        tgt_rbn     <= 32'd0;
        issue_p     <= 1'b0;
        mode_switch <= 1'b0;
        dsi_fresh   <= 1'b0;
    end else begin
        issue_p     <= 1'b0;             // both outputs are one-cycle pulses
        mode_switch <= 1'b0;

        // Freshness of the DSI scalars, shape copied from dvd/dpad_seek.sv.
        if (nav_flush)       dsi_fresh <= 1'b0;
        else if (dsi_commit) dsi_fresh <= 1'b1;

        if (start_streaming) begin
            // A mount supersedes: it fires its own trio AND the decoder soft reset, and
            // tgt_rbn would belong to the PREVIOUS disc. Cancel silently — emitting the
            // fallback here would add a second flush on top of the mount's.
            state <= S_IDLE;
            tmr   <= 24'd0;
        end else begin
            case (state)
            S_IDLE:
                // Note only S_IDLE looks at mode_edge: further edges during an arm are
                // ABSORBED. See the coalescing note in the header.
                if (mode_edge) begin
                    if (possible) begin
                        state <= S_ARM;
                        tmr   <= WDOG;
                    end else
                        mode_switch <= 1'b1;         // fallback: today's in-place trio
                end

            S_ARM:
                if (ack_done)             state <= S_IDLE;   // something else already did it
                else if (scrub_pulse)     state <= S_ACK;    // the user's seek is a superset
                else if (can_issue) begin
                    tgt_rbn <= base;                         // latched ONCE
                    issue_p <= 1'b1;
                    tmr     <= WDOG;
                    state   <= S_ACK;
                end else if (~hold_freeze) begin
                    // A held scrub is not a timeout: its release issues a seek that
                    // satisfies this arm, so freeze the budget instead of spending it.
                    if (tmr == 24'd0) begin
                        mode_switch <= 1'b1;
                        state       <= S_IDLE;
                    end else
                        tmr <= tmr - 24'd1;
                end

            S_ACK:
                if (ack_done)             state <= S_IDLE;
                else if (tmr == 24'd0) begin
                    mode_switch <= 1'b1;                     // the seek never landed
                    state       <= S_IDLE;
                end else
                    tmr <= tmr - 24'd1;

            default: state <= S_IDLE;
            endcase
        end
    end
end

// ---------------------------------------------------------------------------------
// SWITCH BLANK. Deliberately a SEPARATE state machine from the seek arm above: it must
// cover the raster change, which happens at the OSD edit whichever path the seek takes
// (re-align or in-place fallback), and it outlives the arm by ~an order of magnitude (the
// seek lands in ms; the decoder re-locks in ~a second).
reg         blank_r;
reg  [25:0] blank_tmr;
reg         vl_dropped;      // video_live has gone LOW since the blank started

always @(posedge clk) begin
    if (~rst_n) begin
        blank_r    <= 1'b0;
        blank_tmr  <= 26'd0;
        vl_dropped <= 1'b0;
    end else if (start_streaming) begin
        // A mount cuts to black and cold-starts on its own (flush trio + the decoder soft
        // reset), so it needs no help from here — and holding a blank across it would just
        // delay the new disc's first frame.
        blank_r    <= 1'b0;
        blank_tmr  <= 26'd0;
        vl_dropped <= 1'b0;
    end else if (mode_edge && blank_en) begin
        // Re-triggers if another edge arrives mid-blank: the raster changed again, so the
        // window restarts. (The SEEK arm coalesces; the blank must not, or a second toggle
        // would uncover the transient it caused.)
        blank_r    <= 1'b1;
        blank_tmr  <= BLANK_MAX;
        vl_dropped <= 1'b0;
    end else if (blank_r) begin
        if (~video_live)              vl_dropped <= 1'b1;
        if (vl_dropped && video_live) blank_r    <= 1'b0;   // first new-mode frame on screen
        else if (blank_tmr == 26'd0)  blank_r    <= 1'b0;   // menu path + the safety ceiling
        else                          blank_tmr  <= blank_tmr - 26'd1;
    end
end

assign sw_blank = blank_r;

// The scrub ALWAYS wins the mux, so even in a state the FSM does not allow the reader
// latches the user's target rather than ours; the resulting seek_ack then completes the
// arm. There is no cycle in which the reader can see a pulse with the wrong target.
assign seek_rbn_pulse = scrub_pulse | issue_p;
assign seek_rbn       = scrub_pulse ? scrub_rbn : tgt_rbn;
assign realign_pend   = (state != S_IDLE);

endmodule

`default_nettype wire
