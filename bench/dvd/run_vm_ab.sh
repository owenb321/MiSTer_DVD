#!/usr/bin/env bash
# run_vm_ab.sh -- the microcoded DVD VM against the hardwired FSM it replaced
# (docs/nav_engine.md "Gates").
#
#   bench/dvd/run_vm_ab.sh          GREEN: generated files current; the three-way A/B
#   bench/dvd/run_vm_ab.sh --red    + every ;MUT arm diverges; RTL wrapper mutations
#                                     are caught
#
# GREEN, tools/vm_ab.py --new over $VM_AB_SEEDS generated scripts (default 300) of
# $VM_AB_STEPS steps (default 120): the old FSM (bench/dvd/ref/dvd_vm_hw.sv), the
# Python VM (microcode emulator + wrapper model) and the microcoded RTL emit the same
# pulses with the same fields in the same order, the same SPRM changes, and the same
# state at every rest; the RTL also matches the emulator's instruction trace and its
# cycle count, step for step. 1,000 x 120 passed when this was written (217k pulses).
# The generator biases a few commands (SetGPRMMD counters, JumpSS/CallSS VTSM) so
# every ;MUT arm bites even at 60 x 80; the corpus is deterministic per seed.
#
# RED: (a) every `;MUT` arm in dvd/nav/vm.uasm, run in the Python VM, diverges from
# the old FSM somewhere in the corpus (BLIND = FAIL); (b) mutations of the wrapper's
# RTL (the hardwired half, which no ;MUT reaches) diverge in the RTL A/B.
set -u
cd "$(dirname "$0")/../.."
SEEDS=${VM_AB_SEEDS:-300}
STEPS=${VM_AB_STEPS:-120}
rc=0
pass()   { echo "  ok   $*"; }
failed() { echo "  FAIL $*"; rc=1; }

echo "== GREEN"
if python3 tools/nav_isa.py --asm --check > .sim/vm_ab_check.txt 2>&1; then
    pass "tools/nav_isa.py --asm --check: the ROM and generated files are current"
else failed "stale generated files"; cat .sim/vm_ab_check.txt; fi
mkdir -p .sim/vm_ab
if python3 tools/vm_ab.py --new --seeds "$SEEDS" --steps "$STEPS" > .sim/vm_ab/green.txt 2>&1; then
    pass "$(grep '^vm_ab:' .sim/vm_ab/green.txt): old = py = new (+ trace, cycles)"
else failed "vm_ab"; grep -A2 "^FAIL" .sim/vm_ab/green.txt | head -12; fi

if [ "${1:-}" != "--red" ]; then
    [ $rc -eq 0 ] && echo "run_vm_ab: ALL GREEN" || echo "run_vm_ab: FAILURES"
    exit $rc
fi

echo "== RED (a): every ;MUT arm diverges from the old FSM"
if python3 tools/vm_ab.py --red --seeds "$SEEDS" --steps "$STEPS" > .sim/vm_ab/red.txt 2>&1; then
    grep "RED " .sim/vm_ab/red.txt | sed 's/^ */  ok   /'
else failed "vm_ab --red"; grep "RED \|^FAIL" .sim/vm_ab/red.txt | head -20; fi

echo "== RED (b): the wrapper's RTL"
# Each mutant is a COPY in $TMP, compiled through vm_ab.py --vm-src: the tree's
# dvd/dvd_vm.sv is never edited, so a killed run cannot leave a mutant behind.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
wrap() {   # $1 label, $2 sed expression on dvd/dvd_vm.sv
    local src="$TMP/dvd_vm_$1.sv"
    sed "$2" dvd/dvd_vm.sv > "$src"
    if cmp -s dvd/dvd_vm.sv "$src"; then failed "$1: the mutation did not apply (anchor moved)"; return; fi
    if python3 tools/vm_ab.py --new --vm-src "$src" --seeds 40 --steps 80 > ".sim/vm_ab/$1.txt" 2>&1; then
        failed "$1: the A/B PASSED the mutant"
    else pass "$1 -> $(grep -m1 -o '\[new vs old\]: step [0-9]* [A-Z][^:]*' ".sim/vm_ab/$1.txt" || echo diverged)"; fi
}
# the event priority: Return ahead of Menu
wrap W1-priority "s/for (ei = UEV_N - 1; ei >= 0; ei = ei - 1)/for (ei = 0; ei < UEV_N; ei = ei + 1)/"
# (A clear losing to a same-cycle latch is NOT an arm: the A/B applies stimulus only
#  at rest, so no event can share a cycle with a microcode clear. Outside its model --
#  docs/nav_engine.md "What the A/B cannot see".)
# the SPRM8 activation latch forgets to freeze
wrap W2-no-freeze "s/                sprm8_frozen <= 1'b1;/                sprm8_frozen <= 1'b0;/"
# pre_done ignores a pending load
wrap W3-pre-early "s/else if (pre_armed \&\& !ev\[UEV_LOADED\] \&\& (v_idle || jump_pulse)) begin/else if (pre_armed \&\& (v_idle || jump_pulse)) begin/"
# the menu-load latch takes the live cur_vts instead of the VM's domain VTS
wrap W4-lm-vts "s/            last_menu_vts  <= vm_vts;/            last_menu_vts  <= cur_vts;/"

[ $rc -eq 0 ] && echo "run_vm_ab: ALL GREEN" || echo "run_vm_ab: FAILURES"
exit $rc
