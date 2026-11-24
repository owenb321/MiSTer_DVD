#!/usr/bin/env bash
#
# run_kbd_hold.sh -- dvd/kbd_hold.sv: a keyboard / remote FF/REW press is a TAP (the 10 s
# jump) or a HOLD (trick play). bench/dvd/kbd_hold_tb.sv; --red applies one mutation per
# rule to a copy, and each must fail its own scenario:
#   M1 no bridging (a remote's tap stream is not a hold)        -> [3]
#   M2 a hold also taps at its end (a 10 s jump after trick play) -> [2]
#   M3 a lost release holds for ever                            -> [5]
#   M4 nothing is ever held                                     -> [2]
#
#   ./bench/dvd/run_kbd_hold.sh [--red]
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=.sim/kbd_hold; mkdir -p "$OUT"
rc=0
iverilog -g2012 -o "$OUT/base.vvp" dvd/kbd_hold.sv bench/dvd/kbd_hold_tb.sv || exit 1
log=$(vvp -n "$OUT/base.vvp" 2>&1)
if grep -q '^PASS' <<<"$log"; then echo "PASS kbd_hold_tb"; else echo "FAIL kbd_hold_tb"; grep FAIL <<<"$log"; rc=1; fi
if [ "${1:-}" = "--red" ]; then
  mut() {   # mut <id> <scenario> <old> <new>
    python3 - "$OUT/$1.sv" "$3" "$4" <<'PY' || { echo "[$1] FAIL: the mutation did not apply"; rc=1; return; }
import sys
s = open('dvd/kbd_hold.sv').read()
assert s.count(sys.argv[2]) == 1, 'anchor not unique'
open(sys.argv[1], 'w').write(s.replace(sys.argv[2], sys.argv[3]))
PY
    iverilog -g2012 -o "$OUT/$1.vvp" "$OUT/$1.sv" bench/dvd/kbd_hold_tb.sv
    local l; l=$(vvp -n "$OUT/$1.vvp" 2>&1)    # captured: the mutant ends in $fatal
    if grep -q "^FAIL \[$2\]" <<<"$l"; then echo "[$1] PASS ([$2] fails)"; else echo "[$1] FAIL: survived"; rc=1; fi
  }
  mut M1 3 "else if (ev_t >= BRIDGE) begin" "else begin"
  mut M2 2 "tap  <= !held && (run_t < T_HOLD);" "tap  <= 1'b1;"
  mut M3 5 "else if (ev_t >= MAX_DOWN)  begin st <= S_IDLE; held <= 1'b0; end" "else if (1'b0)  begin st <= S_IDLE; held <= 1'b0; end"
  mut M4 2 "if (st != S_IDLE && run_t >= T_HOLD) held <= 1'b1;" "if (1'b0) held <= 1'b1;"
fi
[ $rc = 0 ] && echo "run_kbd_hold: PASS" || echo "run_kbd_hold: FAIL"
exit $rc
