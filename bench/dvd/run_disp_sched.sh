#!/usr/bin/env bash
# run_disp_sched.sh — the display scheduler (dvd/disp_sched.sv), GREEN then MUTATED.
#
# disp_sched_tb builds a decoder + raster + clock model from first principles and
# requires every pickup to land within half a scan of its PTS across 13 scenarios.
# Level assertions on a scheduler are exactly the shape that passes without
# proving anything, so five targeted RTL mutations are applied to a COPY of the
# shipping source and each must make its own scenario FAIL:
#
#   M1  due compare flipped to +half_scan       -> every picture one scan late ([1]-[4] lag)
#   M2  deferred skip ordering removed          -> [6] drops break the timeline
#   M3  second-field offset removed             -> [9] second-field tags off by a field
#   M4  backward discontinuity never re-anchors -> [7d] 200 ms backward jump (a 5 s one
#       also trips LATE_MAX, so [7a] cannot see this)
#   M5  every picture counts as 2 fields        -> [6]/[11] false starvation lates (the image
#       list pins each picture's fields on the raster, so the timeline error shows as lates)
set -u
cd "$(dirname "$0")/../.."
fail=0

echo "== GREEN =="
iverilog -g2012 -o bench/dvd/disp_sched_sim dvd/disp_sched.sv bench/dvd/disp_sched_tb.sv || exit 1
if vvp bench/dvd/disp_sched_sim | grep -v '^VCD' | tee /tmp/disp_sched_green.log | grep -q "^PASS: disp_sched_tb"; then
  echo "  PASS disp_sched_tb"
else
  echo "  FAIL disp_sched_tb"; tail -20 /tmp/disp_sched_green.log; fail=1
fi

mut() {   # name  python-expression(old->new)  expected-failing-scenario-regex
  local name=$1 old=$2 new=$3 pat=$4
  local d; d=$(mktemp -d)
  python3 - "$d" "$old" "$new" <<'PYEOF'
import sys
d, old, new = sys.argv[1:4]
s = open('dvd/disp_sched.sv').read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(d + '/disp_sched.sv', 'w').write(s.replace(old, new))
PYEOF
  iverilog -g2012 -o "$d/sim" "$d/disp_sched.sv" bench/dvd/disp_sched_tb.sv || { echo "  $name: build failed"; fail=1; rm -rf "$d"; return; }
  vvp "$d/sim" | grep -v '^VCD' > "$d/log"
  if grep -q "^FAIL" "$d/log" && grep -q "$pat" "$d/log"; then
    echo "  $name: caught ($(grep -c '^FAIL' "$d/log") FAIL lines, incl. $pat)"
  else
    echo "  $name: NOT CAUGHT -- the bench cannot see this defect"; grep "FAIL\|PASS" "$d/log" | head -5; fail=1
  fi
  rm -rf "$d"
}

echo "== MUTATIONS (each must FAIL) =="
mut M1 "(d_stc_want >= -half_s)" "(d_stc_want >= half_s)" "FAIL \[1\]"
mut M2 "if (pic_valid) defer_q3 <= defer_q3 + {18'd0, skip_dur_q3};" "if (1'b0) defer_q3 <= defer_q3 + {18'd0, skip_dur_q3};" "FAIL \[6\]"
mut M3 "pic_pts_eff <= pic_pts - (pic_pts_2nd ? field_ticks : 33'd0);" "pic_pts_eff <= pic_pts;" "FAIL \[9\]"
mut M4 "((d_pic_next < -frame_s) || (d_pic_next > fwd_max_s) || (d_stc_pic > late_max_s))" "((d_pic_next > fwd_max_s) || (d_stc_pic > late_max_s))" "FAIL \[7d\]"
mut M5 "pic_dur_q3  <= field_q3 * pic_fields;" "pic_dur_q3  <= field_q3 * 3'd2;" "FAIL \[6\]"

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
