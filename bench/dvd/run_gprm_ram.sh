#!/usr/bin/env bash
# run_gprm_ram.sh -- the GPRMs as a RAM (docs/logic_reclaim.md §9), now the
# microcoded VM's data RAM (docs/nav_engine.md).
#
#   bench/dvd/run_gprm_ram.sh          GREEN: dvd_vm_tb + the access gate
#   bench/dvd/run_gprm_ram.sh --red    + one mutation per GPRM mechanism, each
#                                      caught by the arm written for it
#
# Branch E (PR #135) moved the 16 GPRMs into an M10K and so replaced one-cycle
# reads and writes with an operand prefetch, a two-cycle swap, a read-modify-write
# tick and a clear walk. The microcoded VM (2026-10-07) does all of those in its
# program now, so the mutations are microcode arms (`;MUT` lines in dvd/nav/vm.uasm,
# built into a runnable dvd_vm.sv by `tools/nav_isa.py --mutant`). The claims did
# not change, and neither did the arms of dvd_vm_tb that catch them:
#   F1 type 4 compares AFTER its own set (was: operand forwarding)  -> t4_inc_hits
#   F2 swap's second write                                          -> T6s
#   F3 the 1 Hz counter tick's write                                -> T1
#   F4 a mount clears the GPRMs                                     -> T7c
#   F5 a GPRM index is 4 bits (was: the operand capture slot)       -> T1 harvest
set -u
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0
pass()   { echo "  ok   $*"; }
failed() { echo "  FAIL $*"; rc=1; }
iv() { iverilog -g2012 -Y .sv -Y .v -y dvd -I dvd -o "$1" "$2" bench/dvd/dvd_vm_tb.sv > "$1.log" 2>&1; }

echo "== GREEN"
if python3 tools/nav_isa.py --asm --check > "$TMP/a.out" 2>&1; then pass "the microcode and its generated files are current"
else failed "tools/nav_isa.py --asm --check"; cat "$TMP/a.out"; fi
if iv "$TMP/g" dvd/dvd_vm.sv && vvp "$TMP/g" > "$TMP/g.out" 2>&1 && grep -q "ALL TESTS PASS" "$TMP/g.out"; then
    pass "dvd_vm_tb"
else
    failed "dvd_vm_tb"; grep -E "^FAIL" "$TMP/g.out" | head -5
fi
if python3 tools/check_gprm_ram.py > "$TMP/c.out" 2>&1; then pass "$(cat "$TMP/c.out")"
else failed "check_gprm_ram.py"; cat "$TMP/c.out"; fi

if [ "${1:-}" != "--red" ]; then
    [ $rc -eq 0 ] && echo "run_gprm_ram: ALL GREEN" || echo "run_gprm_ram: FAILURES"
    exit $rc
fi

echo "== RED (each mutation must be caught by its own arm)"
mutate() {   # $1 label, $2 the ;MUT arm in dvd/nav/vm.uasm, $3 expected FAIL text
    local sv
    if ! sv=$(python3 tools/nav_isa.py --mutant "$2" "$TMP" 2>"$TMP/$1.asm"); then
        failed "$1: no ;MUT $2 in dvd/nav/vm.uasm (arm removed?)"; head -3 "$TMP/$1.asm"; return; fi
    if ! iv "$TMP/$1" "$sv"; then failed "$1: mutant did not compile"; head -3 "$TMP/$1.log"; return; fi
    vvp "$TMP/$1" > "$TMP/$1.out" 2>&1
    if grep -q "ALL TESTS PASS" "$TMP/$1.out"; then failed "$1: dvd_vm_tb PASSED the mutant"
    elif grep -q -e "$3" "$TMP/$1.out"; then pass "$1 -> caught by \"$3\""
    else failed "$1: failed, but not by \"$3\""; grep -E "^FAIL" "$TMP/$1.out" | head -3; fi
}
mutate F1-t4-compares-latched t4latched  "FAIL: t4_inc_hits"
mutate F2-swap-one-write      swap1      "FAIL: T6s: swap g1"
mutate F3-tick-no-write       tickwrite  "FAIL: T1: g13 != 8"
mutate F4-no-mount-clear      mountclear "FAIL: T7c"
mutate F5-gprm-index-3-bits   gidx       "FAIL: T1: harvest"

echo "== RED: the access gate"
if python3 tools/check_gprm_ram.py --red > "$TMP/r.out" 2>&1; then sed 's/^/  /' "$TMP/r.out" | sed 's/^  /  ok   /;s/ok     ok/ok/'
else failed "check_gprm_ram.py --red"; cat "$TMP/r.out"; fi

[ $rc -eq 0 ] && echo "run_gprm_ram: ALL GREEN" || echo "run_gprm_ram: FAILURES"
exit $rc
