#!/usr/bin/env bash
#
# run_trick_ctrl.sh -- dvd/trick_ctrl.sv, hold FF/REW = trick play (docs/trick_play.md
# "The controller"). bench/dvd/trick_ctrl_tb.sv scripts every gesture; --red applies one
# mutation per rule to a copy of the source, and each must fail its own scenario:
#
#   M1 the lost-queue fallback exits to the latest armed VOBU    -> [16]
#   M2 still active in the exit seek's cycle                    -> [4]
#   M3 no release needed after an exit (re-enter at the edge)   -> [7]
#   M4 entry without the flushing seek                          -> [1]
#   M5 8x only from T2                                          -> [3]
#   M6 the cadence gate never pulses                            -> [2]
#   M7 the gesture released at the exit (scrub takes a held button) -> [7]
#   M8 an edge on its own arm's clock exits to the VOBU before     -> [10]
#   M9 the fallback: a release on an arm's clock ignores that arm -> [11]
#   M10 the exit back on the old one-ahead rule (the rig's +30 s)   -> [12]
#   M11 nothing shown yet: exit to the latest arm, not the entry    -> [13]
#   M12 a pickup on the release's own clock not counted             -> [14]
#   M13 no tail at the exit                                         -> [15]
#   M14 the tail not ended by the flush                             -> [15]
#   M15 a filter skip leaves the queue trusted                      -> [16]
#
#   ./bench/dvd/run_trick_ctrl.sh [--red]
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=.sim/trick_ctrl; mkdir -p "$OUT"
rc=0

iverilog -g2012 -o "$OUT/base.vvp" dvd/trick_ctrl.sv bench/dvd/trick_ctrl_tb.sv || exit 1
if vvp -n "$OUT/base.vvp" | tee "$OUT/base.log" | grep -q '^PASS'; then echo "PASS trick_ctrl_tb"
else echo "FAIL trick_ctrl_tb"; grep FAIL "$OUT/base.log"; rc=1; fi

if [ "${1:-}" = "--red" ]; then
  mut() {   # mut <id> <scenario> <old> <new>
    python3 - "$OUT/$1.sv" "$3" "$4" <<'EOF' || { echo "[$1] FAIL: the mutation did not apply"; rc=1; return; }
import sys
s = open('dvd/trick_ctrl.sv').read()
assert s.count(sys.argv[2]) == 1, 'anchor not unique'
open(sys.argv[1], 'w').write(s.replace(sys.argv[2], sys.argv[3]))
EOF
    iverilog -g2012 -o "$OUT/$1.vvp" "$OUT/$1.sv" bench/dvd/trick_ctrl_tb.sv
    # capture first: the mutant ends in $fatal, and under pipefail a failing vvp would
    # sink the pipeline even when grep matches
    local log; log=$(vvp -n "$OUT/$1.vvp" 2>&1)
    if grep -q "^FAIL \[$2\]" <<<"$log"; then echo "[$1] PASS ([$2] fails)"
    else echo "[$1] FAIL: survived"; rc=1; fi
  }
  mut M1 16 "shown_ovf           ? ((ex_n == 2'd2) ? ex_prev" "shown_ovf           ? ((ex_n == 2'd2) ? ex_last"
  mut M2 4 "                active     <= 1'b0;
                need_rel   <= 1'b1;" "                need_rel   <= 1'b1;"
  mut M3 7 "if (allowed && !need_rel && (held_ff ^ held_rew))" "if (allowed && (held_ff ^ held_rew))"
  mut M4 1 "                seek_rbn   <= cur_rbn;
                seek_pulse <= 1'b1;" "                seek_rbn   <= cur_rbn;"
  mut M5 3 "(held_cnt >= T1) ? 2'd1" "(held_cnt >= T2) ? 2'd1"
  mut M6 2 "                    go     <= 1'b1;" "                    go     <= 1'b0;"
  mut M7 7 "assign owns = active || need_rel;" "assign owns = active;"
  mut M8 10 "wire [31:0] ex_last = trick_vobu ? trick_nav : nav_last;" "wire [31:0] ex_last = nav_last;"
  mut M10 12 "                              shown_v             ? shown_nav :" "                              shown_v             ? ex_prev :"
  mut M11 13 "                                                    entry_rbn;" "                                                    ex_last;"
  mut M12 14 "                              pop                 ? q0        :" "                              1'b0                ? q0        :"
  mut M13 15 "                tail       <= 1'b1;
                tail_cnt   <= 28'd0;" "                tail_cnt   <= 28'd0;"
  mut M14 15 "if (flush || tail_cnt >= TAIL_MAX - 1)" "if (tail_cnt >= TAIL_MAX - 1)"
  mut M15 16 "            if (skipped) shown_ovf <= 1'b1;" ""
  mut M9 11 "wire [31:0] ex_prev = trick_vobu ? nav_last  : nav_prev;" "wire [31:0] ex_prev = nav_prev;"
fi
[ $rc = 0 ] && echo "run_trick_ctrl: PASS" || echo "run_trick_ctrl: FAIL"
exit $rc
