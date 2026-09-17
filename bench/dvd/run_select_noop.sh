#!/usr/bin/env bash
# run_select_noop.sh -- Select during a menu transition must do nothing.
#
# THE DEFECT (2026-09-17)
# ----------------------
# Field report: "sometimes when navigating menus, if I hit Select during a
# transition, it will kick me back to the boot chain" -- ULTIMATE_T2's Mission
# Profiles slides and the Scooby-Doo 2 menu transitions, landing on the disc's
# first copyright screen. The maintainer supplied the control arm that identifies
# the mechanism: on Scooby it happens ONLY if the Menu button was used to skip the
# boot logos.
#
#   * emu.sv re-interpreted Select-with-nothing-armed as Resume.
#   * A menu TRANSITION is exactly that window: every cell seek / VM jump pulses
#     load_flush -> pipe_rst_n -> nav_pci disarms, and a transition cell's NAV packs
#     carry hli_ss=0, so nothing re-arms for the length of the clip (T2 ~2 s,
#     Scooby 6-19 s).
#   * dvd_vm's ev_resume was the one user event NOT invalidated by a PGC load
#     (ev_btn is cleared at both ev_loaded exits) -- so the press outlived the
#     transition and LinkRSM'd out of the menu that had just arrived.
#   * The Menu press used to skip the logos is what makes rsm_* the boot chain.
#
# Neither disc authors a UOP prohibition on button select (measured: pgc_uop bit 17
# and every vobu_uop_ctl are clear), so there was nothing to honour -- the fix is
# that the press means nothing rather than something else.
#
# WHAT THIS GATES
#   [1] tools/check_select_noop.py -- the emu.sv seam. emu.sv has no bench, and the
#       fix is a DELETION there, so this is the only thing that can see it.
#   [2] dvd_vm_tb -- [S16] (re-pointed at the Menu key rather than left vacuous when
#       its key_resume stimulus was deleted) and [S25] (a button press latched during
#       V_WAIT dies with that wait, on BOTH exits).
#   [3] the menu suites that must not move: nav_pci_tb via run_link_button.sh, and
#       the reader's menu/VM benches.
#
# --red applies one targeted regression per claim and requires the assertion that
# owns it to be the one that fires.
#
#   bench/dvd/run_select_noop.sh          # GREEN only
#   bench/dvd/run_select_noop.sh --red    # GREEN + the regression arms
set -euo pipefail
cd "$(dirname "$0")/../.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rc=0

pass()   { echo "  ok   $1"; }
failed() { echo "  FAIL $1"; rc=1; }

iv() { iverilog -g2012 -o "$1" "${@:2}"; }

# Apply a mutation and FAIL LOUDLY if it did not change the file. A sed that no
# longer matches silently produces an unmutated copy, the checker passes, and --red
# reports a gate that is proving nothing. (run_frame_step.sh records the same trap.)
mut() {  # $1 = label, $2 = src, $3 = dst, $4.. = sed script(s)
    local label="$1" src="$2" dst="$3"; shift 3
    cp "$src" "$dst"
    local args=()
    for e in "$@"; do args+=(-e "$e"); done
    sed -i "${args[@]}" "$dst"
    if cmp -s "$src" "$dst"; then
        failed "$label: the mutation did not apply -- pattern stale, so this arm proves NOTHING"
        return 1
    fi
    return 0
}

# A mutated emu.sv must be REJECTED, and by the named assertion that owns it.
red_emu() {  # $1 = label, $2 = mutated file, $3 = assertion substring
    if python3 tools/check_select_noop.py "$2" > "$TMP/out" 2>&1; then
        failed "$1: the seam check PASSED a mutated emu.sv"
        return
    fi
    if grep -qe "$3" "$TMP/out"; then
        pass "$1 -> caught by: $(grep -oe "$3" "$TMP/out" | head -1)"
    else
        failed "$1: rejected, but NOT by the assertion that owns it (wanted '$3')"
        sed -n '1,6p' "$TMP/out"
    fi
}

# A mutated dvd_vm.sv must make dvd_vm_tb fail, by its own named arm.
red_vm() {  # $1 = label, $2 = mutated dvd_vm.sv, $3 = expected FAIL substring
    if ! iv "$TMP/red_vm" "$2" bench/dvd/dvd_vm_tb.sv > "$TMP/c.log" 2>&1; then
        failed "$1: mutated dvd_vm.sv did not compile"; head -3 "$TMP/c.log"; return
    fi
    vvp "$TMP/red_vm" > "$TMP/red_vm.out" 2>&1 || true
    if grep -q "ALL TESTS PASS" "$TMP/red_vm.out"; then
        failed "$1: dvd_vm_tb PASSED a mutated dvd_vm.sv"
        return
    fi
    if grep -qe "$3" "$TMP/red_vm.out"; then
        pass "$1 -> caught by: $(grep -oe "$3" "$TMP/red_vm.out" | head -1)"
    else
        failed "$1: failed, but NOT by the arm that owns it (wanted '$3')"
        grep "^FAIL" "$TMP/red_vm.out" | head -3
    fi
}

echo "== GREEN =="

# [1] the emu.sv seam
if python3 tools/check_select_noop.py > "$TMP/seam.out" 2>&1; then
    pass "check_select_noop.py: $(cat "$TMP/seam.out")"
else
    failed "check_select_noop.py"; cat "$TMP/seam.out"
fi

# [2] the VM: S16 (Cluedo, re-pointed) and S25 (both V_WAIT doors)
if iv "$TMP/vm_sim" dvd/dvd_vm.sv bench/dvd/dvd_vm_tb.sv > "$TMP/vm.log" 2>&1; then
    vvp "$TMP/vm_sim" > "$TMP/vm.out" 2>&1 || true
    if grep -q "ALL TESTS PASS" "$TMP/vm.out"; then
        pass "dvd_vm_tb ($(grep -c '^S[0-9]' "$TMP/vm.out") scenarios)"
        grep -E "^S(16|25) " "$TMP/vm.out" | sed 's/^/       /'
    else
        failed "dvd_vm_tb"; grep "^FAIL" "$TMP/vm.out" | head -5
    fi
else
    failed "dvd_vm_tb compile"; head -5 "$TMP/vm.log"
fi

# [3] the menu suites this must not move. The reader benches all instantiate
#     dvd_vm, so the port removal touches every one of them.
for tb in iso_reader_vm iso_reader_menu iso_reader_cluedo_menu iso_reader_intitle_link \
          iso_reader_callss_return iso_reader_zerocell iso_reader_titlestill \
          iso_reader_predispatch iso_reader_montage iso_reader_linkptt iso_reader_celldur; do
    T=bench/dvd/${tb}_tb.sv
    [ -f "$T" ] || { failed "$tb: bench missing"; continue; }
    if iv "$TMP/$tb" dvd/dvd_iso_reader.sv dvd/dvd_vm.sv dvd/bcd_time_add.sv "$T" \
         > "$TMP/$tb.log" 2>&1; then
        vvp "$TMP/$tb" > "$TMP/$tb.out" 2>&1 || true
        # ⚠ Require the PASS marker positively, and never sniff for "error": these
        # benches print `pgc_error=1` as an EXPECTED outcome (iso_reader_menu_tb
        # TEST6/TEST7 are the whole point of the fallback chain), so a loose
        # case-insensitive grep reports a green bench as failing -- measured, and it
        # is the same shape as reading a healthy signal as a fault. A positive
        # marker also catches a bench that dies before it finishes, which a
        # failure-sniffing rule reports as a pass.
        if grep -q "ALL TESTS PASSED" "$TMP/$tb.out" \
           && ! grep -qE "(^|[[:space:]])FAIL" "$TMP/$tb.out"; then
            pass "$tb"
        else
            failed "$tb"; grep -E "(^|[[:space:]])FAIL" "$TMP/$tb.out" | head -3
        fi
    else
        failed "$tb: compile"; grep -v -e warning -e Padding "$TMP/$tb.log" | head -3
    fi
done

if iv "$TMP/atmos" dvd/dvd_vm.sv bench/dvd/dvd_vm_atmos_tb.sv > "$TMP/atmos.log" 2>&1; then
    vvp "$TMP/atmos" > "$TMP/atmos.out" 2>&1 || true
    grep -q "PASSED" "$TMP/atmos.out" && pass "dvd_vm_atmos_tb" || {
        failed "dvd_vm_atmos_tb"; grep -iE "fail|error" "$TMP/atmos.out" | head -3; }
else
    failed "dvd_vm_atmos_tb: compile"; grep -v -e warning -e Padding "$TMP/atmos.log" | head -3
fi

if [ "${1:-}" != "--red" ]; then
    [ $rc -eq 0 ] && echo "run_select_noop: ALL GREEN" || echo "run_select_noop: FAIL"
    exit $rc
fi

echo "== RED (the seam) =="
E=dvd/emu.sv

# R0 -- the REAL pre-fix file, straight out of git. Not a hand-made mutation: the
# thing the field reported, as it actually shipped.
if git show 99790bd:dvd/emu.sv > "$TMP/R0.sv" 2>/dev/null; then
    red_emu "R0 pre-fix emu.sv (main @ 99790bd)" "$TMP/R0.sv" "second consumer"
else
    echo "  skip R0 (commit 99790bd not in this clone)"
fi

# R1 -- a NEW second consumer of sel_edge. This is the shape the next
# "Select should also..." patch will take, and the reason the check is written as
# an invariant over every reader rather than as "key_resume is absent".
mut R1 "$E" "$TMP/R1.sv" \
    "s|^        if (menus_on \&\& menu_edge)\$|        if (menus_on \&\& menu_active \&\& sel_edge \&\& !hl_btns_armed)\n            key_title_p <= 1'b1;\n        if (menus_on \&\& menu_edge)|" \
    && red_emu "R1 a new second consumer of sel_edge" "$TMP/R1.sv" "second consumer"

# R2 -- ANTI-VACUITY: Select deleted outright. "Nothing drives it" must not pass.
mut R2 "$E" "$TMP/R2.sv" \
    "s|            nav_act_p <= sel_edge;|            nav_act_p <= 1'b0;|" \
    "s|        else if (in_title_hli \&\& sel_edge)|        else if (in_title_hli)|" \
    && red_emu "R2 activation removed (anti-vacuity)" "$TMP/R2.sv" "nothing reads it"

# R3 -- ANTI-VACUITY: the Menu key unwired. B5 now solely owns the resume toggle,
# so "no key_resume" would otherwise pass for entirely the wrong reason.
mut R3 "$E" "$TMP/R3.sv" \
    "s|\.key_menu      (key_menu_p),|.key_menu      (1'b0),|" \
    && red_emu "R3 Menu key unwired (anti-vacuity)" "$TMP/R3.sv" "key_menu"

# R4 -- strip_comments() is load-bearing, and this proves it rather than asserting
# it: emu.sv's replacement comment quotes the DELETED code verbatim, on purpose, so
# a grep-based checker reports the defect present on a CORRECT file.
if grep -q "key_resume_p <= 1'b1;" "$E"; then
    pass "R4 a grep checker would FAIL the fixed file (the comment quotes the deleted code)"
else
    failed "R4: the comment no longer quotes the deleted code -- the trap is undocumented"
fi

echo "== RED (the VM: both V_WAIT doors) =="
V=dvd/dvd_vm.sv

# R5 -- un-clear the ev_error exit. Reachable whenever the fallback chain lands on
# its one NO-JUMP arm (FB_GAVEUP); every other arm jumps, and that jump's ev_loaded
# would clear ev_btn anyway. S25b exists to reach exactly that.
python3 - "$V" "$TMP/R5.sv" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = """                end else if (ev_error) begin
                    ev_btn <= 1'b0;
                    state <= V_IDLE;             // V_IDLE runs the chain"""
new = """                end else if (ev_error) begin
                    state <= V_IDLE;             // V_IDLE runs the chain"""
assert old in s, "R5 anchor moved -- this arm would prove NOTHING"
open(sys.argv[2], 'w').write(s.replace(old, new, 1))
PY
red_vm "R5 ev_error exit leaks a stale press" "$TMP/R5.sv" "S25b"

# R6 -- un-clear the give-up exit.
python3 - "$V" "$TMP/R6.sv" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = """                    // the reader never answered (jump not latched): give up
                    ev_btn <= 1'b0;
                    skip_pre <= 1'b0;"""
new = """                    // the reader never answered (jump not latched): give up
                    skip_pre <= 1'b0;"""
assert old in s, "R6 anchor moved -- this arm would prove NOTHING"
open(sys.argv[2], 'w').write(s.replace(old, new, 1))
PY
red_vm "R6 give-up exit leaks a stale press" "$TMP/R6.sv" "S25a"

[ $rc -eq 0 ] && echo "run_select_noop: ALL GREEN" || echo "run_select_noop: FAIL"
exit $rc
