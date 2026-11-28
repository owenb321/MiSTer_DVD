#!/usr/bin/env bash
#
# run_pad_hold.sh -- dvd/pad_hold.sv: the gamepad's Fast Fwd / Rewind, tap or hold
# (docs/trick_play.md "The gamepad: tap or hold"). --red adds one mutation per rule;
# each must FAIL its own scenario:
#   M1 a hold also taps at its release                       -> [2]
#   M2 held from the press, not from T_HOLD                  -> [1]
#   M3 the other button joining does not abort the run       -> [4]
#   M4 the direction ignored (every tap is Fast Fwd)         -> [3]
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=bench/dvd/test_vobs/pad_hold; mkdir -p "$OUT"
rc=0

iverilog -g2012 -o "$OUT/base.vvp" dvd/pad_hold.sv bench/dvd/pad_hold_tb.sv || exit 1
log=$(vvp -n "$OUT/base.vvp" 2>&1)
if grep -q '^PASS' <<<"$log"; then echo "PASS pad_hold_tb"; else echo "FAIL pad_hold_tb"; grep FAIL <<<"$log"; rc=1; fi

if [ "${1:-}" = "--red" ]; then
  mut() {   # mut <id> <scenario> <old> <new>
    python3 - "$OUT/$1.sv" "$3" "$4" <<'EOF' || { echo "[$1] FAIL: the mutation did not apply"; rc=1; return; }
import sys
s = open('dvd/pad_hold.sv').read()
assert s.count(sys.argv[2]) == 1, 'anchor not unique'
open(sys.argv[1], 'w').write(s.replace(sys.argv[2], sys.argv[3]))
EOF
    iverilog -g2012 -o "$OUT/$1.vvp" "$OUT/$1.sv" bench/dvd/pad_hold_tb.sv
    # capture first: the mutant ends in $fatal, and under pipefail a failing vvp would
    # sink the pipeline even when grep matches
    local l; l=$(vvp -n "$OUT/$1.vvp" 2>&1)
    if grep -q "^FAIL \[$2\]" <<<"$l"; then echo "[$1] PASS ([$2] fails)"
    else echo "[$1] FAIL: survived"; rc=1; fi
  }
  mut M1 2 "if (!both && !held_ff && !held_rew) begin" "if (!both) begin"
  mut M2 1 "end else if (!both && t >= T_HOLD - 1) begin" "end else if (!both) begin"
  mut M3 4 "                if (ff && rew) begin" "                if (1'b0) begin"
  mut M4 3 "                    tap_ff  <= !dir;
                    tap_rew <=  dir;" "                    tap_ff  <= 1'b1;
                    tap_rew <= 1'b0;"
fi
[ $rc = 0 ] && echo "run_pad_hold: PASS" || echo "run_pad_hold: FAIL"
exit $rc
