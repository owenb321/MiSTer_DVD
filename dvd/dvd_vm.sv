// dvd_vm.sv - DVD Virtual Machine interpreter (Phase 4 disc menus).
//
// Executes the disc's navigation commands (8-byte VM instructions from the
// PGC command tables) so authored menus actually WORK: First Play boot, menu
// button dispatch (SetGPRM + Jump/Link chains, the MiB "trampoline"), PGC
// pre/post/cell commands, CallSS/RSM resume, and SetSTN audio/subpicture
// stream selection.
//
// SEMANTICS are a faithful port of libdvdnav src/vm/decoder.c eval_command
// (compare ops incl. op1 = bitwise AND; add/mul clamp to 0xFFFF, sub clamps
// to 0, div/mod by zero => 0xFFFF; Goto/Break 1-based line flow; the exact
// per-type cond/set/link ordering) with ONE deviation: command types 5/6 use
// the vmcmd.c bit layout (if_version_5 / set_version_3) - decoder.c marks
// its own type-5/6 handling "FIXME wrong", and our on-disc-validated
// decode_vmcmd agrees with vmcmd.c. Link/jump DISPATCH mirrors vm.c
// process_command / play.c at this core's granularity: cell-granular RSM,
// PTT ~= program until the Phase-6 VTS_PTT_SRPT map, no angle blocks. GPRM
// counter mode NOW ticks (the DVD-game entropy path, see "DVD-game entropy"
// below); NVTMR (SPRM9) stored but never fires (libdvdnav doesn't fire it).
// The golden model is tools/dvd_vm_ref.py; bench/dvd/dvd_vm_tb.sv checks
// this RTL against its emitted vectors bit-exactly (including the rnd LFSR).
//
// PLACEMENT: clk_sys nav plane (reader/demux domain), reset by reset_n - VM
// state (GPRMs, RSM, SPRMs) survives seeks and jumps (the pgc-palette
// seek-reset lesson); a fresh mount (start) runs vm_reset.
//
// EXECUTION TRIGGERS (events, serviced one at a time from V_IDLE):
//   nav_ready rise  -> jump FP, run its PRE  (boot; fallback = auto title)
//   pgc_loaded      -> run PRE   (skipped on RSM resume)
//   vm_pgc_end      -> run POST  (reader waits, drained, in S_VM_WAIT)
//   vm_cell_cmd     -> run that one cell command (reader waits)
//   btn_cmd_valid   -> run the button's command (from nav_pci)
//   key_menu        -> title: synthesized CallSS VTSM Root; menu: LinkRSM
//   (Select with no buttons armed is a STRICT NO-OP - see the ev_menu handler)
//   key_title       -> VMGM Title menu (entry 2), the real-remote TITLE key;
//                      from a title also saves RSM (Menu/Select toggle back)
//   key_cmenu       -> VTSM Chapter/PTT menu (entry 7), the remote's scene-
//                      selection key. Measured on 956 library discs: 401 (42%)
//                      author one, so the no-menu path is the COMMON case and
//                      must be a clean no-op, not a failed jump.
//   key_return      -> GoUp: in-domain jump to the loaded PGC's authored
//                      goup_pgcn (libdvdnav dvdnav_go_up); goup==0 = no-op
//   key_chedge      -> a chapter skip hit the TITLE's edge (the reader decides;
//                      audit item 7). Next: run this PGC's POST as a USER chain
//                      (nat_src=0, so its jump is immediate) and on a fall-
//                      through follow next_pgcn (libdvdnav vm_jump_next_pg);
//                      Prev: prev_pgcn at its LAST program (vm_jump_prev_pg).
//                      A chain that ends without a jump is a strict no-op:
//                      playback continues (dvdnav_next_pg_search treats a
//                      stopped VM as failure), so its vm_adv is masked.
//   pgc_error       -> fallback chain (own VTSM -> best-menu-VOB VTSM ->
//                      VMGM Title -> resume/auto title), ported from the
//                      Phase-2/3 emu glue this module replaces.
//
// Every reader-wait event (vm_cell_cmd / vm_pgc_end) is ALWAYS answered with
// exactly one of: vm_adv (continue authored behaviour), vm_replay (replay
// the current cell, no flush - menu loops), seek_pulse, or jump_pulse.
//
// See docs/dvd_vm.md for the full design + frozen decode tables.
//
// ★ IMPLEMENTATION (2026-10-07, docs/nav_engine.md): MICROCODE. This module is a
// thin hardwired wrapper around nav_seq (below), a small sequencer whose program
// dvd/nav/vm.uasm is the VM: command fetch and decode, compare/set/link/jump, the
// fallback chain, RSM, the counter tick. The wrapper keeps everything real-time --
// event latches and their priority, the wait timer, the output pulses and fields,
// the SPRM8/SPRM3 shadows, pre_done, the LFSR -- and every port is unchanged.
// It replaced the hardwired FSM, which is kept unchanged as the A/B oracle
// (bench/dvd/ref/dvd_vm_hw.sv; tools/vm_ab.py matches the two transaction for
// transaction). A navigation change is now a microcode change: edit vm.uasm, run
// `tools/nav_isa.py --asm`, and the A/B, the Python emulator and the benches tell
// you what moved. The program ROM loads from dvd/nav/nav_ucode.mem by repo-relative
// path; the GENERATED blocks below are stamped by the same tool and checked by
// `--asm --check` (an `include would need -I in every runner).

module dvd_vm (
    input             clk,            // clk_sys
    input             rst_n,          // reset_n (NOT pipe_rst_n - state survives seeks)
    input             enable,         // O[1] Disc Menus (level); 0 = fully inert
    input             start,          // mount pulse: vm_reset
    // Player language (OSD "Player Language" ISO-639 code, default 'en'):
    // read back as SPRM0 (menu language) and SPRM16/18 (audio/subtitle
    // preference) - one setting drives all three, like a set-top player's
    // language menu. Discs read these in nav commands to pick their LU /
    // auto-select streams.
    input      [15:0] cfg_lang,
    // Player parameters a disc can read (feature/player-regs; computed by
    // dvd/player_regs.sv in emu from the output settings and the disc's region mask;
    // docs/dvd_vm.md "Player parameters SPRM14/15/20"). They were libdvdnav's
    // constants 0x0100 / 0x7CFC / 0x0001 -- benches tie them to exactly those.
    input      [15:0] cfg_sprm14,     // video preference: display aspect + 4:3 mode
    input      [15:0] cfg_sprm15,     // audio capabilities
    input      [15:0] cfg_sprm20,     // player region (one-hot): a region the disc allows
    input             nav_ready,      // reader: VIDEO_TS walk finished (level)
    input      [7:0]  auto_vts,       // reader: Auto title pick (largest VTS / OSD)
    input      [7:0]  best_menu_vts,  // reader: VTS with the largest menu VOB
    input      [6:0]  res_ttn,        // reader: resolved vts_ttn (JumpTT -> SPRM5)

    // DVD-game entropy (the only entropy on a DVD player is wall-clock time,
    // like libdvdnav's srand(usec) + wall-clock GPRM counters). Scene It and
    // other game discs harvest it for question randomization: the rnd LFSR is
    // seeded from rnd_seed at mount and stirred by user-input timing, and
    // counter-mode GPRMs accumulate real seconds via sec_tick. Without these
    // the VM is fully deterministic -> identical gameplay every play. See
    // docs/dvd_vm.md "DVD-game entropy".
    input      [15:0] rnd_seed,       // entropy seed for the rnd LFSR (mount latch)
    input             sec_tick,       // 1 Hz pulse: counter-mode GPRMs +1 (idle-gated)
    input             entropy_stir,   // pulse: fold user-input timing into the LFSR
    input      [15:0] entropy_val,    // entropy value to stir on entropy_stir

    // Command-table BRAM write (reader streams the loaded PGC's table)
    input             cmd_we,
    input      [11:0] cmd_waddr,
    input      [7:0]  cmd_wdata,
    input      [7:0]  nr_pre,
    input      [7:0]  nr_post,
    input      [7:0]  nr_cell,
    // Program-map BRAM write (reader P_PMAP walk; pm[i] = entry cell of pg i+1)
    input             pm_we,
    input      [6:0]  pm_waddr,
    input      [7:0]  pm_wdata,
    input      [7:0]  nr_pgms,

    // Reader events / read-backs
    input             pgc_loaded,     // pulse: PGC parsed (commands/counts valid)
    input             pgc_error,      // pulse: a menu jump failed
    input             vm_cell_cmd,    // pulse: cell ended, cell_cmd_nr!=0, reader waits
    input      [7:0]  cell_cmd_nr,
    input             vm_pgc_end,     // pulse: PGC done + drained, reader waits
    input             menu_active,    // level: menu-domain PGC loaded
    input      [7:0]  cur_vts,
    input      [15:0] cur_pgcn,
    input      [7:0]  cur_cell,
    input      [7:0]  cell_count,
    input      [15:0] next_pgcn,
    input      [15:0] prev_pgcn,
    input      [15:0] goup_pgcn,

    // User keys (edge pulses from emu)
    input             key_menu,
    input             key_title,      // B12: VMGM Title ("Top Menu") key
    input             key_return,     // B13: Return = GoUp (authored goup_pgcn)
    input             key_cmenu,      // B16: Chapter/PTT menu (VTSM entry 7)
    input             key_chedge,     // pulse: chapter skip hit the title's edge
    input             key_chedge_dir, // 1 = Next (POST), 0 = Prev (prev_pgcn)

    // Button activation (nav_pci)
    input      [63:0] btn_cmd,
    input             btn_cmd_valid,
    input      [5:0]  btn_sel,        // nav_pci live selection (SPRM8 shadow)
    input             btns_armed,
    output reg        btn_force,      // pulse: force nav_pci selection (SetHL_BTNN)
    output reg [5:0]  btn_force_val,
    // DVD-FORK FIX (2026-09-14, Scooby-Doo 2 Wickles Manor grid): HL_BTNN = the
    // button number SPRM8 holds RIGHT NOW. libdvdnav keeps HL_BTNN_REG in the VM
    // and NOTHING clears it on a jump (vm.c only writes it at links / SetHL_BTNN /
    // fosl / user select; vm_reset is the disc open). Our nav_pci lives on
    // pipe_rst_n, so every load_flush zeroed its selection to button 1 -- which
    // threw away the button a `LinkCN 26 (button 16)` / `LinkPGN 2 (button 18)`
    // carried, because that same link is what FIRES the flush. nav_pci re-seeds
    // its selection from this port when the flush releases. Wired in emu.sv;
    // gated by tools/check_hl_btnn_wiring.py (emu has no bench).
    output wire [5:0] hl_btnn,

    // Jump / seek / verdict outputs (to dvd_iso_reader via emu)
    output reg        jump_pulse,
    output reg [1:0]  jump_domain,
    output reg [7:0]  jump_vts,
    output reg [15:0] jump_pgcn,
    output reg [3:0]  jump_entry,
    output reg [6:0]  jump_ttn,       // TT: title-entry scan (0 = use jump_pgcn)
    output reg [7:0]  jump_pgn,       // TT: start at program n (0 = use jump_cell)
    output reg [9:0]  jump_ptt,       // TT: EXACT chapter/PTT part (Phase 6, 0/1 = ptt[0]);
                                      // reader resolves VTS_PTT_SRPT[ttn][ptt-1] -> {pgcn,pgn}
    output reg [7:0]  jump_cell,
    output reg        seek_pulse,     // in-PGC cell seek (flushing)
    output reg [7:0]  seek_cell,
    output reg        vm_replay,      // pulse: replay current cell (no flush)
    output            vm_adv,         // pulse: reader continues authored behaviour
    // NATURAL-JUMP PROVENANCE (tail-drain Phase B, docs/dvd_nav.md).
    // vm_from_wait = wait_verdict && nat_src: 1 only while the executing
    // block is CELL/POST AND the command chain was STARTED by a reader wait
    // event (ev_cellcmd / ev_pgcend) - a NATURAL transition. Sampled by
    // emu/the reader on the jump_pulse/seek_pulse cycle: a natural title
    // jump waits for vbuf_empty so its keep_vbuf=0 flush can't cut the clip's
    // buffered tail. nat_src (not blk alone) is what keeps USER chains
    // immediate: a POST reached via a button's LinkTailPGC reads BLK_POST but
    // nat_src=0 (the Tomb Raider Select scene-skip fix). The V_IDLE event
    // arms also set blk <= BLK_BTN + nat_src=0 (belt and braces).
    output            vm_from_wait,
    // Level from the reader (via emu): a natural jump/seek is latched and
    // GATED on vbuf_empty (nat_wait_o). Freezes the V_WAIT give-up timer -
    // the gate window is up to DRAIN_WD (~5 s), far past wait_tmr's ~0.62 s,
    // and an early give-up would clear skip_pre / leave tt_resolve armed
    // (wrong-PRE / stale-SPRM5 corruption). Drops the moment the reader
    // executes or watchdog-releases the jump, so the give-up guard against a
    // never-latched jump is preserved.
    input             wait_hold,

    // Stream selection (SetSTN)
    output     [7:0]  sprm_astn,      // SPRM1 (audio stream; >=8 = none selected)
    output     [7:0]  sprm_spstn,     // SPRM2 (subpicture; bit6 = display enable)
    // SPRM3 = AGLN, the camera angle. Exported for the SAME reason as SPRM1/2:
    // a disc picks its angle with SetSTN and the player must obey. MEASURED on
    // CASTLE_IN_THE_SKY: FP -> VMGM PGC2 post sets g[14]=2, and VTS_02 PGC1's
    // PRE runs "SetSTN ASTN=g[12] SPSTN=g[13] AGLN=g[14]" -- i.e. the disc asks
    // for ANGLE 2 (the English title cards; angle 1 is the Japanese ones), and
    // its own Audio menu re-issues SetSTN with the matching angle per language.
    // Before this port existed sprm3 was written and then DEAD: the reader's
    // cur_angle was fed only by the B6 button, so the disc's choice was ignored
    // and angle 1 always played.
    output     [7:0]  sprm_agln,      // SPRM3 (camera angle, 1-based)
    // Pulse: this PGC's PRE block has been resolved - it ran to the end, it
    // linked away, or there was none. The reader needs it because it picks the
    // angle CELL and we pick the angle NUMBER, and libdvdnav's order is
    // play_PGC -> PRE -> play_Cell's "cellN += AGL_REG - 1". Without it the
    // reader always resolves first (it arrives ~8 cycles after pgc_loaded; the
    // serial ALU needs far longer for even one command), so a SetSTN AGLN is
    // deterministically too late for the block it configures.
    output reg        pre_done,
    // A user B6 press must write BACK, or the disc's own menus read a stale
    // angle: CASTLE's VTSM PGCs 19/20/21/24 all execute "g[14] = AGLN" and
    // re-apply it on the next title entry. libdvdnav keeps AGL_REG the single
    // source of truth for exactly this reason.
    input             agl_set,        // pulse: user changed the angle
    input      [3:0]  agl_set_val,    // 1-based angle to store in SPRM3

    output     [7:0]  dbg_state,
    // DVD-FORK DEBUG (Atmosfear wrong-title diagnosis): expose the scenario-
    // dispatch GPRMs (read by dvd_vm_tb; emu leaves them unconnected since the
    // debug overlay that latched them at the game jump was retired).
    output     [15:0] dbg_g3,          // g[3] = the scenario-dispatch selector
    output     [15:0] dbg_g14_9,       // {g[14][7:0] (root button), g[9][7:0] (yes count)}
    // DVD-FORK DEBUG (TP Star Wars symptom-1 diagnosis): the RSM target, so the
    // overlay can tell "resumed the FP intro (rsm=01/01)" from other landings.
    output     [15:0] dbg_rsm,         // {rsm_vts[7:0], rsm_pgcn[7:0]}
    // {deadend_vts, deadend_pgcn} of the FIRST 0-cell menu PGC that reached the end
    // of its PRE with NO link taken (0 = none). Two triggers share this latch:
    //   (1) nr_pre == 0  (a genuine command-less stub), and
    //   (2) nr_pre != 0 but every PRE command FELL THROUGH (a selector dispatcher
    //       with no matching case). (2) is the COMMON, BENIGN one -- e.g. Trivial
    //       Pursuit Star Wars' VTSM Root PGC1 is a `g15=TTN; if(g15==k) LinkPGCN..`
    //       dispatcher over its 18 titles with NO case for TTN==1, so reaching Root
    //       from the intro (TTN==1) context legitimately falls through. The reader
    //       delivers the real nr_pre (=13) correctly -- this is NOT a reader/parse or
    //       sector-straddle bug (that theory was investigated + disproven; see
    //       docs/dvd_nav.md "Sector-straddle audit"). Either way the VM recovers to a
    //       menu (FB_VTSM) instead of the auto-title (= the copyright), which is why
    //       TP_SW plays correctly (a question returns to the menu).
    output     [15:0] dbg_deadend,

    // One-cycle pulse: a USER-visible menu link failed to resolve (pgc_error on
    // a menu-domain jump) and the VM re-entered the last good menu instead of
    // running the auto-title fallback. emu surfaces it as the transport-HUD
    // "LINK FAIL nn" popup so a field report can say what happened.
    output reg        link_fail,
    // The PGCN that failed to resolve, valid on the link_fail pulse (HUD digits).
    output reg [7:0]  link_fail_pgcn
);

// ==== BEGIN GENERATED by tools/nav_isa.py --asm (never edit) ====
localparam integer UC_WORDS = 1014;
localparam integer UC_DEPTH = 1024;
localparam [5:0] UOP_NOP = 6'd0;
localparam [5:0] UOP_ALU = 6'd1;
localparam [5:0] UOP_ALUI = 6'd2;
localparam [5:0] UOP_DCMP = 6'd3;
localparam [5:0] UOP_LD = 6'd4;
localparam [5:0] UOP_ST = 6'd5;
localparam [5:0] UOP_LDC = 6'd6;
localparam [5:0] UOP_LDP = 6'd7;
localparam [5:0] UOP_IN = 6'd8;
localparam [5:0] UOP_OUT = 6'd9;
localparam [5:0] UOP_OUTI = 6'd10;
localparam [5:0] UOP_BR = 6'd11;
localparam [5:0] UOP_BRI = 6'd12;
localparam [5:0] UOP_BB = 6'd13;
localparam [5:0] UOP_JMP = 6'd14;
localparam [5:0] UOP_CALL = 6'd15;
localparam [5:0] UOP_RET = 6'd16;
localparam [5:0] UOP_JR = 6'd17;
localparam [5:0] UOP_WEV = 6'd18;
localparam [3:0] UFN_ADD = 4'd0;
localparam [3:0] UFN_SUB = 4'd1;
localparam [3:0] UFN_AND = 4'd2;
localparam [3:0] UFN_OR = 4'd3;
localparam [3:0] UFN_XOR = 4'd4;
localparam [3:0] UFN_SHL = 4'd5;
localparam [3:0] UFN_SHR = 4'd6;
localparam [3:0] UFN_SADD = 4'd7;
localparam [3:0] UFN_SSUB = 4'd8;
localparam [3:0] UFN_SEQ = 4'd9;
localparam [3:0] UFN_SNE = 4'd10;
localparam [3:0] UFN_SLTU = 4'd11;
localparam [3:0] UFN_SGEU = 4'd12;
localparam [5:0] UIN_CUR_VTS = 6'd0;
localparam [5:0] UIN_CUR_PGCN = 6'd1;
localparam [5:0] UIN_CUR_CELL = 6'd2;
localparam [5:0] UIN_CELL_COUNT = 6'd3;
localparam [5:0] UIN_NEXT_PGCN = 6'd4;
localparam [5:0] UIN_PREV_PGCN = 6'd5;
localparam [5:0] UIN_GOUP_PGCN = 6'd6;
localparam [5:0] UIN_NR_PRE = 6'd7;
localparam [5:0] UIN_NR_POST = 6'd8;
localparam [5:0] UIN_NR_CELL = 6'd9;
localparam [5:0] UIN_NR_PGMS = 6'd10;
localparam [5:0] UIN_AUTO_VTS = 6'd11;
localparam [5:0] UIN_BEST_MENU_VTS = 6'd12;
localparam [5:0] UIN_RES_TTN = 6'd13;
localparam [5:0] UIN_MENU_ACTIVE = 6'd14;
localparam [5:0] UIN_CC_NR = 6'd15;
localparam [5:0] UIN_CHEDGE_DIR = 6'd16;
localparam [5:0] UIN_LFSR = 6'd17;
localparam [5:0] UIN_VM_DOM = 6'd18;
localparam [5:0] UIN_VM_VTS = 6'd19;
localparam [5:0] UIN_MENU_SEEN = 6'd20;
localparam [5:0] UIN_LM_V = 6'd21;
localparam [5:0] UIN_LM_DOM = 6'd22;
localparam [5:0] UIN_LM_VTS = 6'd23;
localparam [5:0] UIN_LM_PGCN = 6'd24;
localparam [5:0] UIN_JPGCN = 6'd25;
localparam [5:0] UIN_EVENTS = 6'd26;
localparam [5:0] UIN_ZERO27 = 6'd27;
localparam [5:0] UIN_BTN0 = 6'd28;
localparam [5:0] UIN_BTN1 = 6'd29;
localparam [5:0] UIN_BTN2 = 6'd30;
localparam [5:0] UIN_BTN3 = 6'd31;
localparam [5:0] UIN_SPRMW = 6'd32;
localparam [5:0] UOUT_J_DE = 6'd0;
localparam [5:0] UOUT_J_VTS = 6'd1;
localparam [5:0] UOUT_J_PGCN = 6'd2;
localparam [5:0] UOUT_RSV3 = 6'd3;
localparam [5:0] UOUT_J_TTN = 6'd4;
localparam [5:0] UOUT_J_PGN = 6'd5;
localparam [5:0] UOUT_J_PTT = 6'd6;
localparam [5:0] UOUT_J_CELL = 6'd7;
localparam [5:0] UOUT_SEEK_CELL = 6'd8;
localparam [5:0] UOUT_PULSE = 6'd9;
localparam [5:0] UOUT_BTNF_VAL = 6'd10;
localparam [5:0] UOUT_LF_PGCN = 6'd11;
localparam [5:0] UOUT_SPRM1 = 6'd12;
localparam [5:0] UOUT_SPRM2 = 6'd13;
localparam [5:0] UOUT_SPRM3 = 6'd14;
localparam [5:0] UOUT_SPRM8 = 6'd15;
localparam [5:0] UOUT_VM_DOM = 6'd16;
localparam [5:0] UOUT_VM_VTS = 6'd17;
localparam [5:0] UOUT_FLAGS = 6'd18;
localparam [5:0] UOUT_EVCLR = 6'd19;
localparam [5:0] UOUT_EVSET = 6'd20;
localparam integer UPB_JUMP = 0;
localparam integer UPB_SEEK = 1;
localparam integer UPB_REPLAY = 2;
localparam integer UPB_ADV = 3;
localparam integer UPB_BTNF = 4;
localparam integer UPB_LINKFAIL = 5;
localparam integer UPB_LFSTEP = 6;
localparam integer UPB_WARM = 7;
localparam integer UPB_TICKDONE = 8;
localparam integer UFL_BLK = 0;
localparam integer UFL_NAT = 2;
localparam integer UFL_USR = 3;
localparam integer UFL_WALK = 4;
localparam integer UEV_BOOT = 0;
localparam integer UEV_ERROR = 1;
localparam integer UEV_LOADED = 2;
localparam integer UEV_BTN = 3;
localparam integer UEV_CELLCMD = 4;
localparam integer UEV_PGCEND = 5;
localparam integer UEV_CHEDGE = 6;
localparam integer UEV_MENU = 7;
localparam integer UEV_TITLE = 8;
localparam integer UEV_CMENU = 9;
localparam integer UEV_RETURN = 10;
localparam integer UEV_N = 11;
localparam [7:0] UM_GPRM = 8'h00;
localparam [7:0] UM_GMODE = 8'h10;
localparam [7:0] UM_FB = 8'h11;
localparam [7:0] UM_CVM = 8'h12;
localparam [7:0] UM_SKIP_PRE = 8'h13;
localparam [7:0] UM_TT_RESOLVE = 8'h14;
localparam [7:0] UM_CHAIN = 8'h15;
localparam [7:0] UM_RSM_VTS = 8'h18;
localparam [7:0] UM_RSM_PGCN = 8'h19;
localparam [7:0] UM_RSM_CELL = 8'h1a;
localparam [7:0] UM_RSM_R4 = 8'h1b;
localparam [7:0] UM_RSM_R5 = 8'h1c;
localparam [7:0] UM_RSM_R6 = 8'h1d;
localparam [7:0] UM_RSM_R7 = 8'h1e;
localparam [7:0] UM_RSM_R8 = 8'h1f;
localparam [7:0] UM_DE_SEEN = 8'h20;
localparam [7:0] UM_DE_VTS = 8'h21;
localparam [7:0] UM_DE_PGCN = 8'h22;
localparam [7:0] UM_T0 = 8'h28;
localparam [7:0] UM_SPRMI = 8'h40;
localparam [2:0] UFB_NONE = 3'd0;
localparam [2:0] UFB_FP = 3'd1;
localparam [2:0] UFB_VTSM = 3'd2;
localparam [2:0] UFB_VTSM2 = 3'd3;
localparam [2:0] UFB_VMGM = 3'd4;
localparam [2:0] UFB_TITLE = 3'd5;
localparam [2:0] UFB_GAVEUP = 3'd6;
localparam [2:0] UFB_BOOTM = 3'd7;
// ==== END GENERATED ====

localparam [1:0] DOM_FP = 2'd0, DOM_VMGM = 2'd1, DOM_VTSM = 2'd2, DOM_TT = 2'd3;

// =========================================================================
// Command table (written by the reader at PGC load) + program map. The table
// is two byte banks so the sequencer reads a whole 16-bit word (ins[63:48] ...)
// per access: 2 x 2048 x 8 = the same 4 M10K as the old 4096 x 8. 512 commands
// covers the spec's 128 pre + 128 post + 128 cell (+ margin; was 256 = a >256-
// command menu dispatcher was skipped -> nav broke).
// =========================================================================
wire [10:0] c_ra;
wire [6:0]  p_ra;
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] cmem_e [0:2047];   // even bytes
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] cmem_o [0:2047];   // odd bytes
reg [7:0] ce_q, co_q;
always @(posedge clk) begin
    if (cmd_we && !cmd_waddr[0]) cmem_e[cmd_waddr[11:1]] <= cmd_wdata;
    ce_q <= cmem_e[c_ra];
end
always @(posedge clk) begin
    if (cmd_we && cmd_waddr[0]) cmem_o[cmd_waddr[11:1]] <= cmd_wdata;
    co_q <= cmem_o[c_ra];
end
wire [15:0] c_q = {ce_q, co_q};

reg [7:0] pmem [0:127];
reg [7:0] p_q;
always @(posedge clk) begin
    if (pm_we) pmem[pm_waddr] <= pm_wdata;
    p_q <= pmem[p_ra];
end

// Silicon powers these up 0; say so for simulation (the old FSM read X here
// before the first write -- bench/dvd/vm_ab_tb.sv).
integer mi;
initial begin
    for (mi = 0; mi < 2048; mi = mi + 1) begin cmem_e[mi] = 8'd0; cmem_o[mi] = 8'd0; end
    for (mi = 0; mi < 128; mi = mi + 1) pmem[mi] = 8'd0;
end

// =========================================================================
// The sequencer
// =========================================================================
wire [5:0]  in_port;
reg  [15:0] in_data;
wire        out_stb;
wire [5:0]  out_port;
wire [15:0] out_data;
wire        wev_req, wev_mode, wev_take;
reg         ev_valid;
reg  [3:0]  ev_idx;
wire        snoop_we;
wire [7:0]  snoop_a;
wire [15:0] snoop_d;

nav_seq u_seq (
    .clk(clk), .rst_n(rst_n), .restart(start),
    .c_ra(c_ra), .c_q(c_q), .p_ra(p_ra), .p_q(p_q),
    .in_port(in_port), .in_data(in_data),
    .out_stb(out_stb), .out_port(out_port), .out_data(out_data),
    .wev_req(wev_req), .wev_mode(wev_mode), .ev_valid(ev_valid), .ev_idx(ev_idx),
    .wev_take(wev_take),
    .snoop_we(snoop_we), .snoop_a(snoop_a), .snoop_d(snoop_d),
    .tr_valid(), .tr_kind(), .tr_pc(), .tr_addr(), .tr_val());

wire o_we = out_stb;                 // one output write per cycle, decoded below
wire [15:0] od = out_data;

// =========================================================================
// The wrapper's state: everything real-time, and everything a port shows
// =========================================================================
reg  [UEV_N-1:0] ev;                 // event latches, UEV_* order (the wev priority)
reg  [7:0]  ev_cellcmd_nr;
reg  [63:0] ev_btn_cmd;
reg         ev_chedge_dir;
reg         nav_ready_d;
reg         tick_pending;
reg  [4:0]  flags;                   // {walk, usr_edge, nat_src, blk[1:0]} from the microcode
reg  [1:0]  vm_dom;
reg  [7:0]  vm_vts;
reg         menu_seen;
reg  [1:0]  last_menu_dom;
reg  [7:0]  last_menu_vts;
reg  [15:0] last_menu_pgcn;
reg         last_menu_v;
reg  [15:0] sprm1, sprm2, sprm3, sprm8;
reg         sprm8_frozen;
reg  [15:0] lfsr;
reg         seed_ld;
reg  [9:0]  j_ptt;
reg         vm_adv_q;
reg         pre_armed;
reg  [23:0] wait_tmr;

assign sprm_astn  = sprm1[7:0];
assign sprm_spstn = sprm2[7:0];
assign sprm_agln  = sprm3[7:0];

// SPRM8 shadows the live nav_pci selection while buttons are armed (the D-pad
// moves the selection outside the VM; compares like "if SPRM8==0x400" must see
// it). DVD-FORK FIX `sprm8_frozen`: once a button is ACTIVATED, its command's
// dispatch must read the ACTIVATED button, not the live selection (Atmosfear's
// LinkTailPGC -> POST reads HL_BTNN); the next PGC load clears it.
wire [15:0] sprm8_eff = (btns_armed && !sprm8_frozen) ? {btn_sel, 10'd0} : sprm8;
// The exported HL_BTNN is the REGISTER (nav_pci re-seeds from it after a pipe
// reset; gated by tools/check_hl_btnn_wiring.py).
assign hl_btnn = sprm8[15:10];

// LFSR16 for rnd (taps 0/2/3/5 -> new MSB; steps ONCE per rnd, bit-exact with
// tools/dvd_vm_ref.py). Seeded from rnd_seed (nonzero) at power-on and at every
// mount -- SYNCHRONOUSLY: the old FSM loaded this non-constant value in its async
// reset branch, which every STA run logged as a latch (emu|dvd_vm|lfsr[8]~15).
wire [15:0] lfsr_next = {(lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5]), lfsr[15:1]};
wire [15:0] lfsr_seed = (|rnd_seed) ? rnd_seed : 16'hACE1;
wire [15:0] lfsr_stir = lfsr ^ entropy_val;

// V_IDLE of the old FSM: parked at the idle wev, or in the counter-tick walk.
// pre_done and the entropy stir are defined against it.
wire v_idle      = (wev_req && !wev_mode) || flags[UFL_WALK];
wire parked_wait = wev_req && wev_mode;
wire wait_verdict = (flags[1:0] == 2'd1) || (flags[1:0] == 2'd2);   // POST / CELL
assign vm_from_wait = wait_verdict && flags[UFL_NAT];
assign vm_adv = vm_adv_q;

// ---- the event priority (wev) -------------------------------------------
// idle: the tick, then Disc Menus off, then the events in UEV_* order (index + 2);
// wait: the load, the error, the timeout.
integer ei;
always @* begin
    ev_valid = 1'b0;
    ev_idx   = 4'd0;
    if (!wev_mode) begin
        if (tick_pending) begin
            ev_valid = 1'b1; ev_idx = 4'd0;
        end else if (!enable && (|ev)) begin
            ev_valid = 1'b1; ev_idx = 4'd1;
        end else begin
            for (ei = UEV_N - 1; ei >= 0; ei = ei - 1)
                if (ev[ei]) begin ev_valid = 1'b1; ev_idx = ei + 2; end
        end
    end else begin
        if (ev[UEV_LOADED])                 begin ev_valid = 1'b1; ev_idx = 4'd0; end
        else if (ev[UEV_ERROR])             begin ev_valid = 1'b1; ev_idx = 4'd1; end
        else if (wait_tmr == 24'hFFFFFF)    begin ev_valid = 1'b1; ev_idx = 4'd2; end
    end
end

// ---- the sequencer's inputs ------------------------------------------------
always @* begin
    in_data = 16'd0;
    if (in_port[5]) begin
        // the live-SPRM window (the RAM-resident SPRMs read 0 here)
        case (in_port[4:0])
        5'd0, 5'd16, 5'd18: in_data = cfg_lang;   // player language: menu, audio, subpicture
        5'd1:  in_data = sprm1;
        5'd2:  in_data = sprm2;
        5'd3:  in_data = sprm3;
        5'd8:  in_data = sprm8_eff;
        5'd12: in_data = 16'h5553;                // 'US' parental country
        5'd14: in_data = cfg_sprm14;              // video preference (player_regs)
        5'd15: in_data = cfg_sprm15;              // audio capabilities (player_regs)
        5'd20: in_data = cfg_sprm20;              // player region (player_regs)
        default: ;
        endcase
    end else begin
        case (in_port)
        UIN_CUR_VTS:       in_data = {8'd0, cur_vts};
        UIN_CUR_PGCN:      in_data = cur_pgcn;
        UIN_CUR_CELL:      in_data = {8'd0, cur_cell};
        UIN_CELL_COUNT:    in_data = {8'd0, cell_count};
        UIN_NEXT_PGCN:     in_data = next_pgcn;
        UIN_PREV_PGCN:     in_data = prev_pgcn;
        UIN_GOUP_PGCN:     in_data = goup_pgcn;
        UIN_NR_PRE:        in_data = {8'd0, nr_pre};
        UIN_NR_POST:       in_data = {8'd0, nr_post};
        UIN_NR_CELL:       in_data = {8'd0, nr_cell};
        UIN_NR_PGMS:       in_data = {8'd0, nr_pgms};
        UIN_AUTO_VTS:      in_data = {8'd0, auto_vts};
        UIN_BEST_MENU_VTS: in_data = {8'd0, best_menu_vts};
        UIN_RES_TTN:       in_data = {9'd0, res_ttn};
        UIN_MENU_ACTIVE:   in_data = {15'd0, menu_active};
        UIN_CC_NR:         in_data = {8'd0, ev_cellcmd_nr};
        UIN_CHEDGE_DIR:    in_data = {15'd0, ev_chedge_dir};
        UIN_LFSR:          in_data = lfsr;
        UIN_VM_DOM:        in_data = {14'd0, vm_dom};
        UIN_VM_VTS:        in_data = {8'd0, vm_vts};
        UIN_MENU_SEEN:     in_data = {15'd0, menu_seen};
        UIN_LM_V:          in_data = {15'd0, last_menu_v};
        UIN_LM_DOM:        in_data = {14'd0, last_menu_dom};
        UIN_LM_VTS:        in_data = {8'd0, last_menu_vts};
        UIN_LM_PGCN:       in_data = last_menu_pgcn;
        UIN_JPGCN:         in_data = jump_pgcn;
        UIN_EVENTS:        in_data = {{(16 - UEV_N){1'b0}}, ev};
        UIN_BTN0:          in_data = ev_btn_cmd[63:48];
        UIN_BTN1:          in_data = ev_btn_cmd[47:32];
        UIN_BTN2:          in_data = ev_btn_cmd[31:16];
        UIN_BTN3:          in_data = ev_btn_cmd[15:0];
        default: ;
        endcase
    end
end

// ---- the clocked half ------------------------------------------------------
reg [UEV_N-1:0] ev_set, ev_clr, ev_force;
always @* begin
    ev_set = {UEV_N{1'b0}};
    if (enable) begin
        ev_set[UEV_BOOT]    = nav_ready && !nav_ready_d;
        ev_set[UEV_LOADED]  = pgc_loaded;
        ev_set[UEV_ERROR]   = pgc_error;
        ev_set[UEV_CELLCMD] = vm_cell_cmd;
        ev_set[UEV_PGCEND]  = vm_pgc_end;
        ev_set[UEV_BTN]     = btn_cmd_valid;
        ev_set[UEV_MENU]    = key_menu;
        ev_set[UEV_TITLE]   = key_title;
        ev_set[UEV_RETURN]  = key_return;
        ev_set[UEV_CMENU]   = key_cmenu;
        ev_set[UEV_CHEDGE]  = key_chedge;
    end
    // the microcode's clears win over a same-cycle latch, as the old FSM's did
    ev_clr = (o_we && out_port == UOUT_EVCLR) ? od[UEV_N-1:0] : {UEV_N{1'b0}};
    if (wev_take && !wev_mode && ev_idx >= 4'd2) ev_clr[ev_idx - 4'd2] = 1'b1;
    ev_force = (o_we && out_port == UOUT_EVSET) ? od[UEV_N-1:0] : {UEV_N{1'b0}};
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ev <= {UEV_N{1'b0}};
        ev_cellcmd_nr <= 8'd0; ev_btn_cmd <= 64'd0; ev_chedge_dir <= 1'b0;
        nav_ready_d <= 1'b0;
        tick_pending <= 1'b0;
        flags <= 5'd0;
        vm_dom <= DOM_TT; vm_vts <= 8'd0;
        menu_seen <= 1'b0;
        last_menu_dom <= DOM_VTSM; last_menu_vts <= 8'd0;
        last_menu_pgcn <= 16'd0; last_menu_v <= 1'b0;
        sprm1 <= 16'd15; sprm2 <= 16'd62; sprm3 <= 16'd1; sprm8 <= 16'h0400;
        sprm8_frozen <= 1'b0;
        lfsr <= 16'hACE1; seed_ld <= 1'b1;
        j_ptt <= 10'd0;
        pre_armed <= 1'b0; pre_done <= 1'b0;
        wait_tmr <= 24'd0;
        jump_pulse <= 1'b0; jump_domain <= DOM_TT;
        jump_vts <= 8'd0; jump_pgcn <= 16'd0; jump_entry <= 4'd0;
        jump_ttn <= 7'd0; jump_pgn <= 8'd0; jump_cell <= 8'd0; jump_ptt <= 10'd0;
        seek_pulse <= 1'b0; seek_cell <= 8'd0;
        vm_replay <= 1'b0; vm_adv_q <= 1'b0;
        btn_force <= 1'b0; btn_force_val <= 6'd1;
        link_fail <= 1'b0; link_fail_pgcn <= 8'd0;
    end else begin
        // one-cycle pulses; jump_ptt is 0 except on the jump_pulse cycle
        jump_pulse <= 1'b0; jump_ptt <= 10'd0;
        seek_pulse <= 1'b0; vm_replay <= 1'b0; vm_adv_q <= 1'b0;
        btn_force <= 1'b0; link_fail <= 1'b0;
        nav_ready_d <= nav_ready;

        // SPRM8 shadow write-back (lowest priority), SPRM3 write-back of a user
        // angle change; the activation latch and the microcode's writes land later
        // in this block and win.
        if (btns_armed && !sprm8_frozen) sprm8 <= {btn_sel, 10'd0};
        if (agl_set) sprm3 <= {12'd0, agl_set_val};
        // the last SUCCESSFULLY loaded menu PGC (the LINK FAIL re-enter target) and
        // menu_seen (the boot-chain shortcut's gate), on the load event itself
        if (pgc_loaded && (vm_dom == DOM_VMGM || vm_dom == DOM_VTSM)) begin
            last_menu_dom  <= vm_dom;
            last_menu_vts  <= vm_vts;
            last_menu_pgcn <= cur_pgcn;
            last_menu_v    <= 1'b1;
            menu_seen      <= 1'b1;
        end
        if (sec_tick) tick_pending <= 1'b1;

        // pre_done: this PGC's PRE block has been resolved. Arms on every load and
        // fires once the load EVENT is consumed and the VM is idle or has linked away.
        // ⚠ The !ev[LOADED] term is load-bearing (the pulse must not precede the PRE).
        pre_done <= 1'b0;
        if (pgc_loaded)
            pre_armed <= 1'b1;
        else if (pre_armed && !ev[UEV_LOADED] && (v_idle || jump_pulse)) begin
            pre_armed <= 1'b0;
            pre_done  <= 1'b1;
        end

        // event latches (Disc Menus gate them) and their payloads
        ev <= ((ev | ev_set) & ~ev_clr) | ev_force;
        if (enable) begin
            if (vm_cell_cmd) ev_cellcmd_nr <= cell_cmd_nr;
            if (btn_cmd_valid) begin
                ev_btn_cmd <= btn_cmd;
                // DVD-FORK FIX: durably latch the ACTIVATED button into SPRM8 (a
                // menu's dispatch PRE runs after the menu tears down); freeze it
                sprm8 <= {btn_sel, 10'd0};
                sprm8_frozen <= 1'b1;
            end
            if (pgc_loaded) sprm8_frozen <= 1'b0;
            if (key_chedge) ev_chedge_dir <= key_chedge_dir;
        end

        // the wait timer (~0.62 s): counts while the VM waits for a jump's verdict,
        // frozen by wait_hold (a natural jump gated on the tail drain)
        if (parked_wait && !wait_hold) wait_tmr <= wait_tmr + 24'd1;

        // the LFSR: seeded on the first cycle out of reset, stirred while idle
        if (seed_ld) begin
            lfsr <= lfsr_seed; seed_ld <= 1'b0;
        end else if (entropy_stir && v_idle)
            lfsr <= (|lfsr_stir) ? lfsr_stir : 16'hACE1;

        // ---- the microcode's outputs ----
        if (o_we) begin
            case (out_port)
            UOUT_J_DE:      begin jump_domain <= od[1:0]; jump_entry <= od[7:4]; end
            UOUT_J_VTS:     jump_vts  <= od[7:0];
            UOUT_J_PGCN:    jump_pgcn <= od;
            UOUT_J_TTN:     jump_ttn  <= od[6:0];
            UOUT_J_PGN:     jump_pgn  <= od[7:0];
            UOUT_J_PTT:     j_ptt     <= od[9:0];
            UOUT_J_CELL:    jump_cell <= od[7:0];
            UOUT_SEEK_CELL: seek_cell <= od[7:0];
            UOUT_BTNF_VAL:  btn_force_val <= od[5:0];
            UOUT_LF_PGCN:   link_fail_pgcn <= od[7:0];
            UOUT_SPRM1:     sprm1 <= od;
            UOUT_SPRM2:     sprm2 <= od;
            UOUT_SPRM3:     sprm3 <= od;
            UOUT_SPRM8:     sprm8 <= od;
            UOUT_VM_DOM:    vm_dom <= od[1:0];
            UOUT_VM_VTS:    vm_vts <= od[7:0];
            UOUT_FLAGS:     flags <= od[4:0];
            UOUT_PULSE: begin
                if (od[UPB_JUMP])   begin jump_pulse <= 1'b1; jump_ptt <= j_ptt; end
                if (od[UPB_SEEK])   seek_pulse <= 1'b1;
                if (od[UPB_REPLAY]) vm_replay <= 1'b1;
                // a title-edge chain (usr_edge) is the user's: its no-op arms must
                // not release a reader that waits on something else
                if (od[UPB_ADV])    vm_adv_q <= !flags[UFL_USR];
                if (od[UPB_BTNF])   btn_force <= 1'b1;
                if (od[UPB_LINKFAIL]) link_fail <= 1'b1;
                if (od[UPB_LFSTEP]) lfsr <= lfsr_next;
                if (od[UPB_WARM])   wait_tmr <= 24'd0;
                if (od[UPB_TICKDONE]) tick_pending <= 1'b0;
            end
            default: ;
            endcase
        end

        // ---- mount: vm_reset (overrides everything above, as the old FSM's did) ----
        if (start) begin
            ev <= {UEV_N{1'b0}};
            tick_pending <= 1'b0;
            flags <= {3'd0, flags[1:0]};
            vm_dom <= DOM_TT; vm_vts <= 8'd0;
            menu_seen <= 1'b0;
            last_menu_dom <= DOM_VTSM; last_menu_vts <= 8'd0;
            last_menu_pgcn <= 16'd0; last_menu_v <= 1'b0;
            sprm1 <= 16'd15; sprm2 <= 16'd62; sprm3 <= 16'd1; sprm8 <= 16'h0400;
            sprm8_frozen <= 1'b0;
            lfsr <= lfsr_seed; seed_ld <= 1'b0;
        end
    end
end

// =========================================================================
// Debug ports. Nothing in the core reads them (emu leaves them open, so they
// are pruned); dvd_vm_tb reads dbg_state. fb / came_via_menukey / RSM / dead
// end are mirrored from the sequencer's RAM writes, so no microcode is spent.
// =========================================================================
reg [2:0]  dbg_fb;
reg        dbg_cvm;
reg [7:0]  dbg_rsm_vts, dbg_rsm_pgcn, dbg_de_vts, dbg_de_pgcn;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dbg_fb <= 3'd0; dbg_cvm <= 1'b0;
        dbg_rsm_vts <= 8'd0; dbg_rsm_pgcn <= 8'd0; dbg_de_vts <= 8'd0; dbg_de_pgcn <= 8'd0;
    end else if (snoop_we) begin
        case (snoop_a)
        UM_FB:       dbg_fb       <= snoop_d[2:0];
        UM_CVM:      dbg_cvm      <= snoop_d[0];
        UM_RSM_VTS:  dbg_rsm_vts  <= snoop_d[7:0];
        UM_RSM_PGCN: dbg_rsm_pgcn <= snoop_d[7:0];
        UM_DE_VTS:   dbg_de_vts   <= snoop_d[7:0];
        UM_DE_PGCN:  dbg_de_pgcn  <= snoop_d[7:0];
        default: ;
        endcase
    end
end
// state: the old FSM's encoding for the two states anything observes
// (V_IDLE = 0, V_WAIT = 10); 2 (V_EXEC) while the program runs
wire [3:0] state = wev_req ? (wev_mode ? 4'd10 : 4'd0) : 4'd2;
assign dbg_state   = {dbg_cvm, dbg_fb, state};
assign dbg_g3      = 16'd0;
assign dbg_g14_9   = 16'd0;
assign dbg_rsm     = {dbg_rsm_vts, dbg_rsm_pgcn};
assign dbg_deadend = {dbg_de_vts, dbg_de_pgcn};

endmodule


// nav_seq.sv - the navigation sequencer: a small microcoded machine that runs the
// DVD virtual machine (dvd/nav/vm.uasm) inside dvd/dvd_vm.sv (docs/nav_engine.md).
//
// The executable definition of this machine is tools/nav_isa.py: its instruction
// set, its assembler, and an emulator the RTL must match instruction by instruction
// (bench/dvd/nav_seq_tb.sv scores the tr_* trace against it; tools/vm_ab.py scores
// the whole VM, wrapper included, against the hardwired FSM it replaced).
//
// Instruction word, 40 bits: op[39:34] rd[33:30] rs[29:26] rt[25:22] imm[21:6] aux[5:0].
// 16 registers of 16 bits (r0 = 0), a 4-deep call stack, a 1K-word program ROM and a
// 256 x 16 data RAM, both M10K. ld/ldc/ldp take 2 cycles, everything else 1; wev
// parks until the wrapper offers an event.
//
// The command table (ldc) and the program map (ldp) live in the wrapper, which the
// reader writes; this module only addresses them. So does every input (in) and
// output (out/outi): the wrapper is the machine's whole world.
//
// ⚠ Quartus 17: no `function`s, no N'(expr) size casts (both have miscompiled in
// silicon here; CLAUDE.md "Cross-cutting lessons"). Every memory is touched in
// exactly one clocked block; after an edit near one, grep DVD.map.rpt for its
// "Inferred altsyncram" line.
module nav_seq (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        restart,      // a mount: pc <- 0, stack empty; registers and RAM kept

    // command table / program map (in the wrapper; registered reads, data next cycle)
    output wire [10:0] c_ra,
    input  wire [15:0] c_q,
    output wire [6:0]  p_ra,
    input  wire [7:0]  p_q,

    // the wrapper's ports
    output wire [5:0]  in_port,
    input  wire [15:0] in_data,
    output wire        out_stb,
    output wire [5:0]  out_port,
    output wire [15:0] out_data,

    // events: wev offers its mode; the wrapper answers combinationally
    output wire        wev_req,      // executing a wev this cycle (= parked if no event)
    output wire        wev_mode,
    input  wire        ev_valid,
    input  wire [3:0]  ev_idx,
    output wire        wev_take,     // the event is dispatched this cycle

    // data RAM write snoop (debug mirrors in the wrapper; pruned in the core)
    output wire        snoop_we,
    output wire [7:0]  snoop_a,
    output wire [15:0] snoop_d,

    // bench-only trace (unconnected in the core)
    output reg         tr_valid,
    output reg  [1:0]  tr_kind,      // 0 reg write, 1 store, 2 output, 3 dispatch
    output reg  [9:0]  tr_pc,
    output reg  [7:0]  tr_addr,
    output reg  [15:0] tr_val
);
// ==== BEGIN GENERATED by tools/nav_isa.py --asm (never edit) ====
localparam integer UC_WORDS = 1014;
localparam integer UC_DEPTH = 1024;
localparam [5:0] UOP_NOP = 6'd0;
localparam [5:0] UOP_ALU = 6'd1;
localparam [5:0] UOP_ALUI = 6'd2;
localparam [5:0] UOP_DCMP = 6'd3;
localparam [5:0] UOP_LD = 6'd4;
localparam [5:0] UOP_ST = 6'd5;
localparam [5:0] UOP_LDC = 6'd6;
localparam [5:0] UOP_LDP = 6'd7;
localparam [5:0] UOP_IN = 6'd8;
localparam [5:0] UOP_OUT = 6'd9;
localparam [5:0] UOP_OUTI = 6'd10;
localparam [5:0] UOP_BR = 6'd11;
localparam [5:0] UOP_BRI = 6'd12;
localparam [5:0] UOP_BB = 6'd13;
localparam [5:0] UOP_JMP = 6'd14;
localparam [5:0] UOP_CALL = 6'd15;
localparam [5:0] UOP_RET = 6'd16;
localparam [5:0] UOP_JR = 6'd17;
localparam [5:0] UOP_WEV = 6'd18;
localparam [3:0] UFN_ADD = 4'd0;
localparam [3:0] UFN_SUB = 4'd1;
localparam [3:0] UFN_AND = 4'd2;
localparam [3:0] UFN_OR = 4'd3;
localparam [3:0] UFN_XOR = 4'd4;
localparam [3:0] UFN_SHL = 4'd5;
localparam [3:0] UFN_SHR = 4'd6;
localparam [3:0] UFN_SADD = 4'd7;
localparam [3:0] UFN_SSUB = 4'd8;
localparam [3:0] UFN_SEQ = 4'd9;
localparam [3:0] UFN_SNE = 4'd10;
localparam [3:0] UFN_SLTU = 4'd11;
localparam [3:0] UFN_SGEU = 4'd12;
localparam [5:0] UIN_CUR_VTS = 6'd0;
localparam [5:0] UIN_CUR_PGCN = 6'd1;
localparam [5:0] UIN_CUR_CELL = 6'd2;
localparam [5:0] UIN_CELL_COUNT = 6'd3;
localparam [5:0] UIN_NEXT_PGCN = 6'd4;
localparam [5:0] UIN_PREV_PGCN = 6'd5;
localparam [5:0] UIN_GOUP_PGCN = 6'd6;
localparam [5:0] UIN_NR_PRE = 6'd7;
localparam [5:0] UIN_NR_POST = 6'd8;
localparam [5:0] UIN_NR_CELL = 6'd9;
localparam [5:0] UIN_NR_PGMS = 6'd10;
localparam [5:0] UIN_AUTO_VTS = 6'd11;
localparam [5:0] UIN_BEST_MENU_VTS = 6'd12;
localparam [5:0] UIN_RES_TTN = 6'd13;
localparam [5:0] UIN_MENU_ACTIVE = 6'd14;
localparam [5:0] UIN_CC_NR = 6'd15;
localparam [5:0] UIN_CHEDGE_DIR = 6'd16;
localparam [5:0] UIN_LFSR = 6'd17;
localparam [5:0] UIN_VM_DOM = 6'd18;
localparam [5:0] UIN_VM_VTS = 6'd19;
localparam [5:0] UIN_MENU_SEEN = 6'd20;
localparam [5:0] UIN_LM_V = 6'd21;
localparam [5:0] UIN_LM_DOM = 6'd22;
localparam [5:0] UIN_LM_VTS = 6'd23;
localparam [5:0] UIN_LM_PGCN = 6'd24;
localparam [5:0] UIN_JPGCN = 6'd25;
localparam [5:0] UIN_EVENTS = 6'd26;
localparam [5:0] UIN_ZERO27 = 6'd27;
localparam [5:0] UIN_BTN0 = 6'd28;
localparam [5:0] UIN_BTN1 = 6'd29;
localparam [5:0] UIN_BTN2 = 6'd30;
localparam [5:0] UIN_BTN3 = 6'd31;
localparam [5:0] UIN_SPRMW = 6'd32;
localparam [5:0] UOUT_J_DE = 6'd0;
localparam [5:0] UOUT_J_VTS = 6'd1;
localparam [5:0] UOUT_J_PGCN = 6'd2;
localparam [5:0] UOUT_RSV3 = 6'd3;
localparam [5:0] UOUT_J_TTN = 6'd4;
localparam [5:0] UOUT_J_PGN = 6'd5;
localparam [5:0] UOUT_J_PTT = 6'd6;
localparam [5:0] UOUT_J_CELL = 6'd7;
localparam [5:0] UOUT_SEEK_CELL = 6'd8;
localparam [5:0] UOUT_PULSE = 6'd9;
localparam [5:0] UOUT_BTNF_VAL = 6'd10;
localparam [5:0] UOUT_LF_PGCN = 6'd11;
localparam [5:0] UOUT_SPRM1 = 6'd12;
localparam [5:0] UOUT_SPRM2 = 6'd13;
localparam [5:0] UOUT_SPRM3 = 6'd14;
localparam [5:0] UOUT_SPRM8 = 6'd15;
localparam [5:0] UOUT_VM_DOM = 6'd16;
localparam [5:0] UOUT_VM_VTS = 6'd17;
localparam [5:0] UOUT_FLAGS = 6'd18;
localparam [5:0] UOUT_EVCLR = 6'd19;
localparam [5:0] UOUT_EVSET = 6'd20;
localparam integer UPB_JUMP = 0;
localparam integer UPB_SEEK = 1;
localparam integer UPB_REPLAY = 2;
localparam integer UPB_ADV = 3;
localparam integer UPB_BTNF = 4;
localparam integer UPB_LINKFAIL = 5;
localparam integer UPB_LFSTEP = 6;
localparam integer UPB_WARM = 7;
localparam integer UPB_TICKDONE = 8;
localparam integer UFL_BLK = 0;
localparam integer UFL_NAT = 2;
localparam integer UFL_USR = 3;
localparam integer UFL_WALK = 4;
localparam integer UEV_BOOT = 0;
localparam integer UEV_ERROR = 1;
localparam integer UEV_LOADED = 2;
localparam integer UEV_BTN = 3;
localparam integer UEV_CELLCMD = 4;
localparam integer UEV_PGCEND = 5;
localparam integer UEV_CHEDGE = 6;
localparam integer UEV_MENU = 7;
localparam integer UEV_TITLE = 8;
localparam integer UEV_CMENU = 9;
localparam integer UEV_RETURN = 10;
localparam integer UEV_N = 11;
localparam [7:0] UM_GPRM = 8'h00;
localparam [7:0] UM_GMODE = 8'h10;
localparam [7:0] UM_FB = 8'h11;
localparam [7:0] UM_CVM = 8'h12;
localparam [7:0] UM_SKIP_PRE = 8'h13;
localparam [7:0] UM_TT_RESOLVE = 8'h14;
localparam [7:0] UM_CHAIN = 8'h15;
localparam [7:0] UM_RSM_VTS = 8'h18;
localparam [7:0] UM_RSM_PGCN = 8'h19;
localparam [7:0] UM_RSM_CELL = 8'h1a;
localparam [7:0] UM_RSM_R4 = 8'h1b;
localparam [7:0] UM_RSM_R5 = 8'h1c;
localparam [7:0] UM_RSM_R6 = 8'h1d;
localparam [7:0] UM_RSM_R7 = 8'h1e;
localparam [7:0] UM_RSM_R8 = 8'h1f;
localparam [7:0] UM_DE_SEEN = 8'h20;
localparam [7:0] UM_DE_VTS = 8'h21;
localparam [7:0] UM_DE_PGCN = 8'h22;
localparam [7:0] UM_T0 = 8'h28;
localparam [7:0] UM_SPRMI = 8'h40;
localparam [2:0] UFB_NONE = 3'd0;
localparam [2:0] UFB_FP = 3'd1;
localparam [2:0] UFB_VTSM = 3'd2;
localparam [2:0] UFB_VTSM2 = 3'd3;
localparam [2:0] UFB_VMGM = 3'd4;
localparam [2:0] UFB_TITLE = 3'd5;
localparam [2:0] UFB_GAVEUP = 3'd6;
localparam [2:0] UFB_BOOTM = 3'd7;
// ==== END GENERATED ====

// ---------------------------------------------------------------- program ROM
(* ramstyle = "M10K" *) reg [39:0] rom [0:UC_DEPTH-1];
initial $readmemh("dvd/nav/nav_ucode.mem", rom);

// ---------------------------------------------------------------- data RAM
(* ramstyle = "M10K, no_rw_check" *) reg [15:0] dram [0:255];
integer di;
initial for (di = 0; di < 256; di = di + 1) dram[di] = 16'd0;

// ---------------------------------------------------------------- state
localparam [1:0] Q_BOOT = 2'd0, Q_RUN = 2'd1, Q_LD = 2'd2;
reg [1:0]  q;
reg [9:0]  pc;                   // the address of ir
reg [39:0] ir;
reg [15:0] rf [0:15];
reg [9:0]  stk [0:3];
reg [2:0]  sp;

wire [5:0]  op  = ir[39:34];
wire [3:0]  rd  = ir[33:30];
wire [3:0]  rs  = ir[29:26];
wire [3:0]  rt  = ir[25:22];
wire [15:0] imm = ir[21:6];
wire [5:0]  aux = ir[5:0];

wire [15:0] va = (rs == 4'd0) ? 16'd0 : rf[rs];
wire [15:0] vb = (rt == 4'd0) ? 16'd0 : rf[rt];
wire [15:0] vd = (rd == 4'd0) ? 16'd0 : rf[rd];
wire [15:0] vk = (aux[3:0] == 4'd0) ? 16'd0 : rf[aux[3:0]];

// ---------------------------------------------------------------- ALU
wire [15:0] alu_b   = (op == UOP_ALUI) ? imm : vb;
wire [16:0] sum     = {1'b0, va} + {1'b0, alu_b};
wire [16:0] dif     = {1'b0, va} - {1'b0, alu_b};
wire        a_eq    = (va == alu_b);
wire        a_lt    = dif[16];
reg  [15:0] alu_y;
always @* begin
    case (aux[3:0])
    UFN_ADD:  alu_y = sum[15:0];
    UFN_SUB:  alu_y = dif[15:0];
    UFN_AND:  alu_y = va & alu_b;
    UFN_OR:   alu_y = va | alu_b;
    UFN_XOR:  alu_y = va ^ alu_b;
    UFN_SHL:  alu_y = va << alu_b[3:0];
    UFN_SHR:  alu_y = va >> alu_b[3:0];
    UFN_SADD: alu_y = sum[16] ? 16'hFFFF : sum[15:0];
    UFN_SSUB: alu_y = dif[16] ? 16'd0 : dif[15:0];
    UFN_SEQ:  alu_y = {15'd0, a_eq};
    UFN_SNE:  alu_y = {15'd0, ~a_eq};
    UFN_SLTU: alu_y = {15'd0, a_lt};
    UFN_SGEU: alu_y = {15'd0, ~a_lt};
    default:  alu_y = 16'd0;
    endcase
end

// the DVD compare (libdvdnav eval_compare): rd = cmp(rk & 7, rs, rt)
wire [16:0] cdif = {1'b0, va} - {1'b0, vb};
wire        c_eq = (va == vb);
wire        c_lt = cdif[16];
reg         dcmp_y;
always @* begin
    case (vk[2:0])
    3'd1:    dcmp_y = |(va & vb);
    3'd2:    dcmp_y = c_eq;
    3'd3:    dcmp_y = ~c_eq;
    3'd4:    dcmp_y = ~c_lt;
    3'd5:    dcmp_y = ~c_lt & ~c_eq;
    3'd6:    dcmp_y = c_lt | c_eq;
    3'd7:    dcmp_y = c_lt;
    default: dcmp_y = 1'b1;
    endcase
end

// ---------------------------------------------------------------- branches
wire [15:0] br_b  = (op == UOP_BRI) ? {6'd0, rt, aux} : vb;
wire [16:0] bdif  = {1'b0, va} - {1'b0, br_b};
wire        b_eq  = (va == br_b);
wire        b_lt  = bdif[16];
reg         take;
always @* begin
    case (rd[1:0])
    2'd0:    take = b_eq;
    2'd1:    take = ~b_eq;
    2'd2:    take = b_lt;
    default: take = ~b_lt;
    endcase
    if (op == UOP_BB) take = (va[rt] == rd[0]);
end

wire [9:0] pc1  = pc + 10'd1;
wire [15:0] jrt = imm + va;
wire       is_ld = (op == UOP_LD) || (op == UOP_LDC) || (op == UOP_LDP);
wire       run  = (q == Q_RUN) && !restart;   // a mount aborts the program: no side effects
assign wev_req  = run && (op == UOP_WEV);
assign wev_mode = aux[0];
assign wev_take = wev_req && ev_valid;
wire       stall = (run && is_ld) || (wev_req && !ev_valid) || (q == Q_BOOT);

reg [9:0] npc;
always @* begin
    npc = pc1;
    case (op)
    UOP_BR, UOP_BRI, UOP_BB: if (take) npc = imm[9:0];
    UOP_JMP, UOP_CALL:       npc = imm[9:0];
    UOP_RET:                 npc = stk[sp - 3'd1];
    UOP_JR:                  npc = jrt[9:0];
    UOP_WEV:                 npc = imm[9:0] + {6'd0, ev_idx};
    default: ;
    endcase
end

// next fetch: the same word while stalled (and while finishing a load), else npc
wire [9:0] fetch_a = (q == Q_BOOT) ? 10'd0 : (q == Q_LD) ? pc1 : stall ? pc : npc;
always @(posedge clk) ir <= rom[fetch_a];

// ---------------------------------------------------------------- memories
wire [15:0] ea   = va + imm;
wire        d_we = run && (op == UOP_ST);
wire [7:0]  d_a  = ea[7:0];
reg  [15:0] d_q;
always @(posedge clk) begin
    if (d_we) dram[d_a] <= vd;
    d_q <= dram[d_a];
end
assign c_ra = ea[10:0];
assign p_ra = ea[6:0];
assign snoop_we = d_we;
assign snoop_a  = d_a;
assign snoop_d  = vd;

wire [5:0] in_sum = aux + va[5:0];
assign in_port  = in_sum;
assign out_stb  = run && ((op == UOP_OUT) || (op == UOP_OUTI));
assign out_port = aux;
assign out_data = (op == UOP_OUTI) ? imm : va;

// ---------------------------------------------------------------- the register write
reg        wr_en;
reg [15:0] wr_v;
always @* begin
    wr_en = 1'b0;
    wr_v  = alu_y;
    if (q == Q_LD) begin
        wr_en = 1'b1;
        wr_v  = (op == UOP_LD) ? d_q : (op == UOP_LDC) ? c_q : {8'd0, p_q};
    end else if (run) begin
        case (op)
        UOP_ALU, UOP_ALUI: wr_en = 1'b1;
        UOP_DCMP: begin wr_en = 1'b1; wr_v = {15'd0, dcmp_y}; end
        UOP_IN:   begin wr_en = 1'b1; wr_v = in_data; end
        default: ;
        endcase
    end
    if (rd == 4'd0) wr_en = 1'b0;
end

integer ri;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        q  <= Q_BOOT;
        pc <= 10'd0;
        sp <= 3'd0;
        for (ri = 0; ri < 16; ri = ri + 1) rf[ri] <= 16'd0;
        for (ri = 0; ri < 4; ri = ri + 1) stk[ri] <= 10'd0;
        tr_valid <= 1'b0; tr_kind <= 2'd0; tr_pc <= 10'd0; tr_addr <= 8'd0; tr_val <= 16'd0;
    end else begin
        tr_valid <= 1'b0;
        if (restart) begin
            q  <= Q_BOOT;
            pc <= 10'd0;
            sp <= 3'd0;
        end else begin
            if (wr_en) begin
                rf[rd] <= wr_v;
                tr_valid <= 1'b1; tr_kind <= 2'd0; tr_pc <= pc; tr_addr <= {4'd0, rd}; tr_val <= wr_v;
            end
            case (q)
            Q_BOOT: q <= Q_RUN;                      // ir <= rom[0] this edge
            Q_LD: begin q <= Q_RUN; pc <= pc1; end
            default: begin
                if (is_ld) q <= Q_LD;
                else if (!stall) begin
                    pc <= npc;
                    if (op == UOP_CALL) begin stk[sp[1:0]] <= pc1; sp <= sp + 3'd1; end
                    if (op == UOP_RET)  sp <= sp - 3'd1;
                end
                if (d_we) begin
                    tr_valid <= 1'b1; tr_kind <= 2'd1; tr_pc <= pc; tr_addr <= d_a; tr_val <= vd;
                end
                if (out_stb) begin
                    tr_valid <= 1'b1; tr_kind <= 2'd2; tr_pc <= pc; tr_addr <= {2'd0, aux}; tr_val <= out_data;
                end
                if (wev_take) begin
                    tr_valid <= 1'b1; tr_kind <= 2'd3; tr_pc <= pc; tr_addr <= {7'd0, aux[0]}; tr_val <= {12'd0, ev_idx};
                end
            end
            endcase
        end
    end
end

// for benches: parked at a wev with nothing to take
wire parked       = wev_req;
wire parked_wait  = wev_req && wev_mode;
wire can_dispatch = ev_valid;

endmodule
