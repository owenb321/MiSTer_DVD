#!/usr/bin/env bash
# run_nav_trace.sh -- the nav event FIFO (dvd/nav_trace.sv; docs/hil_play_harness.md
# "Nav event FIFO (fabric)").
#
#   GREEN  bench/dvd/nav_trace_tb.sv: arms [codes] [order] [simul] [merge] [ovf] [ts]
#          [proto] [absent] all PASS
#          tools/check_nav_trace_wiring.py: the emu.sv / dvd_vm / nav_pci / qsf /
#          dvd_ctl.cpp seams (emu.sv has no bench)
#   RED    (--red) every mutation must fail EXACTLY the arms listed beside it -- a
#          mutation caught only by some unrelated arm leaves its own arm vacuous --
#          and the wiring check must catch each wiring mutation.
#
# vvp exits 0 on a bench that only prints FAIL, so the verdict is the bench's own
# PASS/FAIL lines plus its RESULT marker, never the exit code alone.
set -u
cd "$(dirname "$0")/../.."
fail=0
TB=bench/dvd/nav_trace_tb.sv
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# sim <dut.sv> -> prints the sorted FAIL arm list ("-" when none), or BUILD/NOVERDICT
sim() {
    local dut=$1 log="$tmp/log"
    if ! iverilog -g2012 -o "$tmp/sim" "$dut" "$TB" > "$tmp/build" 2>&1; then
        echo BUILD; return; fi
    vvp "$tmp/sim" > "$log" 2>&1
    if ! grep -q "^RESULT: " "$log"; then echo NOVERDICT; return; fi
    local arms; arms=$(grep -oE '^FAIL \[[a-z]+\]' "$log" | sed 's/FAIL \[\(.*\)\]/\1/' | sort -u | tr '\n' ' ')
    echo "${arms:--}"
}

echo "== GREEN"
iverilog -g2012 -o "$tmp/g" dvd/nav_trace.sv "$TB" && vvp "$tmp/g" > "$tmp/glog" 2>&1
if grep -q "^RESULT: PASS" "$tmp/glog" && ! grep -q "^FAIL" "$tmp/glog"; then
    echo "  PASS nav_trace_tb"; grep "^PASS \[" "$tmp/glog" | sed 's/^/      /'
else
    echo "  FAIL nav_trace_tb"; tail -20 "$tmp/glog" | sed 's/^/      /'; fail=1
fi
if python3 tools/check_nav_trace_wiring.py > "$tmp/wlog" 2>&1; then
    echo "  PASS check_nav_trace_wiring"
else
    echo "  FAIL check_nav_trace_wiring"; grep FAIL "$tmp/wlog" | sed 's/^/      /'; fail=1
fi

if [ "${1:-}" = "--red" ]; then
    echo "== RED (RTL: each must fail exactly its arms)"
    # mut <name> <expected arms, space separated> <old> <new> [<old2> <new2>]
    # Each <old> must occur exactly once (or the count given as <old>@N).
    mut() {
        local name=$1 want=$2; shift 2
        python3 - "$tmp/m.sv" "$@" <<'PYEOF'
import sys
dst, *pairs = sys.argv[1:]
s = open('dvd/nav_trace.sv').read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    n = 1
    if '@@' in old:
        old, n = old.rsplit('@@', 1); n = int(n)
    if s.count(old) != n:
        sys.exit(f'anchor count {s.count(old)} != {n}: {old!r}')
    s = s.replace(old, new)
open(dst, 'w').write(s)
PYEOF
        if [ $? != 0 ]; then echo "  FAIL $name: mutation did not apply -- its arm is VOID"; fail=1; return; fi
        local got; got=$(sim "$tmp/m.sv"); got=$(echo "$got" | xargs)
        if [ "$got" = "$want" ]; then echo "  ok   $name -> [$got]"
        else echo "  FAIL $name: failed [$got], must fail exactly [$want]"; fail=1; fi
    }
    mut "R1 priority reversed"            "order" \
        "for (k = NS - 1; k >= 0; k = k - 1)" "for (k = 0; k < NS; k = k + 1)"
    mut "R2 pending clear wins over set"  "simul" \
        "pend <= (pend & ~g_oh) | ev;" "pend <= (pend | ev) & ~g_oh;"
    mut "R3 merges not counted"           "merge" \
        "if (|(ev & pend & ~g_oh)) merges <= merges + 16'd1;" "if (|(ev & pend & ~g_oh)) merges <= merges;"
    mut "R4 FIFO-full drops not counted"  "ovf" \
        "else if (g_any) ovf <= ovf + 16'd1;" "else if (g_any) ovf <= ovf;"
    mut "R5 stc stamp one cycle stale"    "ts" \
        "g_pl, stc, free[20:5]}" "g_pl, stc_p, free[20:5]}"
    mut "R6 fts takes the wrong bits"     "ts" \
        "g_pl, stc, free[20:5]}" "g_pl, stc, free[19:4]}"
    mut "R7 per-drain cap 63"             "proto" \
        "? MAXN : fill[6:0];@@2" "? MAXN - 7'd1 : fill[6:0];"
    mut "R8 no read-ahead (2-cycle RAM)"  "proto" \
        "reg  [79:0] q;" "reg  [79:0] q, q2;" \
        "q <= mem[rptr[7:0]];" "q2 <= mem[rptr[7:0]]; q <= q2;"
    mut "R9 an aborted drain pops"        "proto" \
        $'end else if (!io_enable) begin\n            wcnt <= 4\'d0;' \
        $'end else if (!io_enable) begin\n            if (wi != 3\'d0) rptr <= rptr + 9\'d1;\n            wcnt <= 4\'d0;'
    mut "R10 command decoded on low byte" "absent" \
        "active <= (io_din == CMD);" "active <= (io_din[7:0] == CMD[7:0]);"
    mut "R11 HLI s_ptm off by a bit"      "codes" \
        "g_pl = {btn_ns, h_sptm[19:0]};" "g_pl = {btn_ns, h_sptm[20:1]};"
    mut "R12 keyboard flag lost"          "codes" \
        "l_joy  <= {|(joy_rise & kbd_joy), joy_rise};" "l_joy  <= {1'b0, joy_rise};"
    mut "R13 flush falls logged too"      "codes" \
        "wire  [5:0] fl_rise = flush & ~flush_p;" "wire  [5:0] fl_rise = flush ^ flush_p;"

    echo "== RED (wiring: the checker must catch each)"
    python3 tools/check_nav_trace_wiring.py --red || fail=1
fi

[ $fail = 0 ] && echo "run_nav_trace: ALL PASS" || { echo "run_nav_trace: FAILURES"; exit 1; }
