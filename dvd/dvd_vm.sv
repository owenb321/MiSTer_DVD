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
//   key_resume      -> LinkRSM (only if the menu was entered via the Menu key)
//   key_title       -> VMGM Title menu (entry 2), the real-remote TITLE key;
//                      from a title also saves RSM (Menu/Select toggle back)
//   key_return      -> GoUp: in-domain jump to the loaded PGC's authored
//                      goup_pgcn (libdvdnav dvdnav_go_up); goup==0 = no-op
//   pgc_error       -> fallback chain (own VTSM -> best-menu-VOB VTSM ->
//                      VMGM Title -> resume/auto title), ported from the
//                      Phase-2/3 emu glue this module replaces.
//
// Every reader-wait event (vm_cell_cmd / vm_pgc_end) is ALWAYS answered with
// exactly one of: vm_adv (continue authored behaviour), vm_replay (replay
// the current cell, no flush - menu loops), seek_pulse, or jump_pulse.
//
// See docs/dvd_vm.md for the full design + frozen decode tables.

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
    input             key_resume,     // Select with no buttons armed
    input             key_title,      // B12: VMGM Title ("Top Menu") key
    input             key_return,     // B13: Return = GoUp (authored goup_pgcn)

    // Button activation (nav_pci)
    input      [63:0] btn_cmd,
    input             btn_cmd_valid,
    input      [5:0]  btn_sel,        // nav_pci live selection (SPRM8 shadow)
    input             btns_armed,
    output reg        btn_force,      // pulse: force nav_pci selection (SetHL_BTNN)
    output reg [5:0]  btn_force_val,

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
    output reg        vm_adv,         // pulse: reader continues authored behaviour
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

    output     [7:0]  dbg_state,
    // DVD-FORK DEBUG (Atmosfear wrong-title diagnosis): expose the scenario-
    // dispatch GPRMs so emu's DEBUG_OVERLAY can latch them at the game jump.
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
    output     [15:0] dbg_deadend
);

// =========================================================================
// Domains (DVD-VM encoding, matches the reader)
// =========================================================================
localparam [1:0] DOM_FP = 2'd0, DOM_VMGM = 2'd1, DOM_VTSM = 2'd2, DOM_TT = 2'd3;

// =========================================================================
// Command BRAM (2048 x 8, written by the reader at PGC load) + program map
// =========================================================================
// DVD-Video allows up to 128 pre + 128 post + 128 cell commands = 384 per PGC.
// 512 commands (4096 B) covers that with margin (was 256 = a >256-command menu
// dispatcher was skipped -> nav broke). Addresses widen: c_raddr/cmd_waddr [11:0],
// pc/blk_base/blk_end [8:0], reader total clamp raised to 511.
reg [7:0]  cmem [0:4095];
reg [7:0]  cmem_q;
reg [11:0] c_raddr;
always @(posedge clk) begin
    if (cmd_we) cmem[cmd_waddr] <= cmd_wdata;
    cmem_q <= cmem[c_raddr];
end

reg [7:0] pmem [0:127];
reg [7:0] pmem_q;
reg [6:0] pm_raddr;
always @(posedge clk) begin
    if (pm_we) pmem[pm_waddr] <= pm_wdata;
    pmem_q <= pmem[pm_raddr];
end

// =========================================================================
// Registers
// =========================================================================
reg [15:0] gprm [0:15];
reg [15:0] gprm_mode;          // bit per GPRM: 1 = counter mode (stored, no tick)
reg [15:0] sprm1, sprm2, sprm3, sprm4, sprm5, sprm6, sprm7, sprm8;
reg [15:0] sprm9, sprm10, sprm13;

assign sprm_astn  = sprm1[7:0];
assign sprm_spstn = sprm2[7:0];

// SPRM8 shadows the live nav_pci selection while buttons are armed (the
// D-pad moves selection outside the VM; compares like "if SPRM8==0x400"
// must see it). SetHL_BTNN / link-button fields write both sprm8 and (via
// btn_force) nav_pci.
//
// DVD-FORK FIX: `sprm8_frozen` — once a button is ACTIVATED, its command's
// dispatch must read the ACTIVATED button, not the live selection. Atmosfear's
// menu buttons are all LinkTailPGC -> the SAME PGC's POST reads HL_BTNN and
// dispatches; because the menu stays armed, the live btn_sel shadow wins, and
// if btn_sel drifts after activation (menu re-arm) the POST reads the wrong
// button (HW: highlight moves but every option -> the same clip). Freezing on
// activation makes sprm8_eff yield to the Fix-1-latched sprm8 for the dispatch;
// the next PGC load (pgc_loaded) clears it so the new menu's PRE sees the live
// shadow again. (LinkPGCN buttons already tore the menu down so btns_armed=0
// and this changes nothing for them.)
reg        sprm8_frozen;
wire [15:0] sprm8_eff = (btns_armed && !sprm8_frozen) ? {btn_sel, 10'd0} : sprm8;

// LFSR16 for the rnd op (taps 0/2/3/5 -> new MSB; steps ONCE per rnd so
// vectors match tools/dvd_vm_ref.py Lfsr bit-exactly). Seed 0xACE1.
reg [15:0] lfsr;
wire [15:0] lfsr_next = {(lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5]), lfsr[15:1]};

// Mount seed for the LFSR: rnd_seed forced nonzero (an all-zero LFSR locks up
// at 0). The tb drives rnd_seed=0xACE1 so all existing bit-exact vectors are
// unchanged; emu drives the free-running entropy counter.
wire [15:0] lfsr_seed = (|rnd_seed) ? rnd_seed : 16'hACE1;

// 1 Hz counter-mode GPRM tick, idle-gated: a sec_tick sets tick_pending, which
// is applied in V_IDLE (never during a command, so it can't race a GPRM write).
reg tick_pending;

// SPRM read mux (eval_reg, system half). Constants per libdvdnav vm_reset.
function [15:0] sprm_read(input [4:0] r);
    case (r)
    5'd0:  sprm_read = cfg_lang;   // player menu language (OSD "Player Language")
    5'd1:  sprm_read = sprm1;
    5'd2:  sprm_read = sprm2;
    5'd3:  sprm_read = sprm3;
    5'd4:  sprm_read = sprm4;
    5'd5:  sprm_read = sprm5;
    5'd6:  sprm_read = sprm6;
    5'd7:  sprm_read = sprm7;
    5'd8:  sprm_read = sprm8_eff;
    5'd9:  sprm_read = sprm9;
    5'd10: sprm_read = sprm10;
    5'd12: sprm_read = 16'h5553;   // 'US' parental country
    5'd13: sprm_read = sprm13;
    5'd14: sprm_read = 16'h0100;   // try pan&scan
    5'd15: sprm_read = 16'h7CFC;   // audio caps
    5'd16: sprm_read = cfg_lang;   // audio language preference (same OSD setting)
    5'd18: sprm_read = cfg_lang;   // subpicture language preference (same setting)
    5'd20: sprm_read = 16'h0001;   // region mask (region free)
    default: sprm_read = 16'd0;
    endcase
endfunction

// eval_reg: bit7 = system register, else GPRM (low 4 bits). Counter-mode
// GPRMs read their stored value (the 1 Hz tick is punted - documented).
function [15:0] eval_reg(input [7:0] r);
    eval_reg = r[7] ? sprm_read(r[4:0]) : gprm[r[3:0]];
endfunction

// =========================================================================
// Instruction register + field decode (bit numbering = vmcmd.c getbits:
// bit 63 = MSB of byte 0). All combinational off `ins`.
// =========================================================================
reg [63:0] ins;

wire [2:0] ins_type = ins[63:61];
wire       ins_imm  = ins[60];         // set-immediate flag
wire [3:0] set_op   = ins[59:56];
wire       cmp_imm  = ins[55];         // compare-immediate flag
wire [2:0] cmp_op   = ins[54:52];
wire [3:0] lnk_op   = ins[51:48];      // link/jump/special op field (types 0-3)

function cmp_eval(input [2:0] op, input [15:0] a, input [15:0] b);
    case (op)
    3'd1: cmp_eval = |(a & b);
    3'd2: cmp_eval = (a == b);
    3'd3: cmp_eval = (a != b);
    3'd4: cmp_eval = (a >= b);
    3'd5: cmp_eval = (a >  b);
    3'd6: cmp_eval = (a <= b);
    3'd7: cmp_eval = (a <  b);
    default: cmp_eval = 1'b1;          // op 0 = no compare = true
    endcase
endfunction

// Compare operand muxes per if-version
wire [15:0] cmpa_v1 = eval_reg(ins[39:32]);
wire [15:0] cmpb_v1 = cmp_imm ? ins[31:16] : eval_reg(ins[23:16]);
wire [15:0] cmpa_v2 = eval_reg(ins[15:8]);
wire [15:0] cmpb_v2 = eval_reg(ins[7:0]);
wire [15:0] cmpa_v3 = eval_reg(ins[47:40]);
wire [15:0] cmpb_v3 = cmp_imm ? ins[15:0] : eval_reg(ins[7:0]);
wire [15:0] cmpa_v4 = gprm[ins[51:48]];
wire [15:0] cmpb_v4 = cmp_imm ? ins[31:16] : eval_reg(ins[23:16]);
wire [15:0] cmpa_v5 = ins_imm ? gprm[ins[27:24]] : gprm[ins[35:32]];
wire [15:0] cmpb_v5 = ins_imm ? eval_reg(ins[23:16])
                              : (cmp_imm ? ins[31:16] : eval_reg(ins[23:16]));

wire cond_v1 = cmp_eval(cmp_op, cmpa_v1, cmpb_v1);
wire cond_v2 = cmp_eval(cmp_op, cmpa_v2, cmpb_v2);
wire cond_v3 = cmp_eval(cmp_op, cmpa_v3, cmpb_v3);
wire cond_v4 = cmp_eval(cmp_op, cmpa_v4, cmpb_v4);
wire cond_v5 = cmp_eval(cmp_op, cmpa_v5, cmpb_v5);

// Set operand muxes per set-version
wire [3:0]  s1_reg  = ins[35:32];
wire [3:0]  s1_reg2 = ins[19:16];
wire [15:0] s1_data = ins_imm ? ins[31:16] : eval_reg(ins[23:16]);
wire [3:0]  s2_reg  = ins[51:48];
wire [3:0]  s2_reg2 = ins[35:32];
wire [15:0] s2_data = ins_imm ? ins[47:32] : eval_reg(ins[39:32]);
wire [3:0]  s3_reg  = ins[51:48];
wire [3:0]  s3_reg2 = ins[19:16];
wire [15:0] s3_data = ins_imm ? ins[47:32] : eval_reg(ins[47:40]);

// Which set variant applies (types 3-6) and whether it executes
reg         set_do;
reg  [3:0]  set_sel_op;
reg  [3:0]  set_sel_reg, set_sel_reg2;
reg  [15:0] set_sel_data;
always @* begin
    set_do       = 1'b0;
    set_sel_op   = 4'd0;
    set_sel_reg  = 4'd0;
    set_sel_reg2 = 4'd0;
    set_sel_data = 16'd0;
    case (ins_type)
    3'd3: begin
        set_do = cond_v3 && (set_op != 4'd0);
        set_sel_op = set_op; set_sel_reg = s1_reg; set_sel_reg2 = s1_reg2;
        set_sel_data = s1_data;
    end
    3'd4: begin
        set_do = (set_op != 4'd0);              // set ALWAYS (decoder.c type 4)
        set_sel_op = set_op; set_sel_reg = s2_reg; set_sel_reg2 = s2_reg2;
        set_sel_data = s2_data;
    end
    3'd5, 3'd6: begin
        set_do = cond_v5 && (set_op != 4'd0);   // set only when cond (both types)
        set_sel_op = set_op; set_sel_reg = s3_reg; set_sel_reg2 = s3_reg2;
        set_sel_data = s3_data;
    end
    default: ;
    endcase
end

// Clamped add/sub (17-bit)
wire [16:0] add_raw   = {1'b0, gprm[set_sel_reg]} + {1'b0, set_sel_data};
wire [15:0] add_clamp = add_raw[16] ? 16'hFFFF : add_raw[15:0];
wire [16:0] sub_raw   = {1'b0, gprm[set_sel_reg]} - {1'b0, set_sel_data};
wire [15:0] sub_clamp = sub_raw[16] ? 16'd0 : sub_raw[15:0];

// Link/jump presence per type (mirrors eval_command routing). The link
// CONDITION is LATCHED in V_EXEC (link_cond_l) because decoder.c evaluates
// the compare BEFORE the set for types 1/2/3/5 - a set that modifies the
// compared register must not re-evaluate. Type 4 is the exception: its
// compare runs AFTER the set (eval_set_version_2 first), so V_LINKEV uses
// the LIVE cond_v4 (registers updated by then).
reg link_present, is_jump;
always @* begin
    link_present = 1'b0;
    is_jump      = 1'b0;
    case (ins_type)
    3'd1: begin
        if (ins_imm) begin
            link_present = 1'b1;
            is_jump      = 1'b1;
        end else
            link_present = (lnk_op != 4'd0);
    end
    3'd2: link_present = (lnk_op != 4'd0);
    3'd3: link_present = (lnk_op != 4'd0);
    3'd4, 3'd5, 3'd6: link_present = 1'b1;   // linksub slot always present
    default: ;
    endcase
end

reg  link_cond_l;                            // latched in V_EXEC
wire link_cond = (ins_type == 3'd4) ? cond_v4 : link_cond_l;
wire link_cond_pre = (ins_type == 3'd1) ? (ins_imm ? cond_v2 : cond_v1) :
                     (ins_type == 3'd2) ? cond_v2 :
                     (ins_type == 3'd3) ? cond_v3 :
                     (ins_type == 3'd5) ? cond_v5 : 1'b1;

// For types 4/5/6 the link part is always a SUB-instruction (bits 51:48 are
// set-op register bits there, not a link op) - force the subins route.
wire [3:0] lnk_op_eff = (ins_type >= 3'd4) ? 4'd1 : lnk_op;

// Link-subinstruction fields (decoder.c: linkop = LOW 5 BITS of byte 7)
wire [4:0] sub_op  = ins[4:0];
wire [5:0] sub_btn = ins[15:10];

// LinkNextPGC/PrevPGC/GoUpPGC target
wire [15:0] pgc_nav_target = (sub_op == 5'd10) ? next_pgcn :
                            (sub_op == 5'd11) ? prev_pgcn : goup_pgcn;


// =========================================================================
// FSM
// =========================================================================
localparam V_IDLE   = 4'd0;
localparam V_FETCH  = 4'd1;    // 8-byte read from cmem -> ins
localparam V_EXEC   = 4'd2;    // cond + simple set writeback; route
localparam V_ALU    = 4'd3;    // serial mul/div/mod/rnd
localparam V_ALUWB  = 4'd4;    // ALU writeback
localparam V_LINKEV = 4'd5;    // evaluate the link/jump part -> action
localparam V_PGSCAN = 4'd6;    // program map: find cur_pg (2 cyc/entry)
localparam V_PMRD   = 4'd7;    // program map: pm[pg_tgt-1] -> seek cell
localparam V_PMRD2  = 4'd8;
localparam V_NEXT   = 4'd9;    // pc advance / block fall-through
localparam V_WAIT   = 4'd10;   // jump issued: await pgc_loaded / pgc_error

reg [3:0] state;

// Block context
localparam [1:0] BLK_PRE = 2'd0, BLK_POST = 2'd1, BLK_CELL = 2'd2, BLK_BTN = 2'd3;
reg [1:0] blk;
reg [8:0] pc;                  // command index (8-byte units; up to 512)
reg [8:0] blk_base;
reg [8:0] blk_end;             // one past the last command (up to 512)

wire wait_verdict = (blk == BLK_CELL || blk == BLK_POST);  // reader is waiting

// Natural-jump provenance export (tail-drain Phase B): blk updates non-blocking
// in the same cycle a dispatch arm raises jump_pulse, so on the pulse's OUTPUT
// cycle this reads the dispatching block - the executing CELL/POST for command
// jumps, BLK_BTN for every V_IDLE event arm (they force it, see below).
//
// nat_src = WHO STARTED the executing command chain: 1 only when the V_IDLE
// dispatch was ev_cellcmd / ev_pgcend (the reader-initiated natural events),
// 0 for every user/boot/load event. It is PRESERVED across block transitions,
// so a POST reached through a BUTTON's LinkTailPGC keeps nat_src=0 and its
// jump executes immediately - blk alone reads BLK_POST there and mistagged
// the jump natural, which tail-drain-gated Tomb Raider's Select scene skip
// (the whole VBUF played out before the skip landed; VLC skips instantly).
// A POST reached from a PGC end / a timeout cell command keeps nat_src=1.
reg nat_src;
assign vm_from_wait = wait_verdict && nat_src;

reg [3:0]  fetch_i;
reg [12:0] fuse;               // instructions executed this activation
reg [6:0]  chain;              // VM-issued jumps this activation

// Pending events
reg ev_boot, ev_loaded, ev_error, ev_cellcmd, ev_pgcend, ev_btn;
reg ev_menu, ev_resume, ev_title, ev_return;
reg [7:0]  ev_cellcmd_nr;
reg [63:0] ev_btn_cmd;
reg nav_ready_d;

// VM's view of where it is / what it asked for
reg [1:0] vm_dom;
reg [7:0] vm_vts;
// VTS for an IN-DOMAIN PGC link (LinkPGCN / LinkTopPGC / LinkNext/Prev/GoUpPGC).
// In a TITLE the VTS lives in the reader (cur_vts), NOT vm_vts: a preceding
// JumpTT sets vm_vts=0 (the VTS is resolved in the reader), so passing vm_vts
// would ship jump_vts==0 and the reader would treat it as "load VTS 0" -> a
// mis-resolve/dead-end. This bit the multi-PGC GAME titles (Tomb Raider) whose
// choices return to an earlier PGC via a cross-PGC LinkPGCN. Same fix that was
// applied to JumpVTS_TT (the "Scene It boot bug"). In a MENU domain vm_vts is
// authoritative (0 for VMGM, the menu VTS for VTSM), so keep it there.
wire [7:0] link_jump_vts = (vm_dom == DOM_TT) ? cur_vts : vm_vts;
reg       skip_pre;            // next pgc_loaded: don't run PRE (RSM resume)
reg       tt_resolve;          // JumpTT issued: latch SPRM5 <= res_ttn on load
// TRUE while we reached the current menu via the Menu key FROM a playing title
// (title -> CallSS VTSM Root). Only then does a second Menu press LinkRSM back to
// the title (the movie menu<->title toggle). Cleared once a title actually plays.
// On a menu we DID NOT enter via the Menu key (e.g. Trivial Pursuit Star Wars,
// whose game screens are authored menus and whose RSM points at the boot FP intro),
// a Menu press must re-invoke the Root menu, NOT resume the (non-resumable) intro.
reg       came_via_menukey;
// DEBUG (symptom-1): latch the first 0-cell-menu-no-PRE dead-end {vts,pgcn}.
reg [7:0]  deadend_vts;
reg [15:0] deadend_pgcn;   // 16-bit: PGCN is a 15-bit DVD field
reg       deadend_seen;

// RSM state (CallSS saves, LinkRSM restores). rsm_vts==0 = no resume info.
reg [7:0]  rsm_vts, rsm_cell;
reg [15:0] rsm_pgcn;         // 16-bit: PGCN is a 15-bit DVD field
reg [15:0] rsm_r4, rsm_r5, rsm_r6, rsm_r7, rsm_r8;

// Fallback chain (ported from the Phase-2/3 emu glue). FB_TITLE also tags
// command-issued title jumps: if one fails, retry once with the auto title.
localparam [2:0] FB_NONE = 3'd0, FB_FP = 3'd1, FB_VTSM = 3'd2, FB_VTSM2 = 3'd3,
                 FB_VMGM = 3'd4, FB_TITLE = 3'd5, FB_GAVEUP = 3'd6;
reg [2:0] fb;

// Serial ALU (mul: MSB-first shift-add; div/mod/rnd: restoring divide)
reg [3:0]  alu_op;
reg [3:0]  alu_reg;
reg [31:0] alu_acc;            // mul accumulator
reg [16:0] alu_rem;            // divider remainder
reg [15:0] alu_a, alu_b, alu_b_orig;
reg [15:0] alu_quot;
reg [4:0]  alu_cnt;

wire [16:0] div_shift = {alu_rem[15:0], alu_a[15]};
wire [17:0] div_sub   = {1'b0, div_shift} - {2'b00, alu_b_orig};

// Program-map walk scratch
reg [7:0]  pg_i;
reg [7:0]  cur_pg;
reg [7:0]  pg_tgt;
reg [9:0]  link_ptt;       // LinkPTTN part in flight (0 = LinkPGN / none): if the
                           // part overflows the current PGC (V_PMRD), fall back to
                           // the exact VTS_PTT_SRPT resolve (cross-PGC LinkPTT).
reg        pm_stage;
reg [1:0]  pg_ph;         // V_PGSCAN phase: pmem_q is a REGISTERED read, so it
                          // needs a settle cycle before pg_hit is valid (see V_PGSCAN)
wire       pg_hit   = (pmem_q != 8'd0) &&
                      ({1'b0, pmem_q} <= {1'b0, cur_cell} + 9'd1);
wire [7:0] pg_final = pg_hit ? (pg_i + 8'd1) : cur_pg;

// Wait timeout (~0.62 s @ 27 MHz)
reg [23:0] wait_tmr;

assign dbg_state = {came_via_menukey, fb, state};   // bit7 = came_via_menukey
assign dbg_g3    = gprm[3];
assign dbg_g14_9 = {gprm[14][7:0], gprm[9][7:0]};
assign dbg_rsm   = {rsm_vts, rsm_pgcn[7:0]};   // probe keeps the low byte
assign dbg_deadend = {deadend_vts, deadend_pgcn[7:0]};

integer gi;

// =========================================================================
// Main FSM
// =========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= V_IDLE;
        for (gi = 0; gi < 16; gi = gi + 1) gprm[gi] <= 16'd0;
        gprm_mode <= 16'd0;
        sprm1 <= 16'd15; sprm2 <= 16'd62; sprm3 <= 16'd1;
        sprm4 <= 16'd1;  sprm5 <= 16'd1;  sprm6 <= 16'd0;
        sprm7 <= 16'd1;  sprm8 <= 16'h0400;
        sprm8_frozen <= 1'b0;
        sprm9 <= 16'd0;  sprm10 <= 16'd0; sprm13 <= 16'd15;
        lfsr  <= lfsr_seed;
        tick_pending <= 1'b0;
        ins   <= 64'd0;
        blk   <= BLK_PRE;
        nat_src <= 1'b0;
        pc <= 9'd0; blk_base <= 9'd0; blk_end <= 9'd0;
        fetch_i <= 4'd0;
        fuse <= 13'd0; chain <= 7'd0;
        ev_boot <= 1'b0; ev_loaded <= 1'b0; ev_error <= 1'b0;
        ev_cellcmd <= 1'b0; ev_pgcend <= 1'b0; ev_btn <= 1'b0;
        ev_menu <= 1'b0; ev_resume <= 1'b0;
        ev_cellcmd_nr <= 8'd0;
        ev_btn_cmd <= 64'd0;
        nav_ready_d <= 1'b0;
        vm_dom <= DOM_TT; vm_vts <= 8'd0;
        skip_pre <= 1'b0;
        tt_resolve <= 1'b0;
        came_via_menukey <= 1'b0;
        deadend_vts <= 8'd0; deadend_pgcn <= 16'd0; deadend_seen <= 1'b0;
        rsm_vts <= 8'd0; rsm_pgcn <= 16'd0; rsm_cell <= 8'd0;
        rsm_r4 <= 16'd0; rsm_r5 <= 16'd0; rsm_r6 <= 16'd0;
        rsm_r7 <= 16'd0; rsm_r8 <= 16'd0;
        fb <= FB_NONE;
        alu_op <= 4'd0; alu_reg <= 4'd0; alu_acc <= 32'd0; alu_rem <= 17'd0;
        alu_a <= 16'd0; alu_b <= 16'd0; alu_b_orig <= 16'd0;
        alu_quot <= 16'd0; alu_cnt <= 5'd0;
        pg_i <= 8'd0; cur_pg <= 8'd1; pg_tgt <= 8'd1; pm_stage <= 1'b0; pg_ph <= 2'd0;
        link_ptt <= 10'd0;
        link_cond_l <= 1'b0;
        wait_tmr <= 24'd0;
        c_raddr <= 12'd0; pm_raddr <= 7'd0;
        jump_pulse <= 1'b0; jump_domain <= DOM_TT;
        jump_vts <= 8'd0; jump_pgcn <= 16'd0; jump_entry <= 4'd0;
        jump_ttn <= 7'd0; jump_pgn <= 8'd0; jump_cell <= 8'd0; jump_ptt <= 10'd0;
        seek_pulse <= 1'b0; seek_cell <= 8'd0;
        vm_replay <= 1'b0; vm_adv <= 1'b0;
        btn_force <= 1'b0; btn_force_val <= 6'd1;
    end else begin
        // one-cycle pulses
        jump_pulse <= 1'b0;
        // jump_ptt is only sampled by the reader on the jump_pulse cycle, so
        // default it to 0 (= ptt[0]) every cycle; the JumpVTS_PTT / LinkPTTN
        // sites override it with the requested part on their pulse cycle.
        jump_ptt   <= 10'd0;
        seek_pulse <= 1'b0;
        vm_replay  <= 1'b0;
        vm_adv     <= 1'b0;
        btn_force  <= 1'b0;

        // 1 Hz seconds tick -> pending (applied in V_IDLE, race-free vs GPRM
        // writes). Free-running whether or not the VM is busy; one flag is
        // enough since commands finish in << 1 s.
        if (sec_tick) tick_pending <= 1'b1;

        nav_ready_d <= nav_ready;

        // ---- event latching (any state; the FSM consumes by priority) ---
        if (enable) begin
            if (nav_ready && !nav_ready_d)  ev_boot   <= 1'b1;
            if (pgc_loaded)                 ev_loaded <= 1'b1;
            if (pgc_error)                  ev_error  <= 1'b1;
            if (vm_cell_cmd) begin
                ev_cellcmd    <= 1'b1;
                ev_cellcmd_nr <= cell_cmd_nr;
            end
            if (vm_pgc_end)                 ev_pgcend <= 1'b1;
            if (btn_cmd_valid) begin
                ev_btn     <= 1'b1;
                ev_btn_cmd <= btn_cmd;
                // DVD-FORK FIX: durably latch the ACTIVATED button into SPRM8
                // (HL_BTNN). sprm8_eff only reflects btn_sel while btns_armed;
                // but a menu's dispatch PRE (e.g. TP Star Wars "g15 = HL_BTNN;
                // if g15==0x400 ...", Atmosfear's GPRM jump table) runs AFTER the
                // menu tears down (btns_armed low), so without this it read the
                // reset default 0x0400 = button 1 and EVERY selection collapsed to
                // option 1. Mirrors libdvdnav vm.c (HL_BTNN_REG = data1 << 10).
                sprm8 <= {btn_sel, 10'd0};
                sprm8_frozen <= 1'b1;   // dispatch reads this latch, not the live shadow
            end
            // a new PGC load re-opens the live-selection shadow for its PRE
            if (pgc_loaded) sprm8_frozen <= 1'b0;
            if (key_menu)                   ev_menu   <= 1'b1;
            if (key_resume)                 ev_resume <= 1'b1;
            if (key_title)                  ev_title  <= 1'b1;
            if (key_return)                 ev_return <= 1'b1;
        end

        // ---- mount: vm_reset --------------------------------------------
        if (start) begin
            for (gi = 0; gi < 16; gi = gi + 1) gprm[gi] <= 16'd0;
            gprm_mode <= 16'd0;
            sprm1 <= 16'd15; sprm2 <= 16'd62; sprm3 <= 16'd1;
            sprm4 <= 16'd1;  sprm5 <= 16'd1;  sprm6 <= 16'd0;
            sprm7 <= 16'd1;  sprm8 <= 16'h0400;
            sprm8_frozen <= 1'b0;
            sprm9 <= 16'd0;  sprm10 <= 16'd0; sprm13 <= 16'd15;
            lfsr  <= lfsr_seed;         // re-seed rnd from the mount-time entropy
            tick_pending <= 1'b0;
            rsm_vts <= 8'd0;
            vm_dom <= DOM_TT; vm_vts <= 8'd0;
            skip_pre <= 1'b0;
            tt_resolve <= 1'b0;
            came_via_menukey <= 1'b0;
            deadend_vts <= 8'd0; deadend_pgcn <= 16'd0; deadend_seen <= 1'b0;
            fb <= FB_NONE;
            fuse <= 13'd0; chain <= 7'd0;
            nat_src <= 1'b0;
            ev_boot <= 1'b0; ev_loaded <= 1'b0; ev_error <= 1'b0;
            ev_cellcmd <= 1'b0; ev_pgcend <= 1'b0; ev_btn <= 1'b0;
            ev_menu <= 1'b0; ev_resume <= 1'b0; ev_title <= 1'b0;
            ev_return <= 1'b0;
            state <= V_IDLE;
        end else begin
            case (state)

            // ------------------------------------------------------------
            V_IDLE: begin
                fetch_i <= 4'd0;
                // DVD-game entropy, applied only in idle (no command is writing
                // a GPRM/LFSR here, so these can't race a command write):
                //  - counter-mode GPRMs +1 per elapsed second (wall clock).
                //  - fold user-input timing into the rnd LFSR so rnd varies
                //    per play even for discs (e.g. Scene It HP) that seed only
                //    from rnd. See docs/dvd_vm.md "DVD-game entropy".
                if (tick_pending) begin
                    for (gi = 0; gi < 16; gi = gi + 1)
                        if (gprm_mode[gi]) gprm[gi] <= gprm[gi] + 16'd1;
                    tick_pending <= 1'b0;
                end
                if (entropy_stir) lfsr <= lfsr ^ entropy_val;
                if (!enable) begin
                    ev_boot <= 1'b0; ev_loaded <= 1'b0; ev_error <= 1'b0;
                    ev_btn  <= 1'b0; ev_menu <= 1'b0; ev_resume <= 1'b0;
                    ev_title <= 1'b0; ev_return <= 1'b0;
                    // a reader wait must still be released (O[1] flipped off
                    // mid-flight; the reader also has its own timeout)
                    if (ev_cellcmd || ev_pgcend) begin
                        ev_cellcmd <= 1'b0; ev_pgcend <= 1'b0;
                        vm_adv <= 1'b1;
                    end
                end else if (ev_boot) begin
                    // BOOT: run the First Play PGC
                    ev_boot <= 1'b0;
                    fuse <= 13'd0; chain <= 7'd0;
                    fb <= FB_FP;
                    vm_dom <= DOM_FP; vm_vts <= 8'd0;
                    jump_domain <= DOM_FP;
                    jump_vts <= 8'd0; jump_pgcn <= 16'd0; jump_entry <= 4'd0;
                    jump_ttn <= 7'd0; jump_pgn <= 8'd0; jump_cell <= 8'd0;
                    jump_pulse <= 1'b1;
                    blk <= BLK_BTN;      // event jump: never "natural" provenance
                    nat_src <= 1'b0;
                    wait_tmr <= 24'd0;
                    state <= V_WAIT;
                end else if (ev_error) begin
                    // FALLBACK CHAIN (a jump failed). Ordering per Phase-2/3:
                    // menu jumps: own VTSM -> best-menu-VOB VTSM -> VMGM
                    // Title -> resume/auto. FP or title jumps: auto title.
                    ev_error  <= 1'b0;
                    ev_loaded <= 1'b0;
                    // Error-fallback jumps are recovery events, never "natural"
                    // transitions - a stale CELL/POST blk here (failed POST jump)
                    // would be harmless (its VBUF already drained), but classify
                    // uniformly with the other event arms.
                    blk       <= BLK_BTN;
                    nat_src   <= 1'b0;
                    if (fb == FB_GAVEUP) begin
                        fb <= FB_NONE;            // never loop on errors
                    end else if (fb == FB_VTSM && best_menu_vts != 8'd0 &&
                                 best_menu_vts != vm_vts) begin
                        fb <= FB_VTSM2;
                        vm_dom <= DOM_VTSM; vm_vts <= best_menu_vts;
                        jump_domain <= DOM_VTSM;
                        jump_vts <= best_menu_vts; jump_pgcn <= 16'd0;
                        jump_entry <= 4'd3;       // Root
                        jump_ttn <= 7'd0; jump_pgn <= 8'd0; jump_cell <= 8'd0;
                        jump_pulse <= 1'b1;
                        wait_tmr <= 24'd0;
                        state <= V_WAIT;
                    end else if (fb == FB_VTSM || fb == FB_VTSM2) begin
                        fb <= FB_VMGM;
                        vm_dom <= DOM_VMGM; vm_vts <= 8'd0;
                        jump_domain <= DOM_VMGM;
                        jump_vts <= 8'd0; jump_pgcn <= 16'd0;
                        jump_entry <= 4'd2;       // Title menu
                        jump_ttn <= 7'd0; jump_pgn <= 8'd0; jump_cell <= 8'd0;
                        jump_pulse <= 1'b1;
                        wait_tmr <= 24'd0;
                        state <= V_WAIT;
                    end else if (fb == FB_VMGM && rsm_vts != 8'd0) begin
                        // no menus at all: resume the title
                        fb <= FB_GAVEUP;
                        sprm4 <= rsm_r4; sprm5 <= rsm_r5; sprm6 <= rsm_r6;
                        sprm7 <= rsm_r7; sprm8 <= rsm_r8;
                        vm_dom <= DOM_TT; vm_vts <= rsm_vts;
                        jump_domain <= DOM_TT;
                        jump_vts <= rsm_vts; jump_pgcn <= rsm_pgcn;
                        jump_entry <= 4'd0; jump_ttn <= 7'd0;
                        jump_pgn <= 8'd0; jump_cell <= rsm_cell;
                        jump_pulse <= 1'b1;
                        skip_pre <= 1'b1;
                        wait_tmr <= 24'd0;
                        state <= V_WAIT;
                    end else begin
                        // FP / title / VMGM-without-resume failed: auto title
                        fb <= FB_GAVEUP;
                        vm_dom <= DOM_TT; vm_vts <= auto_vts;
                        jump_domain <= DOM_TT;
                        jump_vts <= auto_vts; jump_pgcn <= 16'd1;
                        jump_entry <= 4'd0; jump_ttn <= 7'd0;
                        jump_pgn <= 8'd0; jump_cell <= 8'd0;
                        jump_pulse <= 1'b1;
                        wait_tmr <= 24'd0;
                        state <= V_WAIT;
                    end
                end else if (ev_loaded) begin
                    // A PGC finished loading while idle (reader-internal
                    // next_pgcn advance, or a load that raced our idle):
                    // run its PRE block.
                    ev_loaded  <= 1'b0;
                    ev_cellcmd <= 1'b0;   // stale waits died with the old PGC
                    ev_pgcend  <= 1'b0;
                    ev_btn     <= 1'b0;
                    nat_src    <= 1'b0;   // fresh PGC's PRE: not a natural chain
                    // A title is playing again -> forget any menu-key toggle state
                    // (a later Menu press should re-invoke the Root menu, not resume
                    // whatever the boot FP CallSS happened to leave in RSM).
                    if (vm_dom == DOM_TT) came_via_menukey <= 1'b0;
                    if (skip_pre) begin
                        skip_pre <= 1'b0;
                        fb <= FB_NONE;
                    end else if (nr_pre != 8'd0) begin
                        fb <= FB_NONE;
                        blk <= BLK_PRE;
                        blk_base <= 9'd0;
                        blk_end  <= nr_pre;
                        pc       <= 8'd0;
                        state    <= V_FETCH;
                    end else begin
                        if (cell_count == 8'd0 && vm_dom != DOM_TT) begin
                            // 0-cell menu PGC with no PRE = a dead-end stub (its
                            // nr_pre arrived as 0). Recover through the MENU fallback
                            // chain (fb=FB_VTSM -> ... -> VMGM Title menu), NOT the
                            // auto-title: on a single-VTS game disc (TP Star Wars)
                            // the auto-title = VTS1/title1 = the FP copyright, so a
                            // dead-end here replays the copyright ("question completes
                            // -> copyright"). Latch which PGC for the overlay.
                            fb <= FB_VTSM;
                            ev_error <= 1'b1;
                            if (!deadend_seen) begin
                                deadend_seen <= 1'b1;
                                deadend_vts  <= cur_vts;
                                deadend_pgcn <= cur_pgcn;
                            end
                        end else
                            fb <= FB_NONE;
                    end
                end else if (ev_btn) begin
                    ev_btn <= 1'b0;
                    fuse <= 13'd0; chain <= 7'd0;
                    ins <= ev_btn_cmd;
                    blk <= BLK_BTN;
                    // USER activation: the whole chain it starts is non-natural,
                    // INCLUDING a POST reached via its LinkTailPGC (the Tomb
                    // Raider Select scene-skip shape - must execute instantly).
                    nat_src <= 1'b0;
                    blk_base <= 9'd0; blk_end <= 9'd1; pc <= 9'd0;
                    state <= V_EXEC;
                end else if (ev_cellcmd) begin
                    ev_cellcmd <= 1'b0;
                    fuse <= 13'd0; chain <= 7'd0;
                    nat_src <= 1'b1;      // reader-initiated: natural chain
                    if (ev_cellcmd_nr == 8'd0 || ev_cellcmd_nr > nr_cell) begin
                        vm_adv <= 1'b1;
                    end else begin
                        blk <= BLK_CELL;
                        blk_base <= nr_pre + nr_post + ev_cellcmd_nr - 8'd1;
                        blk_end  <= nr_pre + nr_post + ev_cellcmd_nr;
                        pc       <= nr_pre + nr_post + ev_cellcmd_nr - 8'd1;
                        state    <= V_FETCH;
                    end
                end else if (ev_pgcend) begin
                    ev_pgcend <= 1'b0;
                    fuse <= 13'd0; chain <= 7'd0;
                    nat_src <= 1'b1;      // reader-initiated: natural chain
                    if (nr_post != 8'd0) begin
                        blk <= BLK_POST;
                        blk_base <= nr_pre;
                        blk_end  <= nr_pre + nr_post;
                        pc       <= nr_pre;
                        state    <= V_FETCH;
                    end else begin
                        vm_adv <= 1'b1;   // no post: authored next_pgcn/still
                    end
                end else if (ev_menu) begin
                    ev_menu <= 1'b0;
                    fuse <= 13'd0; chain <= 7'd0;
                    blk  <= BLK_BTN;     // user-key jump: never "natural" provenance
                    nat_src <= 1'b0;
                    if (menu_active || vm_dom != DOM_TT) begin
                        // Menu key while a MENU is up. Two cases:
                        if (came_via_menukey && rsm_vts != 8'd0) begin
                            // (a) We reached this menu by pressing Menu from a playing
                            // title -> a second Menu press toggles BACK to the title
                            // (the movie menu<->title behaviour). LinkRSM.
                            sprm4 <= rsm_r4; sprm5 <= rsm_r5; sprm6 <= rsm_r6;
                            sprm7 <= rsm_r7; sprm8 <= rsm_r8;
                            vm_dom <= DOM_TT; vm_vts <= rsm_vts;
                            jump_domain <= DOM_TT;
                            jump_vts <= rsm_vts; jump_pgcn <= rsm_pgcn;
                            jump_entry <= 4'd0; jump_ttn <= 7'd0;
                            jump_pgn <= 8'd0; jump_cell <= rsm_cell;
                            jump_pulse <= 1'b1;
                            skip_pre <= 1'b1;
                            fb <= FB_NONE;
                            wait_tmr <= 24'd0;
                            state <= V_WAIT;
                        end else begin
                            // (b) We did NOT enter this menu via the Menu key (e.g.
                            // Trivial Pursuit Star Wars: the game screens are authored
                            // menus, and RSM points at the boot FP copyright/intro).
                            // Resuming RSM here would replay the copyright, so instead
                            // RE-INVOKE the Root menu (menu_call(Root) semantics), with
                            // the FB_VTSM fallback chain to a real menu.
                            vm_dom <= DOM_VTSM; vm_vts <= cur_vts;
                            jump_domain <= DOM_VTSM;
                            jump_vts <= cur_vts; jump_pgcn <= 16'd0;
                            jump_entry <= 4'd3;   // Root
                            jump_ttn <= 7'd0; jump_pgn <= 8'd0; jump_cell <= 8'd0;
                            jump_pulse <= 1'b1;
                            fb <= FB_VTSM;
                            wait_tmr <= 24'd0;
                            state <= V_WAIT;
                        end
                    end else begin
                        // Menu key in a title: synthesized CallSS VTSM Root. Remember
                        // we came here via the Menu key so a second press resumes.
                        rsm_vts  <= cur_vts;
                        rsm_pgcn <= cur_pgcn;
                        rsm_cell <= cur_cell;
                        rsm_r4 <= sprm4; rsm_r5 <= sprm5; rsm_r6 <= sprm6;
                        rsm_r7 <= sprm7; rsm_r8 <= sprm8_eff;
                        came_via_menukey <= 1'b1;
                        vm_dom <= DOM_VTSM; vm_vts <= cur_vts;
                        jump_domain <= DOM_VTSM;
                        jump_vts <= cur_vts; jump_pgcn <= 16'd0;
                        jump_entry <= 4'd3;   // Root
                        jump_ttn <= 7'd0; jump_pgn <= 8'd0; jump_cell <= 8'd0;
                        jump_pulse <= 1'b1;
                        fb <= FB_VTSM;
                        wait_tmr <= 24'd0;
                        state <= V_WAIT;
                    end
                end else if (ev_title) begin
                    // TITLE ("Top Menu") key: jump to the VMGM Title menu
                    // (entry 2) from anywhere - the real-remote TITLE button.
                    // From a playing title, save RSM + set came_via_menukey so
                    // Menu/Select toggle back to the movie, exactly like the
                    // Menu key. From a menu, jump without touching RSM or the
                    // toggle flag: a disc-driven menu's RSM is the boot
                    // trampoline (see the ev_resume gate above) and must not
                    // be re-blessed as a user destination. fb=FB_VMGM: if the
                    // disc authors no VMGM Title entry the chain falls to
                    // resume/auto-title.
                    ev_title <= 1'b0;
                    fuse <= 13'd0; chain <= 7'd0;
                    blk  <= BLK_BTN;     // user-key jump: never "natural" provenance
                    nat_src <= 1'b0;
                    if (!menu_active && vm_dom == DOM_TT) begin
                        rsm_vts  <= cur_vts;
                        rsm_pgcn <= cur_pgcn;
                        rsm_cell <= cur_cell;
                        rsm_r4 <= sprm4; rsm_r5 <= sprm5; rsm_r6 <= sprm6;
                        rsm_r7 <= sprm7; rsm_r8 <= sprm8_eff;
                        came_via_menukey <= 1'b1;
                    end
                    vm_dom <= DOM_VMGM; vm_vts <= 8'd0;
                    jump_domain <= DOM_VMGM;
                    jump_vts <= 8'd0; jump_pgcn <= 16'd0;
                    jump_entry <= 4'd2;   // Title menu
                    jump_ttn <= 7'd0; jump_pgn <= 8'd0; jump_cell <= 8'd0;
                    jump_pulse <= 1'b1;
                    fb <= FB_VMGM;
                    wait_tmr <= 24'd0;
                    state <= V_WAIT;
                end else if (ev_return) begin
                    // RETURN key = GoUp (libdvdnav dvdnav_go_up): in-domain
                    // jump to the loaded PGC's authored goup_pgcn - the menu
                    // hierarchy's "one level up" pointer. Mirrors the
                    // LinkGoUpPGC command exec exactly; goup_pgcn==0 (no
                    // authored parent - most movie titles) = a strict no-op,
                    // same as a real player's RETURN.
                    ev_return <= 1'b0;
                    fuse <= 13'd0; chain <= 7'd0;
                    blk  <= BLK_BTN;     // user-key jump: never "natural" provenance
                    nat_src <= 1'b0;
                    if (goup_pgcn != 8'd0) begin
                        jump_domain <= vm_dom;
                        jump_vts <= link_jump_vts;   // cur_vts in a title (see decl)
                        jump_pgcn <= goup_pgcn;
                        jump_entry <= 4'd0; jump_ttn <= 7'd0;
                        jump_pgn <= 8'd0; jump_cell <= 8'd0;
                        jump_pulse <= 1'b1;
                        fb <= FB_NONE;
                        wait_tmr <= 24'd0;
                        state <= V_WAIT;
                    end
                end else if (ev_resume) begin
                    ev_resume <= 1'b0;
                    fuse <= 13'd0; chain <= 7'd0;
                    blk  <= BLK_BTN;     // user-key jump: never "natural" provenance
                    nat_src <= 1'b0;
                    // Resume (Select with no buttons armed) is gated on
                    // came_via_menukey, same as the Menu-key toggle above: RSM
                    // is only a valid USER destination if the user put us in
                    // this menu (Menu from a playing title). A disc-driven
                    // CallSS (e.g. the boot FP trampoline) also fills RSM, but
                    // that resume point is the trampoline title itself - a
                    // dispatch stub that is not resumable. Cluedo: FP JumpTT 1
                    // -> VTS1 PGC1 PRE CallSS VMGM (copyright/logos/intro), so
                    // Select during the intro used to RSM into VTS1 PGC1 cell 1
                    // = the "Please Wait, Processing" card, whose PGC has no
                    // POST and no next -> permanent park. A real player treats
                    // Enter with no armed buttons as a no-op; now we do too.
                    if (came_via_menukey && rsm_vts != 8'd0 &&
                        (menu_active || vm_dom != DOM_TT)) begin
                        sprm4 <= rsm_r4; sprm5 <= rsm_r5; sprm6 <= rsm_r6;
                        sprm7 <= rsm_r7; sprm8 <= rsm_r8;
                        vm_dom <= DOM_TT; vm_vts <= rsm_vts;
                        jump_domain <= DOM_TT;
                        jump_vts <= rsm_vts; jump_pgcn <= rsm_pgcn;
                        jump_entry <= 4'd0; jump_ttn <= 7'd0;
                        jump_pgn <= 8'd0; jump_cell <= rsm_cell;
                        jump_pulse <= 1'b1;
                        skip_pre <= 1'b1;
                        fb <= FB_NONE;
                        wait_tmr <= 24'd0;
                        state <= V_WAIT;
                    end
                end
            end

            // ------------------------------------------------------------
            // Fetch ins = cmem[pc*8 .. pc*8+7] (sync BRAM: address leads
            // capture by one cycle; 10 cycles total).
            V_FETCH: begin
                c_raddr <= {pc, 3'd0} + {8'd0, fetch_i};
                // sync BRAM: address at edge N -> cmem_q valid at edge N+2,
                // so byte 0 is captured when fetch_i == 2.
                if (fetch_i >= 4'd2)
                    ins <= {ins[55:0], cmem_q};
                if (fetch_i == 4'd9) begin
                    fetch_i <= 4'd0;
                    state   <= V_EXEC;
                end else
                    fetch_i <= fetch_i + 4'd1;
            end

            // ------------------------------------------------------------
            // Decode + condition + (simple) set writeback; route per type.
            V_EXEC: begin
                fuse <= fuse + 13'd1;
                link_cond_l <= link_cond_pre;   // pre-set compare (see above)
                if (fuse >= 13'd4095) begin
                    // runaway program: stop; release the reader if waiting
                    vm_adv <= wait_verdict;
                    state  <= V_IDLE;
                end else begin
                    case (ins_type)
                    3'd0: begin              // special: Nop/Goto/Break/SetPML
                        if (cond_v1 && lnk_op == 4'd3)
                            sprm13 <= {12'd0, ins[11:8]};
                        if (cond_v1 && (lnk_op == 4'd1 || lnk_op == 4'd3))
                            pc <= blk_base + ins[7:0] - 8'd1;   // Goto (1-based)
                        else if (cond_v1 && lnk_op == 4'd2)
                            pc <= blk_end;                      // Break
                        else
                            pc <= pc + 8'd1;
                        state <= V_NEXT;
                    end
                    3'd1: state <= V_LINKEV;
                    3'd2: begin              // system set (+ optional link)
                        if (set_op == 4'd1) begin      // SetSTN
                            if (cond_v2 && ins[39])
                                sprm1 <= ins_imm ? {9'd0, ins[38:32]}
                                                 : gprm[ins[35:32]];
                            if (cond_v2 && ins[31])
                                sprm2 <= ins_imm ? {9'd0, ins[30:24]}
                                                 : gprm[ins[27:24]];
                            if (cond_v2 && ins[23])
                                sprm3 <= ins_imm ? {9'd0, ins[22:16]}
                                                 : gprm[ins[19:16]];
                        end else if (set_op == 4'd2) begin   // SetNVTMR (stub)
                            if (cond_v2) begin
                                sprm9  <= ins_imm ? ins[47:32]
                                                  : eval_reg(ins[39:32]);
                                sprm10 <= {8'd0, ins[23:16]};
                            end
                        end else if (set_op == 4'd3) begin   // SetGPRMMD
                            // the mode bit is set even when the cond fails
                            gprm_mode[ins[19:16]] <= ins[23];
                            if (cond_v2)
                                gprm[ins[19:16]] <= ins_imm ? ins[47:32]
                                                            : eval_reg(ins[39:32]);
                        end else if (set_op == 4'd6) begin   // SetHL_BTNN
                            if (cond_v2) begin
                                sprm8 <= ins_imm ? ins[31:16] : gprm[ins[19:16]];
                                btn_force <= 1'b1;
                                btn_force_val <= ins_imm
                                                 ? ins[31:26]
                                                 : gprm[ins[19:16]][15:10];
                            end
                        end
                        if (lnk_op != 4'd0)
                            state <= V_LINKEV;
                        else begin
                            pc <= pc + 8'd1;
                            state <= V_NEXT;
                        end
                    end
                    3'd3, 3'd4, 3'd5, 3'd6: begin
                        if (set_do && (set_sel_op == 4'd5 || set_sel_op == 4'd6 ||
                                       set_sel_op == 4'd7 || set_sel_op == 4'd8)) begin
                            // serial mul/div/mod/rnd
                            alu_op  <= set_sel_op;
                            alu_reg <= set_sel_reg;
                            alu_a   <= (set_sel_op == 4'd8) ? lfsr_next
                                                            : gprm[set_sel_reg];
                            alu_b   <= set_sel_data;
                            alu_b_orig <= set_sel_data;
                            alu_acc <= 32'd0;
                            alu_rem <= 17'd0;
                            alu_quot<= 16'd0;
                            alu_cnt <= 5'd0;
                            if (set_sel_op == 4'd8) lfsr <= lfsr_next;
                            state <= V_ALU;
                        end else begin
                            if (set_do) begin
                                case (set_sel_op)
                                4'd1: gprm[set_sel_reg] <= set_sel_data;
                                4'd2: begin        // swap: reg2 gets old reg
                                    gprm[set_sel_reg2] <= gprm[set_sel_reg];
                                    gprm[set_sel_reg]  <= set_sel_data;
                                end
                                4'd3: gprm[set_sel_reg] <= add_clamp;
                                4'd4: gprm[set_sel_reg] <= sub_clamp;
                                4'd9:  gprm[set_sel_reg] <= gprm[set_sel_reg] & set_sel_data;
                                4'd10: gprm[set_sel_reg] <= gprm[set_sel_reg] | set_sel_data;
                                4'd11: gprm[set_sel_reg] <= gprm[set_sel_reg] ^ set_sel_data;
                                default: ;
                                endcase
                            end
                            state <= V_LINKEV;
                        end
                    end
                    default: begin           // unknown type 7: Nop
                        pc <= pc + 8'd1;
                        state <= V_NEXT;
                    end
                    endcase
                end
            end

            // ------------------------------------------------------------
            // Serial mul (MSB-first shift-add) / div/mod/rnd (restoring)
            V_ALU: begin
                if (alu_op == 4'd5) begin
                    alu_acc <= {alu_acc[30:0], 1'b0} +
                               (alu_b[15] ? {16'd0, alu_a} : 32'd0);
                    alu_b   <= {alu_b[14:0], 1'b0};
                end else begin
                    if (div_sub[17] == 1'b0 && alu_b_orig != 16'd0) begin
                        alu_rem  <= div_sub[16:0];
                        alu_quot <= {alu_quot[14:0], 1'b1};
                    end else begin
                        alu_rem  <= div_shift;
                        alu_quot <= {alu_quot[14:0], 1'b0};
                    end
                    alu_a <= {alu_a[14:0], 1'b0};
                end
                alu_cnt <= alu_cnt + 5'd1;
                if (alu_cnt == 5'd15)
                    state <= V_ALUWB;
            end

            V_ALUWB: begin
                case (alu_op)
                4'd5: gprm[alu_reg] <= (alu_acc[31:16] != 16'd0) ? 16'hFFFF
                                                                 : alu_acc[15:0];
                4'd6: gprm[alu_reg] <= (alu_b_orig == 16'd0) ? 16'hFFFF : alu_quot;
                4'd7: gprm[alu_reg] <= (alu_b_orig == 16'd0) ? 16'hFFFF
                                                             : alu_rem[15:0];
                4'd8: gprm[alu_reg] <= (alu_b_orig == 16'd0)
                                       ? 16'd0 : (alu_rem[15:0] + 16'd1);
                default: ;
                endcase
                state <= V_LINKEV;
            end

            // ------------------------------------------------------------
            // Link / jump evaluation -> perform the action.
            V_LINKEV: begin
                if (!link_present || !link_cond) begin
                    pc <= pc + 8'd1;
                    state <= V_NEXT;
                end else if (is_jump) begin
                    // ---- jump instructions (type 1, bit60=1) ----
                    case (lnk_op)
                    4'd1: begin                      // Exit: stop, hold frame
                        vm_adv <= wait_verdict;
                        state <= V_IDLE;
                    end
                    4'd2: begin                      // JumpTT n (TT_SRPT resolve)
                        sprm4 <= {9'd0, ins[22:16]};
                        sprm7 <= 16'd1;
                        tt_resolve <= 1'b1;          // SPRM5 <= res_ttn on load
                        vm_dom <= DOM_TT; vm_vts <= 8'd0;
                        jump_domain <= DOM_TT;
                        jump_vts <= 8'd0; jump_pgcn <= 16'd0;
                        jump_entry <= 4'd0;
                        jump_ttn <= ins[22:16];
                        jump_pgn <= 8'd0; jump_cell <= 8'd0;
                        jump_pulse <= 1'b1;
                        fb <= FB_TITLE;
                        wait_tmr <= 24'd0;
                        state <= V_WAIT;
                    end
                    4'd3: begin                      // JumpVTS_TT n
                        sprm5 <= {9'd0, ins[22:16]};
                        sprm7 <= 16'd1;
                        vm_dom <= DOM_TT;
                        jump_domain <= DOM_TT;
                        // "current VTS" is DOMAIN-dependent (link_jump_vts, the
                        // PR-#145 LinkPGCN rule): in a TITLE it is the reader's
                        // loaded-title VTS (cur_vts) - NOT vm_vts, which a
                        // preceding JumpTT leaves 0 (the VTS resolves in the
                        // reader); passing 0 would make the reader treat the
                        // jump as a GLOBAL JumpTT -> wrong VTS. That was the
                        // Scene It boot bug: FP JumpTT 28 -> VTS3 PGCN41, then
                        // its POST JumpVTS_TT 1 jumped to global title 1 = VTS1
                        // (a Tom Cruise QUESTION) instead of VTS3 PGCN1.
                        // In a MENU domain it is the MENU's VTS (vm_vts, kept
                        // exact by JumpSS/CallSS_VTSM) - cur_vts is the STALE
                        // last-played-title VTS there. That was the Hobbit
                        // boot loop: FP -> JumpTT 4 (VTS_03 warning) -> ... ->
                        // VTS_01 VTSM pre JumpVTS_TT 3 dispatched with
                        // cur_vts=3, reloading the VTS_03 warning instead of
                        // VTS_01's settings-trampoline title 3, so the g6=1
                        // menu-entry flag never set -> infinite VMGM/VTSM/
                        // warning ping-pong = black screen with Disc Menus On.
                        jump_vts <= link_jump_vts; jump_pgcn <= 16'd0;
                        jump_entry <= 4'd0;
                        jump_ttn <= ins[22:16];
                        jump_pgn <= 8'd0; jump_cell <= 8'd0;
                        jump_pulse <= 1'b1;
                        fb <= FB_TITLE;
                        wait_tmr <= 24'd0;
                        state <= V_WAIT;
                    end
                    4'd5: begin                      // JumpVTS_PTT t:p (Phase 6: EXACT)
                        sprm5 <= {9'd0, ins[22:16]};
                        sprm7 <= {6'd0, ins[41:32]};
                        vm_dom <= DOM_TT;
                        jump_domain <= DOM_TT;
                        jump_vts <= link_jump_vts; jump_pgcn <= 16'd0;  // domain-dependent (see JumpVTS_TT)
                        jump_entry <= 4'd0;
                        jump_ttn <= ins[22:16];       // data1 = vts_ttn (getbits 22,7)
                        // data2 = part (getbits 41,10) -> reader resolves the
                        // EXACT VTS_PTT_SRPT[ttn][part-1] {pgcn,pgn} (was ptt~=pg
                        // via jump_pgn). jump_pgn stays 0 (pgn comes from the PTT).
                        jump_ptt <= ins[41:32];
                        jump_pgn <= 8'd0;
                        jump_cell <= 8'd0;
                        jump_pulse <= 1'b1;
                        fb <= FB_TITLE;
                        wait_tmr <= 24'd0;
                        state <= V_WAIT;
                    end
                    4'd6, 4'd8: begin                // JumpSS / CallSS
                        if (lnk_op == 4'd8 && vm_dom == DOM_TT) begin
                            // CallSS: save resume info (before domain change)
                            rsm_vts  <= cur_vts;
                            rsm_pgcn <= cur_pgcn;
                            rsm_cell <= (ins[31:24] != 8'd0) ? (ins[31:24] - 8'd1)
                                                             : cur_cell;
                            rsm_r4 <= sprm4; rsm_r5 <= sprm5; rsm_r6 <= sprm6;
                            rsm_r7 <= sprm7; rsm_r8 <= sprm8_eff;
                        end
                        case (ins[23:22])
                        2'd0: begin                  // FP
                            vm_dom <= DOM_FP; vm_vts <= 8'd0;
                            jump_domain <= DOM_FP;
                            jump_vts <= 8'd0; jump_pgcn <= 16'd0;
                            jump_entry <= 4'd0;
                        end
                        2'd1: begin                  // VMGM menu
                            vm_dom <= DOM_VMGM; vm_vts <= 8'd0;
                            jump_domain <= DOM_VMGM;
                            jump_vts <= 8'd0; jump_pgcn <= 16'd0;
                            jump_entry <= ins[19:16];
                        end
                        2'd2: begin                  // VTSM: JumpSS_VTSM (op6) vs CallSS_VTSM (op8)
                            // The two ops DECODE DIFFERENTLY here (libdvdnav decoder.c):
                            //   JumpSS_VTSM: data1=vtsN getbits(31,8)=ins[31:24],
                            //     data2=VTS_TTN(SPRM5) getbits(39,8)=ins[39:32],
                            //     data3=menu getbits(19,4)=ins[19:16] -> OPENS A NEW VTSI
                            //     (may change VTS; data1==0 stays).
                            //   CallSS_VTSM: data1=menu getbits(19,4)=ins[19:16],
                            //     data2=rsm_cell getbits(31,8)=ins[31:24] -> NO vts field;
                            //     STAYS in the current VTS (vm.c: "Must be called before the
                            //     domain is changed", uses the current vtsi).
                            // The old shared code applied JumpSS's vts field (ins[30:24]) to
                            // BOTH ops, so a CallSS_VTSM whose rsm_cell byte was non-zero jumped
                            // to a bogus VTS. On the Matrix this diverted boot: the bumper's
                            // CallSS VTSM (rsm_cell=1) was read as "jump to VTS 1", whose VTSM
                            // Root is a command stub -> JumpSS VMGM PGC 19 -> JumpTT 6 -> the
                            // "Follow the White Rabbit" branch PGCN 6, so the rabbit played for
                            // the whole movie. Correct: stay in VTS 2 -> park on the real root menu.
                            vm_dom      <= DOM_VTSM;
                            jump_domain <= DOM_VTSM;
                            jump_pgcn   <= 8'd0;
                            jump_entry  <= ins[19:16];   // menu type (both ops)
                            if (lnk_op == 4'd8) begin
                                // CallSS_VTSM: stay in the current title's VTS (cur_vts is
                                // authoritative; vm_vts may be 0 after a JumpTT). Resume info
                                // was already saved above; do NOT clobber SPRM5.
                                vm_vts   <= cur_vts;
                                jump_vts <= cur_vts;
                            end else begin
                                // JumpSS_VTSM: open the named VTS (0 = stay in the
                                // CURRENT one); set VTS_TTN_REG. "Current" is
                                // domain-dependent (link_jump_vts): from a TITLE it
                                // is cur_vts - vm_vts is 0 after a JumpTT, and the
                                // old vm_vts fallback shipped jump_vts=0 ->
                                // pgc_error -> a fallback-chain title replay before
                                // the menu (the documented dvd_nav.md quirk, now
                                // fixed). From a menu it is vm_vts (bit-identical).
                                sprm5    <= {8'd0, ins[39:32]};
                                vm_vts   <= (ins[31:24] != 8'd0) ? ins[31:24] : link_jump_vts;
                                jump_vts <= (ins[31:24] != 8'd0) ? ins[31:24] : link_jump_vts;
                            end
                        end
                        default: begin               // VMGM pgc (15-bit, low 8 used)
                            vm_dom <= DOM_VMGM; vm_vts <= 8'd0;
                            jump_domain <= DOM_VMGM;
                            jump_vts <= 8'd0;
                            // DVD-FORK FIX: JumpSS_VMGM_PGC's pgcN is also 15 bits
                            // (decoder.c: getbits(46,15)) - was truncated to ins[39:32].
                            jump_pgcn <= (ins[46:32] != 15'd0) ? {1'b0, ins[46:32]} : 16'd1;
                            jump_entry <= 4'd0;
                        end
                        endcase
                        jump_ttn <= 7'd0; jump_pgn <= 8'd0; jump_cell <= 8'd0;
                        jump_pulse <= 1'b1;
                        fb <= FB_NONE;
                        wait_tmr <= 24'd0;
                        state <= V_WAIT;
                    end
                    default: begin                   // unknown jump op: skip
                        pc <= pc + 8'd1;
                        state <= V_NEXT;
                    end
                    endcase
                end else if (lnk_op_eff == 4'd4) begin   // LinkPGCN n
                    jump_domain <= vm_dom;
                    jump_vts <= link_jump_vts;   // cur_vts in a title (see decl)
                    // DVD-FORK FIX: LinkPGCN's operand is a 15-BIT field
                    // (libdvdnav decoder.c eval_link_instruction: getbits(14,15)).
                    // Taking ins[7:0] aliased PGCN 1381 -> 101 on discs with big
                    // PGCITs (Weakest Link VTS_02 has 1394 PGCs). See docs/disc_sweep.md.
                    jump_pgcn <= {1'b0, ins[14:0]};
                    jump_entry <= 4'd0; jump_ttn <= 7'd0;
                    jump_pgn <= 8'd0; jump_cell <= 8'd0;
                    jump_pulse <= 1'b1;
                    fb <= FB_NONE;
                    wait_tmr <= 24'd0;
                    state <= V_WAIT;
                end else if (lnk_op_eff == 4'd5 || lnk_op_eff == 4'd6) begin
                    // LinkPTTN (part) / LinkPGN (program): try the LIGHT in-PGC
                    // program map first (V_PMRD, no flush, no PRE re-run). On a
                    // single-PGC title (every movie) LinkPTTN part==program==pgn
                    // resolves here directly -- unchanged, glitch-free. If the part
                    // OVERFLOWS the current PGC's program count (pg_tgt > nr_pgms)
                    // it is a CROSS-PGC part (multi-PGC GAME titles: Tomb Raider
                    // VTS5 PGC4 POST LinkPTT 5, PGC11 POST LinkPTT 13 = "return to a
                    // previous choice"), so V_PMRD falls back to the EXACT
                    // VTS_PTT_SRPT resolve instead of dead-ending (HW-confirmed via
                    // the row-22 overlay: last jump = TT vts5 pgc4/pgc11). link_ptt
                    // carries the part for that fallback; LinkPGN never crosses PGCs
                    // so it leaves link_ptt = 0 (overflow stays benign vm_adv).
                    if (sub_btn != 6'd0) begin
                        sprm8 <= {sub_btn, 10'd0};
                        btn_force <= 1'b1;
                        btn_force_val <= sub_btn;
                    end
                    link_ptt <= (lnk_op_eff == 4'd5)
                                ? ((ins[9:0] != 10'd0) ? ins[9:0] : 10'd1) : 10'd0;
                    pg_tgt <= (lnk_op_eff == 4'd5)
                              ? ((ins[9:0] != 10'd0) ? ins[7:0] : 8'd1)
                              : ((ins[6:0] != 7'd0) ? {1'b0, ins[6:0]} : 8'd1);
                    pm_stage <= 1'b0;
                    state <= V_PMRD;
                end else if (lnk_op_eff == 4'd7) begin   // LinkCN n
                    if (sub_btn != 6'd0) begin
                        sprm8 <= {sub_btn, 10'd0};
                        btn_force <= 1'b1;
                        btn_force_val <= sub_btn;
                    end
                    if (ins[7:0] != 8'd0 && (ins[7:0] - 8'd1) == cur_cell) begin
                        vm_replay <= 1'b1;
                        state <= V_IDLE;
                    end else begin
                        seek_cell <= (ins[7:0] != 8'd0) ? (ins[7:0] - 8'd1) : 8'd0;
                        seek_pulse <= 1'b1;
                        state <= V_IDLE;
                    end
                end else if (lnk_op_eff == 4'd1) begin
                    // ---- link by sub-instruction ----
                    if (sub_btn != 6'd0 && sub_op <= 5'd16) begin
                        sprm8 <= {sub_btn, 10'd0};
                        btn_force <= 1'b1;
                        btn_force_val <= sub_btn;
                    end
                    case (sub_op)
                    5'd0: begin                      // LinkNoLink (button only)
                        vm_adv <= wait_verdict;
                        state <= V_IDLE;
                    end
                    5'd1: begin                      // LinkTopC: replay cell
                        vm_replay <= 1'b1;
                        state <= V_IDLE;
                    end
                    5'd2: begin                      // LinkNextC
                        if (cur_cell + 8'd1 >= cell_count) begin
                            // past the last cell -> POST block
                            if (nr_post == 8'd0) begin
                                vm_adv <= 1'b1;
                                state <= V_IDLE;
                            end else begin
                                blk <= BLK_POST;
                                blk_base <= nr_pre;
                                blk_end  <= nr_pre + nr_post;
                                pc       <= nr_pre;
                                state    <= V_FETCH;
                            end
                        end else begin
                            seek_cell <= cur_cell + 8'd1;
                            seek_pulse <= 1'b1;
                            state <= V_IDLE;
                        end
                    end
                    5'd3: begin                      // LinkPrevC
                        seek_cell <= (cur_cell != 8'd0) ? (cur_cell - 8'd1) : 8'd0;
                        seek_pulse <= 1'b1;
                        state <= V_IDLE;
                    end
                    5'd5, 5'd6, 5'd7: begin          // LinkTopPG/NextPG/PrevPG
                        if (nr_pgms == 8'd0) begin
                            // no program map: pg ~= cell approximations
                            if (sub_op == 5'd5) begin
                                vm_replay <= 1'b1;
                                state <= V_IDLE;
                            end else if (sub_op == 5'd6) begin
                                if (cur_cell + 8'd1 >= cell_count) begin
                                    if (nr_post == 8'd0) begin
                                        vm_adv <= 1'b1;
                                        state <= V_IDLE;
                                    end else begin
                                        blk <= BLK_POST;
                                        blk_base <= nr_pre;
                                        blk_end  <= nr_pre + nr_post;
                                        pc       <= nr_pre;
                                        state    <= V_FETCH;
                                    end
                                end else begin
                                    seek_cell <= cur_cell + 8'd1;
                                    seek_pulse <= 1'b1;
                                    state <= V_IDLE;
                                end
                            end else begin
                                seek_cell <= (cur_cell != 8'd0) ? (cur_cell - 8'd1)
                                                                : 8'd0;
                                seek_pulse <= 1'b1;
                                state <= V_IDLE;
                            end
                        end else begin
                            pg_i   <= 8'd0;
                            cur_pg <= 8'd1;
                            pm_stage <= 1'b0;
                            pg_ph  <= 2'd0;
                            state  <= V_PGSCAN;
                        end
                    end
                    5'd9: begin                      // LinkTopPGC: re-enter PGC
                        jump_domain <= vm_dom;
                        jump_vts <= link_jump_vts;   // cur_vts in a title (see decl)
                        jump_pgcn <= cur_pgcn;
                        jump_entry <= 4'd0; jump_ttn <= 7'd0;
                        jump_pgn <= 8'd0; jump_cell <= 8'd0;
                        jump_pulse <= 1'b1;
                        fb <= FB_NONE;
                        wait_tmr <= 24'd0;
                        state <= V_WAIT;
                    end
                    5'd10, 5'd11, 5'd12: begin       // LinkNext/Prev/GoUpPGC
                        if (pgc_nav_target == 16'd0) begin
                            vm_adv <= wait_verdict;
                            state <= V_IDLE;
                        end else begin
                            jump_domain <= vm_dom;
                            jump_vts <= link_jump_vts;   // cur_vts in a title (see decl)
                            jump_pgcn <= pgc_nav_target;
                            jump_entry <= 4'd0; jump_ttn <= 7'd0;
                            jump_pgn <= 8'd0; jump_cell <= 8'd0;
                            jump_pulse <= 1'b1;
                            fb <= FB_NONE;
                            wait_tmr <= 24'd0;
                            state <= V_WAIT;
                        end
                    end
                    5'd13: begin                     // LinkTailPGC: run POST now
                        if (blk == BLK_POST || nr_post == 8'd0) begin
                            vm_adv <= 1'b1;          // already there / none
                            state <= V_IDLE;
                        end else begin
                            blk <= BLK_POST;
                            blk_base <= nr_pre;
                            blk_end  <= nr_pre + nr_post;
                            pc       <= nr_pre;
                            state    <= V_FETCH;
                        end
                    end
                    5'd16: begin                     // LinkRSM
                        if (rsm_vts == 8'd0) begin
                            vm_adv <= wait_verdict;
                            state <= V_IDLE;
                        end else begin
                            sprm4 <= rsm_r4; sprm5 <= rsm_r5; sprm6 <= rsm_r6;
                            sprm7 <= rsm_r7;
                            if (sub_btn == 6'd0) sprm8 <= rsm_r8;
                            vm_dom <= DOM_TT; vm_vts <= rsm_vts;
                            jump_domain <= DOM_TT;
                            jump_vts <= rsm_vts; jump_pgcn <= rsm_pgcn;
                            jump_entry <= 4'd0; jump_ttn <= 7'd0;
                            jump_pgn <= 8'd0; jump_cell <= rsm_cell;
                            jump_pulse <= 1'b1;
                            skip_pre <= 1'b1;
                            fb <= FB_NONE;
                            wait_tmr <= 24'd0;
                            state <= V_WAIT;
                        end
                    end
                    default: begin                   // unknown subins: no link
                        pc <= pc + 8'd1;
                        state <= V_NEXT;
                    end
                    endcase
                end else begin
                    pc <= pc + 8'd1;
                    state <= V_NEXT;
                end
            end

            // ------------------------------------------------------------
            // Program-map scan: cur_pg = largest i+1 with pm[i]-1 <= cur_cell
            // (2 cycles/entry: address, then capture).
            // Program-map scan (cur_pg = largest program whose entry cell <= cur_cell).
            // pmem_q is a REGISTERED read of pmem[pm_raddr], so it lags pm_raddr by a
            // cycle AND pm_raddr is set nonblocking - three phases per entry are needed
            // so pg_hit sees pmem_q == pm[pg_i] (was two phases: pg_hit evaluated the
            // PREVIOUS entry's pm[pg_i-1], over-counting cur_pg/pg_final by 1 whenever a
            // program follows the current cell's program. That made LinkTopPG on the
            // last cell of a program SEEK to the next program's cell instead of replaying
            // - the MiB root-menu montage went cell2 LinkTopPG -> seek cell3 (still) ->
            // black. Matrix loops via LinkCN, not the pg scan, so it was unaffected).
            V_PGSCAN: begin
                if (pg_ph == 2'd0) begin
                    pm_raddr <= pg_i[6:0];
                    pg_ph    <= 2'd1;
                end else if (pg_ph == 2'd1) begin
                    pg_ph <= 2'd2;                    // pmem_q settling -> pm[pg_i]
                end else begin
                    pg_ph <= 2'd0;
                    if (pg_hit) cur_pg <= pg_i + 8'd1;
                    if (pg_i + 8'd1 >= nr_pgms) begin
                        // scan done: pg_final includes THIS entry's verdict
                        if (sub_op == 5'd6) begin            // NextPG
                            if (pg_final + 8'd1 > nr_pgms) begin
                                // past the last program -> POST block
                                if (nr_post == 8'd0) begin
                                    vm_adv <= 1'b1;
                                    state <= V_IDLE;
                                end else begin
                                    blk <= BLK_POST;
                                    blk_base <= nr_pre;
                                    blk_end  <= nr_pre + nr_post;
                                    pc       <= nr_pre;
                                    state    <= V_FETCH;
                                end
                            end else begin
                                pg_tgt <= pg_final + 8'd1;
                                state <= V_PMRD;
                            end
                        end else if (sub_op == 5'd7) begin   // PrevPG
                            pg_tgt <= (pg_final > 8'd1) ? (pg_final - 8'd1) : 8'd1;
                            state <= V_PMRD;
                        end else begin                       // TopPG
                            pg_tgt <= pg_final;
                            state <= V_PMRD;
                        end
                    end else
                        pg_i <= pg_i + 8'd1;
                end
            end

            // pm[pg_tgt-1] -> seek_cell (2-cycle BRAM read)
            V_PMRD: begin
                if (pg_tgt == 8'd0 || nr_pgms == 8'd0 || pg_tgt > nr_pgms) begin
                    if (link_ptt != 10'd0) begin
                        // CROSS-PGC LinkPTTN: the requested part is NOT a program of
                        // the current PGC, so resolve it exactly via VTS_PTT_SRPT
                        // (like JumpVTS_PTT) staying in the current title. This is
                        // the Tomb Raider "return to a previous choice" freeze fix:
                        // VTS5 PGC4/11 POST LinkPTT 5/13 lands on the part's real
                        // PGC instead of dead-ending here. jump_ttn = SPRM5 (current
                        // vts_ttn); PRE skipped (libdvdnav LinkPTTN "PGC Pre-Commands
                        // not executed"). jump_ptt reads the OLD link_ptt (the part).
                        vm_dom      <= DOM_TT;
                        jump_domain <= DOM_TT;
                        jump_vts    <= cur_vts;
                        jump_pgcn   <= 8'd0;
                        jump_entry  <= 4'd0;
                        jump_ttn    <= sprm5[6:0];
                        jump_ptt    <= link_ptt;
                        jump_pgn    <= 8'd0;
                        jump_cell   <= 8'd0;
                        jump_pulse  <= 1'b1;
                        skip_pre    <= 1'b1;
                        fb          <= FB_NONE;
                        wait_tmr    <= 24'd0;
                        link_ptt    <= 10'd0;
                        state       <= V_WAIT;
                    end else begin
                        vm_adv <= wait_verdict;
                        state <= V_IDLE;
                    end
                end else begin
                    link_ptt <= 10'd0;
                    pm_raddr <= pg_tgt[6:0] - 7'd1;
                    pm_stage <= 1'b0;
                    state <= V_PMRD2;
                end
            end
            V_PMRD2: begin
                if (!pm_stage)
                    pm_stage <= 1'b1;           // pmem_q settles this cycle
                else begin
                    pm_stage <= 1'b0;
                    if (pmem_q != 8'd0 && (pmem_q - 8'd1) == cur_cell)
                        vm_replay <= 1'b1;      // same cell: gapless replay
                    else begin
                        seek_cell  <= (pmem_q != 8'd0) ? (pmem_q - 8'd1) : 8'd0;
                        seek_pulse <= 1'b1;
                    end
                    state <= V_IDLE;
                end
            end

            // ------------------------------------------------------------
            // Advance within the block / fall off the end (Break lands here).
            V_NEXT: begin
                if (pc >= blk_end || pc < blk_base) begin
                    case (blk)
                    BLK_PRE: begin
                        // pre fell through: play (the reader already is).
                        // A 0-cell menu PGC whose PRE runs to the end with no link
                        // taken is a dead end -> recover through the MENU fallback
                        // chain (NOT the auto-title = copyright). This is the COMMON,
                        // BENIGN dead-end: a selector dispatcher with no matching case
                        // (TP_SW VTSM Root PGC1 = `g15=TTN; if(g15==k) LinkPGCN..` with
                        // no TTN==1 case -> falls through from the intro context). The
                        // reader delivered the real nr_pre here; do NOT read this as an
                        // nr_pre==0 / straddle bug (see dbg_deadend + docs/dvd_nav.md).
                        // TP_SW plays fine: a question returns to the menu via this path.
                        if (cell_count == 8'd0 && vm_dom != DOM_TT) begin
                            fb <= FB_VTSM;
                            ev_error <= 1'b1;
                            if (!deadend_seen) begin
                                deadend_seen <= 1'b1;
                                deadend_vts  <= cur_vts;
                                deadend_pgcn <= cur_pgcn;
                            end
                        end
                        state <= V_IDLE;
                    end
                    BLK_POST: begin
                        // post fell through: authored next_pgcn/still/hold
                        // (the reader's proven Phase-2/3 policy).
                        vm_adv <= 1'b1;
                        state <= V_IDLE;
                    end
                    BLK_CELL: begin
                        vm_adv <= 1'b1;
                        state <= V_IDLE;
                    end
                    default: state <= V_IDLE;    // BTN: state updated, done
                    endcase
                end else
                    state <= V_FETCH;
            end

            // ------------------------------------------------------------
            // A jump was issued: wait for the reader's verdict.
            V_WAIT: begin
                // wait_hold: the reader has the jump LATCHED but gated on
                // vbuf_empty (natural tail drain, up to ~5 s) - freeze the
                // give-up timer or it expires at ~0.62 s mid-drain, clearing
                // skip_pre / stranding tt_resolve (see the port comment).
                if (!wait_hold) wait_tmr <= wait_tmr + 24'd1;
                if (ev_loaded) begin
                    ev_loaded  <= 1'b0;
                    ev_cellcmd <= 1'b0;
                    ev_pgcend  <= 1'b0;
                    ev_btn     <= 1'b0;
                    // A title is playing again -> forget the menu-key toggle state
                    // (see the ev_loaded handler in V_IDLE; a resume/title jump lands
                    // here in V_WAIT, so the clear must happen on this path too).
                    if (vm_dom == DOM_TT) came_via_menukey <= 1'b0;
                    if (tt_resolve) begin
                        sprm5 <= {9'd0, res_ttn};    // JumpTT's resolved vts_ttn
                        tt_resolve <= 1'b0;
                    end
                    chain <= chain + 7'd1;
                    if (chain >= 7'd63) begin
                        // jump-chain runaway (authored loop): stop chaining
                        skip_pre <= 1'b0;
                        fb <= FB_NONE;
                        state <= V_IDLE;
                    end else if (skip_pre) begin
                        skip_pre <= 1'b0;        // RSM resume: no pre-commands
                        fb <= FB_NONE;
                        state <= V_IDLE;
                    end else if (nr_pre != 8'd0) begin
                        blk <= BLK_PRE;
                        nat_src  <= 1'b0;   // fresh PGC's PRE: not a natural chain
                        blk_base <= 9'd0;
                        blk_end  <= nr_pre;
                        pc       <= 8'd0;
                        state    <= V_FETCH;
                    end else begin
                        // no pre-commands: a 0-cell menu PGC is a dead end ->
                        // recover through the MENU fallback chain (NOT auto-title
                        // = copyright; see the ev_loaded site above).
                        if (cell_count == 8'd0 && vm_dom != DOM_TT) begin
                            fb <= FB_VTSM;
                            ev_error <= 1'b1;
                            if (!deadend_seen) begin
                                deadend_seen <= 1'b1;
                                deadend_vts  <= cur_vts;
                                deadend_pgcn <= cur_pgcn;
                            end
                        end else
                            fb <= FB_NONE;
                        state <= V_IDLE;
                    end
                end else if (ev_error) begin
                    state <= V_IDLE;             // V_IDLE runs the chain
                end else if (wait_tmr == 24'hFFFFFF) begin
                    // the reader never answered (jump not latched): give up
                    skip_pre <= 1'b0;
                    state <= V_IDLE;
                end
            end

            default: state <= V_IDLE;
            endcase
        end
    end
end

endmodule
