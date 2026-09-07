#!/usr/bin/env bash
# run_disp_sched.sh — the display scheduler (dvd/disp_sched.sv), GREEN then MUTATED.
#
# disp_sched_tb builds a decoder + raster + clock model from first principles and
# requires every pickup to land within half a scan of its PTS across 16 scenarios.
# Level assertions on a scheduler are exactly the shape that passes without
# proving anything, so five targeted RTL mutations are applied to a COPY of the
# shipping source and each must make its own scenario FAIL:
#
# ⚠ NOT COVERED HERE: the pickup-beats-the-capture race (docs/stc_freerun.md 3.8). A
# faithful model needs the picture to appear at picbuf's output in the same cycle the
# display looks, at a realistic RATE, and the two attempts at it either deadlocked or
# failed identically with and without the fix -- i.e. proved nothing. The acceptance
# evidence for that fix is the measured disp_lag slope on hardware, not this suite.
#
#   M1  due compare flipped to +half_scan       -> every picture one scan late ([1]-[4] lag)
#   M2  deferred skip ordering removed          -> [6] drops break the timeline
#   M3  second-field offset removed             -> [9] second-field tags off by a field
#   M4  backward discontinuity never re-anchors -> [7d] 200 ms backward jump (a 5 s one
#       also trips LATE_MAX, so [7a] cannot see this)
#   M5  every picture counts as 2 fields        -> [6]/[11] false starvation lates (the image
#       list pins each picture's fields on the raster, so the timeline error shows as lates)
#   M6  LATE_MAX back to 350 ms                 -> [8b] a recoverable starvation re-anchors
#   M8  catch-up drop request removed           -> [8d] a display stuck behind at max rate
#   M9  an UNTAGGED pickup sets disp_anchored   -> [13c] audio would commit its phase to a
#       clock pinned at 0. ⚠ NOT [13]: that arm fires a provisional pulse, so `anchored`
#       is already 1 and an untagged pickup never reaches the mutated line -- the check
#       there cannot fail. M9 is what proved it. [13c] is the rig's own case (prov_seen=0).
#   M10 first tag anchors only on disc_w    -> [13b] a SMALL provisional error never
#       yields a display anchor at all
#   M11 anchor_disc keyed on the FULL disc_w -> [14c] a starved display re-phases audio
#   M12 the audio re-phase also keys on a    -> [14d] an authored still/held frame cuts the
#       FORWARD PTS gap                          audio playing over it
#
# ⚠ NOT COVERED HERE, and it cost a hardware round: dvd_audio_decode's play_err is the
# LIP-SYNC measurement (clock minus audio playback position). Re-basing play_anchor on a
# clock re-anchor forces it toward zero and makes it structurally unable to report an
# accumulated error -- it read -98 ms while the real error was 1.6 s. There is no audio
# model in this bench to catch that; the guard is that play_err must be left alone.
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

# ★ MUTATIONS RUN IN PARALLEL (2026-09-07). Each arm is an independent
# build+run, and one disp_sched_tb run is MEASURED at 4m42s pegged on ONE core --
# so ten sequential arms spent ~47 minutes using 1/24th of this machine. They share
# nothing but the shipping source they copy, so they fan out with no interaction.
# Verdicts go to files because a background subshell cannot set `fail` in the parent.
# ⚠ Icarus is single-threaded per process; this parallelises ACROSS arms, which is
# where the idle cores were. Verilator runs the same bench ~13x faster end to end
# and would compound with this, but it is NOT a drop-in: its X handling would have
# hidden the uninitialised cc_line21 toggle that presented as a completely dead DUT
# earlier today. Fast second opinion, not a replacement for the gate.
MUTJOBS=${MUTJOBS:-10}
RESDIR=$(mktemp -d)
mut() {   # name  python-expression(old->new)  expected-failing-scenario-regex
  while [ "$(jobs -rp | wc -l)" -ge "$MUTJOBS" ]; do wait -n 2>/dev/null || break; done
  _mut_one "$@" &
}
_mut_one() {
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
    echo "  $name: caught ($(grep -c '^FAIL' "$d/log") FAIL lines, incl. $pat)" > "$RESDIR/$name"
  else
    { echo "  $name: NOT CAUGHT -- the bench cannot see this defect"
      grep "FAIL\|PASS" "$d/log" | head -5; echo "MUTFAIL"; } > "$RESDIR/$name"
  fi
  rm -rf "$d"
}

echo "== MUTATIONS (each must FAIL) =="
mut M1 "(d_stc_want >= -half_s)" "(d_stc_want >= half_s)" "FAIL \[1\]"
mut M2 "if (pic_valid) defer_q3 <= defer_q3 + {18'd0, skip_dur_q3};" "if (1'b0) defer_q3 <= defer_q3 + {18'd0, skip_dur_q3};" "FAIL \[6\]"
mut M3 "wire [32:0] pic_pts_eff = pic_pts - (pic_pts_2nd ? field_ticks : 33'd0);" "wire [32:0] pic_pts_eff = pic_pts;" "FAIL \[9\]"
mut M4 "((d_pic_next < -frame_s) || (d_pic_next > fwd_max_s) || (d_stc_pic > late_max_s))" "((d_pic_next > fwd_max_s) || (d_stc_pic > late_max_s))" "FAIL \[7d\]"
# M6 is the HW round-B defect itself: lateness treated as a discontinuity again.
mut M6 "34'sd243000" "34'sd31500" "FAIL \[8b\]"
mut M8 "if (cool == 4'd0) begin catchup_late <= 1'b1; cool <= DROP_COOL; end" "if (1'b0) begin catchup_late <= 1'b1; cool <= DROP_COOL; end" "FAIL \[8d\]"
mut M5 "((pic_pf  && pic_rff)  ? dur3 : dur2);" "dur2;" "FAIL \[6\]"
# M9 is the measured HW defect of 2026-09-07: the clock reports itself "on the display
# timeline" while it still holds the parse-front value, so audio latches its playback
# phase ~1.6 s ahead of the picture and nothing ever re-times it.
mut M9 "if (has_tag) disp_anchored <= 1'b1;" "disp_anchored <= 1'b1;" "FAIL \[13c\]"
# M10: the first tagged picture only anchors if it ALSO looks like a discontinuity, so a
# small provisional error never yields a display anchor and audio takes the fallback.
mut M10 "(has_tag && (!disp_anchored || !next_valid || disc_w))" "(has_tag && (!next_valid || disc_w))" "FAIL \[13b\]"
# M11: anchor_disc qualified by the FULL disc_w (lateness included), so a starved
# display re-phases the audio -- a real audio gap as a punishment for our own slowness.
mut M11 "disc       <= disc_jump_w;" "disc       <= disc_w;" "FAIL \[14c\]"
# M12 is the shipped 20260907_1350 build's own predicate: the audio re-phase keyed on a
# FORWARD PTS gap too, so an authored still or held frame cut the middle out of whatever
# audio was playing over it (FAMILY FEUD II: "Name ... windy").
mut M12 "wire disc_jump_w = has_tag && anchored && next_valid && (d_pic_next < -frame_s);" "wire disc_jump_w = has_tag && anchored && next_valid && ((d_pic_next < -frame_s) || (d_pic_next > fwd_max_s));" "FAIL \[14d\]"

wait
for f in "$RESDIR"/*; do
  [ -e "$f" ] || continue
  grep -v '^MUTFAIL$' "$f"
  grep -q '^MUTFAIL$' "$f" && fail=1
done
rm -rf "$RESDIR"

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
