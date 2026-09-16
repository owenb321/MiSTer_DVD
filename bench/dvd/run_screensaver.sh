#!/usr/bin/env bash
# Gate for "Stop and the screensaver must hide everything derived from the picture"
# (2026-09-15; docs/screensaver.md).
#
# The defect: pause on a disc menu with a button highlighted and the highlight was
# still drawn once the screensaver kicked in. pic_blank took core_r/g/b to black and
# hud_on_e/bar_on_e suppressed the chrome, but sp_q_inside / hl_use carried no gate,
# so the subpicture layer composited over the blanked black frame and stayed. A menu
# highlight never expires on its own -- spu_decode's menu_mode bypasses the STC
# show/hide window -- so it burns in for the whole screensaver, and on Stop, which is
# indefinite, it never ends at all.
#
#   A gate on the picture is not a gate on what is drawn OVER the picture.
#
# Three arms, one per layer of that claim:
#   check_saver_overlay_wiring.py   THE SEAM. Which layers go dark is decided entirely
#                     in emu's overlay priority-mux register stage and emu has no
#                     bench -- every module here is individually correct and
#                     individually benched, and the defect was one missing term in the
#                     expression composing them. Pins the pre-existing hud_on_e /
#                     bar_on_e / blend-input gates too, and pins BY REJECTION the
#                     wires that must stay ungated.
#   stop_ctl_tb       THE PRODUCER: the timer, the any_input dismiss (which is what
#                     makes the highlight come back), Stop's two stages, and [S7] --
#                     the screensaver disturbs no playback state.
#                     ⚠ This bench had NO RUNNER until this file; it could only ever
#                     be invoked by hand.
#   subpic_blend_tb   THE CONSUMER: ov_on low is passthrough whatever else is
#                     asserted. The fix hides the layer by clearing ov_on ALONE, so
#                     that has to be a property of the module, not an assumption.
#
# --red applies one targeted mutation per claim and requires the arm that owns the
# claim to fail. Mutations go to $TMP -- the wiring check takes a path argument, so
# unlike run_ov_geom.sh this never writes a mutated emu.sv into the working tree.
#   R1  emu: sp_on_q back to the raw sp_q_inside   THE SHIPPED DEFECT
#   R2  emu: sp_force_q back to the raw hl_use     the half-fix (idx0 fill survives)
#   R3  emu: sp_on_e declared but its line deleted vacuity: absence must FAIL
#   R4  emu: gate narrowed to ~saver_on_w          Stop left leaking
#   R5  emu: the ~ dropped from ~pic_blank         the feature exactly backwards
#   R6  emu: hud_on_e's gate deleted               the PRE-EXISTING policy
#   R7  emu: the blend-input pic_blank deleted     the Stop round-1 regression
#   R8  emu: hl_use_e fed to the O[2] hl_use_q     blinds dbg_blk8
#   R9  emu: sp_sel_col gated                      the palette address must not be
#   R10 emu: pic_blank loses stopped_w             half the coverage
#   R11 emu: sp_seen keyed on sp_on_e              blinds dbg_blk3
#   R12 stop_ctl: `|| any_input` dropped           -> stop_ctl_tb (no dismiss)
#   R13 subpic_blend: (ov_on || ov_force)          -> subpic_blend_tb
#
#   bash bench/dvd/run_screensaver.sh          # GREEN
#   bash bench/dvd/run_screensaver.sh --red    # GREEN + every mutation
set -u
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rc=0

pass()   { echo "  ok   $1"; }
failed() { echo "  FAIL $1"; rc=1; }

# A mutation that does not change the file is a bench that cannot fail. So is one
# that does not COMPILE -- run_spu_window.sh shipped two arms that "passed" on a
# build error.
mut() {   # $1 = source, $2 = sed program, $3 = destination
    sed "$2" "$1" > "$3"
    if cmp -s "$1" "$3"; then
        echo "  FAIL mutation did not apply (stale sed pattern): $2"; rc=1; return 1
    fi
}

run_wire() {  # $1 = emu.sv to check, $2 = label
    python3 tools/check_saver_overlay_wiring.py "$1" > "$TMP/w_$2.out" 2>&1
}
run_stop() {  # $1 = stop_ctl.sv, $2 = label
    iverilog -g2012 -o "$TMP/s_$2" "$1" bench/dvd/stop_ctl_tb.sv > "$TMP/s_$2.log" 2>&1 \
        || { echo "  FAIL compile failed ($2)"; head "$TMP/s_$2.log"; rc=1; return 2; }
    vvp "$TMP/s_$2" > "$TMP/s_$2.out" 2>&1
    grep -q "STOP_CTL_TB: ALL TESTS PASSED" "$TMP/s_$2.out"
}
run_blend() { # $1 = subpic_blend.sv, $2 = label
    iverilog -g2012 -o "$TMP/b_$2" "$1" bench/dvd/subpic_blend_tb.sv > "$TMP/b_$2.log" 2>&1 \
        || { echo "  FAIL compile failed ($2)"; head "$TMP/b_$2.log"; rc=1; return 2; }
    vvp "$TMP/b_$2" > "$TMP/b_$2.out" 2>&1
    grep -q "RESULT: PASS" "$TMP/b_$2.out"
}

echo "== GREEN"
if run_wire dvd/emu.sv green; then pass "$(cat "$TMP/w_green.out")"; else failed "check_saver_overlay_wiring.py"; cat "$TMP/w_green.out"; fi
if run_stop dvd/stop_ctl.sv green; then pass "stop_ctl_tb (11 arms; [S7] = playback state untouched)"; else failed "stop_ctl_tb"; grep -i "FAIL" "$TMP/s_green.out" | head; fi
if run_blend dvd/subpic_blend.sv green; then pass "subpic_blend_tb (ov_on low = passthrough, on/off x 4096 sweep)"; else failed "subpic_blend_tb"; grep -i "FAIL" "$TMP/b_green.out" | head; fi

if [ "${1:-}" != "--red" ]; then
    [ $rc -eq 0 ] && echo "run_screensaver: PASS" || echo "run_screensaver: FAIL"
    exit $rc
fi

echo "== RED (each mutation must be caught by its own arm)"

# --- emu.sv: the composition. Caught by the wiring check. --------------------
# ⚠ delimiter is @ throughout -- these expressions contain bitwise |.
emu_red() {   # $1 = label, $2 = sed program, $3 = a string the failure must name
    mut dvd/emu.sv "$2" "$TMP/$1.sv" || return
    if run_wire "$TMP/$1.sv" "$1"; then
        failed "$1 -- the wiring check PASSED a mutated emu.sv"
    elif grep -q -- "$3" "$TMP/w_$1.out"; then
        pass "$1 caught (names \"$3\")"
    else
        failed "$1 failed, but not for its own reason (wanted \"$3\")"; cat "$TMP/w_$1.out"
    fi
}

emu_red R1  's@| logo_on_w | sp_on_e;@| logo_on_w | sp_q_inside;@'          'sp_on_q'
emu_red R2  's@| logo_on_w | hl_use_e;@| logo_on_w | hl_use;@'              'sp_force_q'
emu_red R3  's@^wire sp_on_e   = sp_q_inside & ~pic_blank;$@// R3: deleted@' 'not assigned anywhere'
# ⚠ R3/R4/R5 all mutate sp_on_e, so each is matched on the MESSAGE that distinguishes
# it, not on the wire name: absent ("not assigned anywhere") vs wrong terms ("expected
# exactly") vs missing '~' ("not INVERTED"). A mutation caught by everything says
# nothing about which assertion is load-bearing.
emu_red R4  's@wire sp_on_e   = sp_q_inside & ~pic_blank;@wire sp_on_e   = sp_q_inside \& ~saver_on_w;@' 'expected exactly'
emu_red R5  's@wire sp_on_e   = sp_q_inside & ~pic_blank;@wire sp_on_e   = sp_q_inside \& pic_blank;@'   'not INVERTED'
emu_red R6  's@wire hud_on_e  = hud_on_w & ~saver_on_w & ~stop_full;@wire hud_on_e  = hud_on_w;@'        'hud_on_e'
emu_red R7  's@\.in_r(pic_blank ? 8.d0 : core_r),@.in_r(core_r),@'          'subpic_blend.in_r'
emu_red R8  's@hl_use_q <= hl_use;@hl_use_q <= hl_use_e;@'                  'hl_use_q'
emu_red R9  's@wire \[3:0\] sp_sel_col = hl_use ?@wire [3:0] sp_sel_col = hl_use_e ?@' 'sp_sel_col'
emu_red R10 's@wire pic_blank = stopped_w | saver_on_w;@wire pic_blank = saver_on_w;@'  'pic_blank'
emu_red R11 's@else if (sp_q_inside)                sp_seen <= 1.b1;@else if (sp_on_e)                   sp_seen <= 1'"'"'b1;@' 'sp_seen'

# --- the two module arms: prove they can fail at all -------------------------
# R12 -- without the dismiss the screensaver never releases, so the highlight this
# whole branch hides would never come back. stop_ctl_tb [S6] owns that claim.
if mut dvd/stop_ctl.sv 's@!armed || any_input || start_streaming@!armed || start_streaming@' "$TMP/R12.sv"; then
    if run_stop "$TMP/R12.sv" R12; then failed "R12 -- stop_ctl_tb PASSED a saver that never dismisses"
    elif grep -q "S6" "$TMP/s_R12.out"; then pass "R12 any_input dismiss deleted -> stop_ctl_tb S6 red"
    else failed "R12 failed, but not in S6"; grep -i "FAIL" "$TMP/s_R12.out" | head; fi
fi

# R13 -- THE ARM THE FIX RESTS ON. Clearing ov_on alone must remove the pixel.
# ⚠ Measured when this arm was added: the PRE-change subpic_blend_tb reports
# RESULT: PASS and exits 0 on exactly this mutation. The on/off sweep is what
# catches it, not the named vectors.
if mut dvd/subpic_blend.sv "s@wire blend = ov_on && (ov_alpha != 4'd0)@wire blend = (ov_on || ov_force) \&\& (ov_alpha != 4'd0)@" "$TMP/R13.sv"; then
    if run_blend "$TMP/R13.sv" R13; then failed "R13 -- subpic_blend_tb PASSED ov_force overriding ov_on"
    else pass "R13 ov_force overrides ov_on -> subpic_blend_tb red"; fi
fi

[ $rc -eq 0 ] && echo "run_screensaver: PASS (green + all mutations caught)" || echo "run_screensaver: FAIL"
exit $rc
