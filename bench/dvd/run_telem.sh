#!/usr/bin/env bash
# Telemetry bridge + hardware-in-the-loop harness gates.
#
# vvp exits 0 even when a testbench reports failures, so every line below is
# gated on the summary string rather than on the exit code.
set -u
cd "$(dirname "$0")/../.."
fail=0

run_iv() {
    local name=$1; shift
    local log; log=$(mktemp)
    if iverilog -g2012 -o /tmp/${name}_sim "$@" 2>"$log" && vvp /tmp/${name}_sim >>"$log" 2>&1 \
       && grep -q "ALL GREEN" "$log"; then
        echo "  PASS $name"
    else
        echo "  FAIL $name"; tail -15 "$log"; fail=1
    fi
    rm -f "$log"
}

run_py() {
    local name=$1; shift
    if "$@" 2>&1 | grep -q "ALL GREEN"; then echo "  PASS $name"
    else echo "  FAIL $name"; "$@" 2>&1 | tail -12; fail=1; fi
}

echo "== RTL =="
run_iv dvd_telem dvd/dvd_telem.sv bench/dvd/dvd_telem_tb.sv

echo "== host tools (no hardware) =="
run_py hud_read     python3 tools/hud_read.py selftest
run_py lipsync      python3 tools/lipsync_measure.py selftest
run_py dvd_explore  python3 tools/dvd_explore.py selftest

[ $fail = 0 ] && echo "run_telem: ALL GREEN" || echo "run_telem: FAILURES"
exit $fail
