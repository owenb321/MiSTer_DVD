// nav_pci.sv - DVD NAV-pack PCI/HLI capture + button state machine
// (Phase-3 disc menus: button highlights + gamepad navigation).
//
// Consumes the PCI byte stream ps_demux forwards for private_stream_2
// substream 0x00 (pci_byte/pci_valid/pci_frame_start, accept-always), keeps
// the HLI (highlight information, PCI bytes 0x60..0x315) in a DOUBLE-BUFFERED
// sync-read BRAM, and runs the button state: arm/expire against the
// presentation STC, current-button selection, D-pad link walking, and
// activation (manual / auto_action / forced-activate). The renderer gets
// REGISTERS ONLY (rect comparators + one 32-bit colour word) - display-hotspot
// safe; the 8-byte button command goes to emu's micro-bridge on activation.
//
// Field layout (rel. to PCI data start; verified against libdvdread
// nav_types.h/nav_read.c and real discs via tools/nav_extract.py):
//   hl_gi:  hli_ss u16@0x60 (low 2 bits: 0=none 1=NEW 2=equal 3=equal-but-cmds)
//           hli_s_ptm@0x62 hli_e_ptm@0x66 (BE u32, 90 kHz; 0xFFFFFFFF = forever)
//           btn_ns@0x71 (low 6) fosl_btnn@0x74 foac_btnn@0x75
//   btn_coli @0x76: 3 groups x {sl u32, ac u32}, nibbles [Ci3..Ci0 A3..A0]
//   btni     @0x8E: 36 x 18 B: b0-2 coln[1:0]+x1[9:0]+zz+x2[9:0];
//           b3-5 auto[1:0]+y1+zz+y2; b6-9 up/dn/lf/rt (low 6); b10-17 command
//
// v2 (HW round 1): the stream runs SECONDS ahead of presentation (VBUF), and
// discs like Matrix author a FINITE per-VOBU HLI window with ss=1 on EVERY
// NAV - a single committed slot gets replaced before its window ever opens
// (highlight never showed) and re-resetting the selection each VOBU snapped
// it back (~2/s). So commits now land in a PENDING slot and PROMOTE to the
// display slot when the STC reaches their start time (hli_s_ptm; ss=0 uses
// vobu_s_ptm to schedule the disarm) - intermediate pendings are simply
// overwritten (identical content on these discs). The SELECTION PERSISTS
// across promotes like the VM's SPRM8 (reset only when invalid, or fosl
// forces); e_ptm display-gating is dropped (a successor HLI or scheduled
// disarm replaces it - real menus rely on that, not on going dark).
// BUTTON GROUPS BY DISPLAY MODE (spec-hardening Phase 3, 2026-08-18): a disc
// may author 1..3 button-record groups (hl_gi.btngr_ns @0x6E[5:4]) with
// 36/18/12 records each, one group per display type (btngrX_dsp_ty, 3-bit:
// 000=4:3-normal, bit0=wide, bit1=letterbox, bit2=pan&scan — nav_types.h).
// The Phase-1 library audit measured btngr_ns=2 on 230/302 discs (anamorphic
// menus: group 1 = wide rects, group 2 = letterbox or pan&scan rects). The
// button record base selects the FIRST group whose dsp_ty matches the
// disp_wide/disp_mode inputs (group 1 fallback when nothing matches,
// bit-identical for btngr_ns==1 discs); a mode change while armed refetches
// the current button from the new group (rects swap; links/commands are
// authored identical across groups).
// ★ HW ROUND 1 LESSON (2026-08-18): what the CALLER must feed disp_mode is
// the verdict of the RENDERED SUBPICTURE VARIANT, not the raw display mode.
// Display-space groups assume the player composites the highlight at display
// resolution; this core composites in SOURCE space and scales the composite,
// so the aspect transform already applies to the highlight — feeding the raw
// display mode double-applied it (T2 Letterbox / MiB Crop: split highlights).
// emu therefore forces the wide verdict for menu-domain highlights (menus
// render source-space stream-0 art) and passes sp_disp_mode only for in-title
// highlights (which render the PR #115 mode-mapped substream variant). NOTE
// libdvdnav itself always reads group 1 (highlight.c btnit[button-1]) — for
// composite-then-scale pipelines that is geometrically correct, which is WHY
// it gets away with it.
// v2 scope still deferred: btn_se_e_ptm/CHG_COLCON, 32-bit 90 kHz STC compare.
//
// FOREVER-HLI DISARM IMMUNITY (T2 boot-menu fix): a scheduled ss=0 disarm (off_v) must
// not tear down a highlight the disc authored with hli_e_ptm == 0xFFFFFFFF ("forever").
// Menus reached after a preceding animation cell (T2's "theatrical/special" selector sits
// on an indefinite still after a ~9 s fly-in) leave that animation's trailing ss=0 parked
// as a pending disarm on the OLD cell's presentation timeline; once we settle on the still
// the STC keeps advancing (a real player freezes it on a still) and eventually crosses the
// stale off time, disarming a forever highlight ~10 s in - after which Select mis-routed to
// resume and the menu restarted. `h_forever` (captured from f_eptm) gates off_due so an
// armed forever HLI is immune. See f_eptm capture + off_due below.

module nav_pci #(
    // Fallback promotion timer (video live, STC never due). RE-TUNED 2026-08-05
    // (highlight-early polish): the age starts when the HLI arms at the PARSE
    // front — i.e. near the START of a menu transition, not its end — so a short
    // timer promoted mid-animation on every disc. The settled-menu case now has
    // its own trigger (menu_settled below, faster AND correct); this timer is
    // only the safety net for LOOPING motion menus that never park on a still,
    // RE-TUNED to ~1 s (2026-08-06): every PARKING menu promotes via settle now,
    // so the timer's only clients are LOOPING motion menus (MiB pages/root) whose
    // page transitions are sub-second — 2.5 s felt sluggish there (HW). A looping
    // menu with a >1 s fly-in would highlight mid-animation; none observed (T2's
    // long fly-ins PARK and ride settle).
    parameter [26:0] PROMOTE_FALLBACK = 27'd27_000_000
) (
    input  wire        clk,           // clk_sys
    input  wire        rst_n,         // pipe_rst_n: a load/seek/jump clears nav state

    // PCI byte stream from ps_demux
    input  wire  [7:0] pci_byte,
    input  wire        pci_valid,
    input  wire        pci_frame_start,

    // presentation clock (av_sync STC, 90 kHz)
    input  wire [32:0] stc,

    // display-mode verdict for button-group selection (the PR #115 subpicture
    // signals, quasi-static): disp_wide = the content is 16:9 (emu
    // ar_wide_auto_eff — menu V_ATR while a menu is active, stream aspect in
    // titles); disp_mode = 16:9 presentation 0=wide 1=letterbox 2=pan&scan
    // (emu sp_disp_mode: Force-4:3-Subpics -> letterbox, O[4:3] analog
    // Letterbox/Crop -> letterbox/pan&scan, else wide).
    input  wire        disp_wide,
    input  wire  [1:0] disp_mode,

    // display is showing decoded video (av_sync video_live, clk_sys). Used as
    // the FALLBACK promotion trigger: after a keep_vbuf menu->menu transition the
    // STC (anchored on the demux parse-front, not the screen) can sit permanently
    // off the new menu's hli_s_ptm, so the STC compare below never fires and the
    // highlight never arms (HW: Mission Profiles / scene menus - no highlight).
    // If a pending ARM has waited > PROMOTE_FALLBACK with video live, promote it
    // anyway so the highlight ALWAYS appears. The STC path is kept for the
    // correctly-timed case (Matrix finite windows).
    input  wire        video_live,

    // MENU SETTLED (2026-08-05, highlight-early polish): the reader is parked on
    // the menu's still cell (S_STILL — the §5 still-park + cold-re-decode moment,
    // i.e. "the transition finished; the settled menu is what's on screen").
    // Promotes a waiting armed HLI IMMEDIATELY: later than the old ~1 s timer on
    // long fly-ins (no more highlight-over-the-animation) and FASTER on short
    // ones. Also covers in-title timed-still choices (Thayer: buttons at the
    // hold). Looping motion menus never park -> the PROMOTE_FALLBACK timer above
    // remains their safety net.
    input  wire        menu_settled,

    // STC FRESH (2026-08-05 round 2, the residual earliness): 1 = the load that
    // last reset this module FLUSHED the pipeline (keep_vbuf=0), so the STC
    // anchor and the display reset together — the clock is display-coherent and
    // scheduled crossings are meaningful. 0 = a keep_vbuf menu->menu hop:
    // load_flush re-anchored the STC on the NEW cell's parse-front PTS while
    // the display still plays the old tail, so the clock leads the screen by
    // the buffered depth and every window compare fires early. In that case
    // the scheduled path stays blocked until the display provably catches up
    // (settled_seen: a still park since the load) — promotion until then is
    // settle/timer only.
    input  wire        stc_fresh,

    // gamepad (1-cycle pulses from emu edge detect)
    // Phase-4 VM selection force (SetHL_BTNN / link button fields): sets the
    // selection like a D-pad landing would. Out-of-range against an armed
    // HLI = ignored; with no HLI armed the value is stored so the next arm's
    // persistence rule keeps it (discs SetHL_BTNN in pre-commands so the
    // remembered button is selected when the menu re-arms).
    input  wire        sel_force,
    input  wire  [5:0] sel_force_btn,

    // NUMPAD select+activate (keyboard digit key = DVD-remote number shortcut):
    // a 1-cycle pulse forces the selection to `num_btn` (1-based) AND activates it
    // once the button record is fetched, so the fired btn_cmd is the freshly-loaded
    // command (no race with the fetch pipeline). Out-of-range / no-HLI = ignored.
    // btn_sel is set before the activate, so dvd_vm's sprm8_eff shadows the right
    // button. See emu.sv "NUMPAD MENU INPUT" and docs/dvd_nav.md "Numpad input".
    input  wire        num_sel,
    input  wire  [5:0] num_btn,

    input  wire        nav_up,
    input  wire        nav_dn,
    input  wire        nav_lf,
    input  wire        nav_rt,
    input  wire        nav_act,

    // renderer interface - ALL REGISTERS (hotspot-safe)
    output reg         hl_on,         // highlight active (draw the rect)
    output reg   [9:0] hl_x1,
    output reg   [9:0] hl_x2,
    output reg   [9:0] hl_y1,
    output reg   [9:0] hl_y2,
    output reg  [31:0] hl_coli,       // active colour word (ACT during the flash)

    // activation -> emu micro-bridge
    output reg  [63:0] btn_cmd,       // selected button's 8-byte VM command
    output reg         btn_cmd_valid, // pulse: activated (execute/flash)

    // DVD-FORK DEBUG (2026-08-05, branch highlight-early regression): WHICH path
    // promoted the last armed HLI + how long it had waited. The cap/settle fixes
    // changed nothing on HW, so promotion must flow through a path other than
    // the fallback — this names it. {promo_cnt[3:0] (wrapping, one per arm
    // promotion), src[1:0] (1=STC-scheduled, 2=menu-settled, 3=timer),
    // pend_age_at_promo[26:17] (~4.85 ms units: 2^17 clk_sys)}.
    output reg  [15:0] dbg_promo,

    // state read-backs
    output wire        btns_armed,    // an HLI with buttons is committed
    output reg   [5:0] btn_sel,       // current button (1-based)
    output wire  [5:0] dbg_btn_ns,
    // EARLY "a multi-button in-title menu HLI has been parsed" — asserts as soon
    // as the PCI (NAV pack) is parsed, i.e. BEFORE the promotion the display path
    // waits on, and stays through commit. emu uses this to open the subpicture
    // gate / force stream 0 in time: an in-title menu's highlight subpicture rides
    // substream 0x20 and arrives a few sectors AFTER the NAV pack in the SAME VOBU,
    // so a gate that waited on the promoted `btns_armed` would miss it (unlike a
    // menu-domain menu whose gate follows menu_active, or the white rabbit whose
    // SetSTN opens the gate in the PGC pre-command). The PCI byte path into nav_pci
    // is not itself subpicture-gated, so this is available regardless.
    output wire        hli_seen
);

// =========================================================================
// HLI store: 4 banks x 1024 B, sync read. Fill writes PCI bytes 0x60..0x315
// (694 B) at bank offset 0..693; fill_bank rotates avoiding the display and
// pending banks.
// =========================================================================
reg [7:0]  hbuf [0:4095];
reg [1:0]  fill_bank;
reg [1:0]  disp_bank;
reg [11:0] h_raddr;
reg [7:0]  h_rdata;
always @(posedge clk) h_rdata <= hbuf[h_raddr];

// ---- fill: byte index within the PCI packet + field capture ----
reg [9:0]  fidx;               // current PCI byte index (0..979)
wire [9:0] cur = pci_frame_start ? 10'd0 : fidx;
reg [23:0] facc;               // rolling accumulator (BE u32 assembly)
reg [1:0]  f_ss;
reg [31:0] f_vptm;             // pci_gi.vobu_s_ptm (schedules ss=0 disarms)
reg [31:0] f_sptm, f_eptm;
reg [5:0]  f_btn_ns, f_fosl, f_foac;
reg [1:0]  f_grns;             // hl_gi.btngr_ns (1..3; 0 treated as 1)
reg [2:0]  f_g1ty, f_g2ty, f_g3ty;   // btngrX_dsp_ty (bit0 wide, bit1 LB, bit2 P&S)

// PENDING slots, waiting for the STC to reach their windows. ARM (ss=1/2/3)
// and DISARM (ss=0) are held SEPARATELY (a cell-boundary ss=0 must not fight
// the following re-arm). CRITICAL park policy (HW round 3, the Matrix
// 'dark with blips' pattern): keep the EARLIEST-s_ptm pending, not the
// newest - the stream front leads the screen by seconds, so newest-wins let
// every VOBU overwrite the pending with a LATER start time before it came
// due: promotion only fired when the stream STALLED (the observed blip
// cadence). Earliest-wins promotes on the display schedule; later identical
// commits simply re-park after each promote. A commit whose s_ptm is >0.7 s
// BELOW the pending's is a TIMELINE RESTART (the menu cell-loop's backward
// PTS jump): it replaces the pending and clears a stale disarm.
reg        nxt_v;
reg [1:0]  nxt_bank;
reg [1:0]  nxt_ss;
reg [31:0] nxt_sptm;
reg        nxt_pre;       // commit happened before its s_ptm (crossing-only schedule gate)
reg [5:0]  nxt_btn_ns, nxt_fosl, nxt_foac;
reg        nxt_forever;         // pending arm authored hli_e_ptm == 0xFFFFFFFF (never auto-disarm)
reg [1:0]  nxt_grns;
reg [2:0]  nxt_g1ty, nxt_g2ty, nxt_g3ty;
reg        off_v;              // pending disarm
reg [31:0] off_sptm;
reg [26:0] pend_age;           // cycles the current ARM pending has waited (video live)

always @(posedge clk)
    if (pci_valid && cur >= 10'h060 && cur <= 10'h315)
        hbuf[{fill_bank, cur - 10'h060}] <= pci_byte;

// next fill bank: rotate, skipping the display and pending banks
function [1:0] next_bank(input [1:0] b, input [1:0] d, input [1:0] n);
    reg [1:0] c;
    begin
        c = b + 2'd1;
        if (c == d || c == n) c = c + 2'd1;
        if (c == d || c == n) c = c + 2'd1;
        next_bank = c;
    end
endfunction

// =========================================================================
// Committed (display) HLI state
// =========================================================================
reg        armed;
reg [31:0] h_sptm;
reg [5:0]  h_btn_ns, h_foac;
reg [1:0]  h_grns;             // committed btngr_ns + per-group display types
reg [2:0]  h_g1ty, h_g2ty, h_g3ty;
// A committed HLI authored with hli_e_ptm == 0xFFFFFFFF ("forever" - buttons persist
// until a jump/seek). Such a highlight must NOT be torn down by a scheduled ss=0
// disarm: menus reached after a preceding animation/transition cell park the front's
// trailing ss=0 (highlight-off) as a pending disarm on the OLD cell's presentation
// timeline; once we settle on the (indefinite-still) menu the STC keeps advancing and
// would eventually cross that stale off time and kill a highlight the disc authored to
// hold forever (T2 boot "theatrical/special" selector - the highlight vanished ~10 s in,
// then Select mis-routed to resume). Gating off_due on this preserves the forever HLI.
reg        h_forever;

// fetch FSM: pulls the selected button's 18-byte record + its colour group's
// {sel, act} words out of the display bank into registers.
localparam F_IDLE = 3'd0, F_BTN_A = 3'd1, F_BTN_D = 3'd2,
           F_COL_A = 3'd3, F_COL_D = 3'd4, F_DONE = 3'd5;
reg [2:0]  fstate;
reg [4:0]  f_i;                // byte counter within the fetch
reg [1:0]  b_coln;             // selected button's colour number (1..3)
reg [1:0]  b_auto;             // auto_action_mode
reg [5:0]  b_up, b_dn, b_lf, b_rt;
reg [31:0] coli_sel, coli_act;
reg [55:0] bsh;                // record assembly shift (cmd needs 7 bytes + current)
reg        fetched;            // rect/links/cmd/coli regs are valid
reg        fetch_req;          // (re)fetch the current button
reg        auto_pend;          // numpad select+activate: fire once the fetch completes
reg        moved;              // selection changed via nav (auto_action trigger)

// activation flash: show the ACT colour word for ~0.6 s
reg [23:0] act_tmr;
wire       act_hold = (act_tmr != 24'd0);

assign btns_armed = armed && (h_btn_ns != 6'd0);
assign dbg_btn_ns = h_btn_ns;
// early multi-button-menu detect: pending (parsed, pre-promote) OR committed.
assign hli_seen   = (nxt_v && (nxt_btn_ns > 6'd1)) || (armed && (h_btn_ns > 6'd1));

// pending slots due? (32-bit 90 kHz compare). Promotion is STRICTLY at
// s_ptm - no apply-immediately-when-disarmed shortcut: at a menu (re)entry
// the STC anchors on the first video PTS ~= the first NAV's s_ptm, so the
// highlight appears WITH the video instead of floating over the old frame
// during the load (MiB HW round 2). A disarm due at/before an arm applies
// first (the authored gap).
// SIGNED distance dues (robust across the loop's backward STC re-anchor)
wire signed [31:0] nxt_dist = stc[31:0] - nxt_sptm;
wire signed [31:0] off_dist = stc[31:0] - off_sptm;
// STC-scheduled promotion (normal case: STC has reached hli_s_ptm). Two gates:
//  - nxt_pre: the commit happened BEFORE the window start (only real crossings
//    schedule; an already-due-at-arm compare carries no timing information);
//  - clock trust: the STC is display-coherent — the load flushed (stc_fresh)
//    or a still park has proven the display caught up (settled_seen). After a
//    keep_vbuf hop the parse-anchored clock leads the screen, and per-VOBU
//    re-commits straddle it, minting fake "crossings" early by the display lag
//    (row-26 probe: src=sched age~0 through every transition).
reg settled_seen;
always @(posedge clk)
    if (!rst_n)            settled_seen <= 1'b0;
    else if (menu_settled) settled_seen <= 1'b1;
wire stc_trusted = stc_fresh || settled_seen;
wire nxt_sched = nxt_v && nxt_pre && !nxt_dist[31] && stc_trusted;
// FALLBACK promotion: an armed pending that has waited > PROMOTE_FALLBACK with
// video live but the STC never became due (keep_vbuf STC/parse-front skew).
// Only for a real ARM (buttons present) so an ss=0-style empty pending doesn't
// spuriously "promote". Disarm (off_due) still wins below.
wire nxt_fallback = nxt_v && (nxt_btn_ns != 6'd0) && video_live &&
                    (menu_settled || (pend_age >= PROMOTE_FALLBACK));
wire nxt_due = nxt_sched || nxt_fallback;
// A forever-armed HLI (h_forever) is immune to a scheduled disarm - a stale ss=0 from a
// preceding animation cell must not kill it (see h_forever). Only blocks the tear-down of
// an ALREADY-armed forever highlight; a disarm arriving before any arm (armed==0) still
// clears the pending slot as before.
// DISARM also requires the TRUSTED clock (2026-08-05 round 3): on an untrusted
// (keep_vbuf-hop) timeline the per-VOBU ss=0 disarms are perpetually "due"
// (STC past their off_sptm), and because off_due OUTRANKS nxt_due in the apply
// block, they cleared arms and starved pending promotions for tens of seconds
// (MiB return-to-main: timer due at 2.5 s, applied at ~40 s — row-26 probe).
// A disarm scheduled against a meaningless clock is itself meaningless; it
// waits (new arms simply overwrite) until the clock is trusted again.
wire off_due = off_v && !off_dist[31] && stc_trusted &&
               (!nxt_due || $signed(off_sptm - nxt_sptm) <= 0) &&
               !(armed && h_forever);
// timeline restart: a new arm >0.7 s (63000 ticks) behind the parked one
wire arm_restart = nxt_v && $signed(f_sptm - nxt_sptm) < -32'sd63000;

// ---- button-group choice by display mode ------------------------------------
// wanted display type: 4:3 content wants a plain-4:3 group (dsp_ty == 000);
// 16:9 content wants the group whose dsp_ty bit matches the presentation.
wire [2:0] want_ty = !disp_wide          ? 3'b000 :
                     (disp_mode == 2'd1) ? 3'b010 :   // letterbox
                     (disp_mode == 2'd2) ? 3'b100 :   // pan&scan
                                           3'b001;    // wide
wire g1_hit = (want_ty == 3'b000) ? (h_g1ty == 3'b000) : |(h_g1ty & want_ty);
wire g2_hit = (want_ty == 3'b000) ? (h_g2ty == 3'b000) : |(h_g2ty & want_ty);
wire g3_hit = (want_ty == 3'b000) ? (h_g3ty == 3'b000) : |(h_g3ty & want_ty);
wire [1:0] grns_eff = (h_grns == 2'd0) ? 2'd1 : h_grns;   // 0 is illegal: treat as 1
// first matching group wins; group 1 is the universal fallback (= v1 behaviour)
wire [1:0] want_grp = g1_hit                          ? 2'd0 :
                      (grns_eff >= 2'd2 && g2_hit)    ? 2'd1 :
                      (grns_eff == 2'd3 && g3_hit)    ? 2'd2 : 2'd0;
// group base: 36/btngr_ns records of 18 B each (2 groups: 18*18=324; 3: 12*18=216)
wire [10:0] grp_off = (want_grp == 2'd0) ? 11'd0   :
                      (grns_eff == 2'd2) ? 11'd324 :            // group 2 of 2
                      (want_grp == 2'd1) ? 11'd216 : 11'd432;   // groups 2/3 of 3
// selected button record base within the bank: 0x2E + group base + (btn_sel-1)*18
wire [10:0] btn_base = 11'h02E + grp_off + ({5'd0, btn_sel} - 11'd1) * 11'd18;
reg  [1:0]  grp_q;             // group the fetched registers came from
// colour group base: 0x16 + (coln-1)*8  (coln 0 is treated as 1 - some discs
// author coln=0 on buttons and players use group 1)
wire [10:0] col_base = 11'h016 +
                       {9'd0, (b_coln == 2'd0 ? 2'd0 : b_coln - 2'd1), 3'b000};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fidx      <= 10'd0;
        facc      <= 24'd0;
        f_ss      <= 2'd0;
        f_vptm    <= 32'd0;
        fill_bank <= 2'd0;
        disp_bank <= 2'd3;
        nxt_v     <= 1'b0;
        nxt_pre   <= 1'b0;
        nxt_bank  <= 2'd2;
        nxt_ss    <= 2'd0;
        nxt_sptm  <= 32'd0;
        nxt_btn_ns<= 6'd0;
        nxt_fosl  <= 6'd0;
        nxt_foac  <= 6'd0;
        nxt_forever<= 1'b0;
        off_v     <= 1'b0;
        off_sptm  <= 32'd0;
        pend_age  <= 27'd0;
        armed     <= 1'b0;
        h_btn_ns  <= 6'd0;
        h_foac    <= 6'd0;
        h_sptm    <= 32'd0;
        h_forever <= 1'b0;
        btn_sel   <= 6'd1;
        fstate    <= F_IDLE;
        fetched   <= 1'b0;
        fetch_req <= 1'b0;
        auto_pend <= 1'b0;
        moved     <= 1'b0;
        hl_on     <= 1'b0;
        hl_x1 <= 10'd0; hl_x2 <= 10'd0; hl_y1 <= 10'd0; hl_y2 <= 10'd0;
        hl_coli   <= 32'd0;
        btn_cmd   <= 64'd0;
        btn_cmd_valid <= 1'b0;
        act_tmr   <= 24'd0;
        h_raddr   <= 12'd0;
        f_i       <= 5'd0;
        b_coln    <= 2'd0;
        b_auto    <= 2'd0;
        b_up <= 6'd0; b_dn <= 6'd0; b_lf <= 6'd0; b_rt <= 6'd0;
        coli_sel  <= 32'd0;
        coli_act  <= 32'd0;
        bsh       <= 56'd0;
        f_sptm    <= 32'd0;
        f_eptm    <= 32'd0;
        f_btn_ns  <= 6'd0;
        f_fosl    <= 6'd0;
        f_foac    <= 6'd0;
        f_grns    <= 2'd0;
        f_g1ty    <= 3'd0; f_g2ty <= 3'd0; f_g3ty <= 3'd0;
        nxt_grns  <= 2'd0;
        nxt_g1ty  <= 3'd0; nxt_g2ty <= 3'd0; nxt_g3ty <= 3'd0;
        h_grns    <= 2'd0;
        h_g1ty    <= 3'd0; h_g2ty <= 3'd0; h_g3ty <= 3'd0;
        grp_q     <= 2'd0;
    end else begin
        btn_cmd_valid <= 1'b0;                 // default: one-cycle pulse
        if (act_tmr != 24'd0) act_tmr <= act_tmr - 24'd1;

        // Age the pending ARM while it waits with video live (fallback timer).
        // Frozen if no pending, if the STC path is already due, or video dead.
        if (nxt_v && nxt_btn_ns != 6'd0 && video_live && !nxt_sched) begin
            if (pend_age != 27'h7FFFFFF) pend_age <= pend_age + 27'd1;
        end else
            pend_age <= 27'd0;

        // ------------------------------------------------------------
        // FILL: capture header fields + store the HLI window. Commit at
        // the last HLI byte (0x315).
        // ------------------------------------------------------------
        if (pci_valid) begin
            fidx <= cur + 10'd1;
            facc <= {facc[15:0], pci_byte};
            case (cur)
            10'h00F: f_vptm   <= {facc, pci_byte};   // pci_gi.vobu_s_ptm
            10'h061: f_ss     <= pci_byte[1:0];      // hli_ss (low 2 of u16)
            10'h065: f_sptm   <= {facc, pci_byte};   // hli_s_ptm
            10'h069: f_eptm   <= {facc, pci_byte};   // hli_e_ptm
            10'h06E: begin                           // btn_md hi: btngr_ns + gr1_dsp_ty
                f_grns <= pci_byte[5:4];
                f_g1ty <= pci_byte[2:0];
            end
            10'h06F: begin                           // btn_md lo: gr2/gr3 dsp_ty
                f_g2ty <= pci_byte[6:4];
                f_g3ty <= pci_byte[2:0];
            end
            10'h071: f_btn_ns <= pci_byte[5:0];
            10'h074: f_fosl   <= pci_byte[5:0];
            10'h075: f_foac   <= pci_byte[5:0];
            10'h315: begin
                // COMMIT into the matching PENDING slot (promotion below
                // applies it at its presentation time). Newer commits of the
                // same kind overwrite an unpromoted older one.
                if (f_ss == 2'd0) begin
                    // DISARM: keep the earliest scheduled one
                    if (!off_v || $signed(f_vptm - off_sptm) < 0) begin
                        off_v    <= 1'b1;
                        off_sptm <= f_vptm;
                    end
                end else if (!nxt_v || arm_restart ||
                             $signed(f_sptm - nxt_sptm) < 0) begin
                    // ARM: park if the slot is free, this one is EARLIER, or
                    // the timeline restarted (menu loop) - else discard (the
                    // parked earlier one promotes first; identical content
                    // re-parks after each promote anyway)
                    nxt_v     <= 1'b1;
                    // CROSSING-ONLY SCHEDULE (2026-08-05, the highlight-early
                    // branch regression — row-26 probe: EVERY promotion was
                    // src=sched with age 0, i.e. stc >= s_ptm ALREADY AT ARM).
                    // A compare that is already true when the HLI commits is a
                    // stale/foreign-timeline artifact (the parse-anchored STC
                    // lands at/past the cell's own start ptm), not an authored
                    // schedule — promoting on it paints the highlight over the
                    // still-playing transition. Only a GENUINE crossing (commit
                    // with stc < s_ptm, then the STC reaches it — the Matrix
                    // finite-window case) may use the scheduled path; an
                    // already-due commit waits for menu_settled / the timer.
                    nxt_pre   <= $signed(stc[31:0] - f_sptm) < 0;
                    nxt_bank  <= fill_bank;
                    nxt_ss    <= f_ss;
                    nxt_sptm  <= f_sptm;
                    nxt_btn_ns<= f_btn_ns;
                    nxt_fosl  <= f_fosl;
                    nxt_foac  <= (f_ss == 2'd1) ? f_foac : 6'd0;
                    nxt_forever<= (f_eptm == 32'hFFFF_FFFF);
                    nxt_grns  <= f_grns;
                    nxt_g1ty  <= f_g1ty;
                    nxt_g2ty  <= f_g2ty;
                    nxt_g3ty  <= f_g3ty;
                    fill_bank <= next_bank(fill_bank, disp_bank, fill_bank);
                    if (arm_restart) off_v <= 1'b0;   // stale old-pass disarm
                end
            end
            default: ;
            endcase
        end

        // ------------------------------------------------------------
        // PROMOTE the pending HLI when the presentation clock reaches it.
        // Selection PERSISTS (SPRM8 semantics): reset only when invalid
        // for the new HLI, or a forced-select (fosl) demands a button.
        // ------------------------------------------------------------
        if (off_due) begin
            off_v   <= 1'b0;
            armed   <= 1'b0;
            fetched <= 1'b0;
            h_forever <= 1'b0;
        end else if (nxt_due) begin
            nxt_v <= 1'b0;
            if (nxt_btn_ns == 6'd0) begin
                armed   <= 1'b0;
                fetched <= 1'b0;
                h_forever <= 1'b0;
            end else begin
                // promotion-source probe (see dbg_promo port comment)
                dbg_promo <= {dbg_promo[15:12] + 4'd1,
                              (nxt_sched ? 2'd1 : (menu_settled ? 2'd2 : 2'd3)),
                              pend_age[26:17]};
                disp_bank <= nxt_bank;
                armed     <= 1'b1;
                h_sptm    <= nxt_sptm;
                h_btn_ns  <= nxt_btn_ns;
                h_foac    <= nxt_foac;
                h_forever <= nxt_forever;
                h_grns    <= nxt_grns;
                h_g1ty    <= nxt_g1ty;
                h_g2ty    <= nxt_g2ty;
                h_g3ty    <= nxt_g3ty;
                if (nxt_fosl != 6'd0 && nxt_fosl <= nxt_btn_ns && !armed)
                    btn_sel <= nxt_fosl;             // forced select on (re)arm
                else if (btn_sel == 6'd0 || btn_sel > nxt_btn_ns)
                    btn_sel <= 6'd1;
                fetch_req <= 1'b1;
                fetched   <= 1'b0;
            end
        end

        // ------------------------------------------------------------
        // NAV / ACTIVATE (only with a fetched button under an armed HLI)
        // ------------------------------------------------------------
        if (btns_armed && fetched) begin
            if (nav_up || nav_dn || nav_lf || nav_rt) begin
                // link 0 = stay; out-of-range links clamp to stay
                if (nav_up && b_up != 6'd0 && b_up <= h_btn_ns && b_up != btn_sel) begin
                    btn_sel <= b_up; fetch_req <= 1'b1; fetched <= 1'b0; moved <= 1'b1;
                end
                if (nav_dn && b_dn != 6'd0 && b_dn <= h_btn_ns && b_dn != btn_sel) begin
                    btn_sel <= b_dn; fetch_req <= 1'b1; fetched <= 1'b0; moved <= 1'b1;
                end
                if (nav_lf && b_lf != 6'd0 && b_lf <= h_btn_ns && b_lf != btn_sel) begin
                    btn_sel <= b_lf; fetch_req <= 1'b1; fetched <= 1'b0; moved <= 1'b1;
                end
                if (nav_rt && b_rt != 6'd0 && b_rt <= h_btn_ns && b_rt != btn_sel) begin
                    btn_sel <= b_rt; fetch_req <= 1'b1; fetched <= 1'b0; moved <= 1'b1;
                end
            end
            if (nav_act) begin
                btn_cmd_valid <= 1'b1;
                act_tmr       <= 24'hFFFFFF;       // ~0.62 s ACT-colour flash
            end
        end

        // VM selection force (after the nav block: the VM's write wins a
        // same-cycle race, matching SPRM8-is-authoritative semantics)
        if (sel_force && sel_force_btn != 6'd0) begin
            if (!armed) begin
                btn_sel <= sel_force_btn;          // stored for the next arm
            end else if (sel_force_btn <= h_btn_ns) begin
                btn_sel   <= sel_force_btn;
                fetch_req <= 1'b1;
                fetched   <= 1'b0;
            end
        end

        // NUMPAD select+activate (keyboard digit key). Force the selection to the
        // typed button and mark it for activation once the fetch completes (auto_pend
        // fires btn_cmd_valid in F_DONE with the freshly-loaded command). Only inside
        // an armed HLI and in range; a no-op otherwise. Setting btn_sel here also
        // updates dvd_vm's sprm8_eff (btns_armed shadow) so the command sees SPRM8=N.
        if (num_sel && armed && num_btn != 6'd0 && num_btn <= h_btn_ns) begin
            btn_sel   <= num_btn;
            fetch_req <= 1'b1;
            fetched   <= 1'b0;
            auto_pend <= 1'b1;
        end

        // ------------------------------------------------------------
        // FETCH: 18-byte button record, then the colour group's 8 bytes
        // (sync-read BRAM: address one cycle ahead of data).
        // ------------------------------------------------------------
        case (fstate)
        F_IDLE: if (fetch_req && armed) begin
            fetch_req <= 1'b0;
            f_i       <= 5'd0;
            grp_q     <= want_grp;            // record which group this fetch reads
            h_raddr   <= {disp_bank, 10'd0} + {1'b0, btn_base};
            fstate    <= F_BTN_A;
        end
        F_BTN_A: begin                          // h_rdata lags h_raddr by 1
            h_raddr <= h_raddr + 12'd1;
            fstate  <= F_BTN_D;
        end
        F_BTN_D: begin
            // consume byte f_i of the button record
            bsh <= {bsh[47:0], h_rdata};
            case (f_i)
            5'd2: begin                          // b0-2: coln + x1 + x2
                b_coln <= bsh[15:14];
                hl_x1  <= bsh[13:4];
                hl_x2  <= {bsh[1:0], h_rdata};
            end
            5'd5: begin                          // b3-5: auto + y1 + y2
                b_auto <= bsh[15:14];
                hl_y1  <= bsh[13:4];
                hl_y2  <= {bsh[1:0], h_rdata};
            end
            5'd6: b_up <= h_rdata[5:0];
            5'd7: b_dn <= h_rdata[5:0];
            5'd8: b_lf <= h_rdata[5:0];
            5'd9: b_rt <= h_rdata[5:0];
            5'd17: btn_cmd <= {bsh[55:0], h_rdata};
            default: ;
            endcase
            if (f_i == 5'd17) begin
                f_i     <= 5'd0;
                h_raddr <= {disp_bank, 10'd0} + {1'b0, col_base};
                fstate  <= F_COL_A;
            end else begin
                f_i     <= f_i + 5'd1;
                h_raddr <= h_raddr + 12'd1;
                // stay in F_BTN_D (address already advanced in F_BTN_A/here)
            end
        end
        F_COL_A: begin
            h_raddr <= h_raddr + 12'd1;
            fstate  <= F_COL_D;
        end
        F_COL_D: begin
            bsh <= {bsh[47:0], h_rdata};
            if (f_i == 5'd3) coli_sel <= {bsh[23:0], h_rdata};
            if (f_i == 5'd7) coli_act <= {bsh[23:0], h_rdata};
            if (f_i == 5'd7) begin
                fetched <= 1'b1;
                fstate  <= F_DONE;
            end else begin
                f_i     <= f_i + 5'd1;
                h_raddr <= h_raddr + 12'd1;
            end
        end
        F_DONE: begin
            // Activate the freshly-fetched button when: a numpad digit forced it
            // (auto_pend); an auto_action button was ARRIVED at via nav (moved); or
            // a forced-activate (foac) button was just committed. btn_cmd now holds
            // this button's command, so the fired activation is race-free.
            if (auto_pend ||
                (b_auto == 2'd1 && moved) ||
                (h_foac != 6'd0 && h_foac == btn_sel)) begin
                btn_cmd_valid <= 1'b1;
                act_tmr       <= 24'hFFFFFF;
                h_foac        <= 6'd0;
            end
            auto_pend <= 1'b0;
            moved     <= 1'b0;
            fstate    <= F_IDLE;
        end
        default: fstate <= F_IDLE;
        endcase

        // foac points elsewhere: hop the selection there once
        if (fstate == F_IDLE && !fetch_req && armed &&
            h_foac != 6'd0 && h_foac <= h_btn_ns && h_foac != btn_sel) begin
            btn_sel   <= h_foac;
            fetch_req <= 1'b1;
            fetched   <= 1'b0;
        end

        // display mode changed while armed (OSD aspect toggle / menu V_ATR
        // update landing after the arm): the fetched rect belongs to the old
        // group — refetch the same button from the newly-wanted group.
        if (fstate == F_IDLE && !fetch_req && armed && fetched &&
            want_grp != grp_q) begin
            fetch_req <= 1'b1;
            fetched   <= 1'b0;
        end

        // ------------------------------------------------------------
        // Renderer registers
        // ------------------------------------------------------------
        hl_on   <= btns_armed && fetched;
        hl_coli <= act_hold ? coli_act : coli_sel;
    end
end

endmodule
