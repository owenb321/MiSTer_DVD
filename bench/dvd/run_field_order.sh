#!/usr/bin/env bash
#
# run_field_order.sh -- does the decoder DISPLAY the field the disc coded first?
#
# THE DEFECT (2026-09-18, field report: Thayer's Quest "looks like it's not
# interlaced properly, even when playing back on a CRT"). On a FIELD-coded
# picture (picture_structure 1=top / 2=bottom rather than 3=frame) ISO 13818-2
# 6.3.10 forces the top_field_first syntax element to 0, so it carries no
# information -- the display order is given by WHICH PARITY IS CODED FIRST.
# dvd/resample_addrgen.v ordered its two field images from top_field_first
# alone, so every field-coded picture was emitted BOTTOM-then-TOP. On film that
# is invisible (both fields of a 3:2 frame are the same instant, so swapping
# them costs the line assignment and no temporal error -- docs/single_raster_
# analog.md); on TRUE-interlaced field-coded content the two fields are distinct
# instants 1/59.94 s apart, so the display sequence becomes t1,t0,t3,t2,...
#
# MEASURED on Thayer's Quest, which is field-coded on 9 of its 11 VTSes: 93.9%
# to 100% of pairs per VTS are coded TOP first while tff reads 0 on all of them;
# ffmpeg independently reports top_field_first=1; and a pixel-level field-
# sequence total-variation measurement scores TOP-first 1.3-1.5x smoother with a
# zig-zag figure of 0.04 against 0.6. Design: docs/field_parity.md.
#
# WHAT IS SCORED: motcomp_picbuf's OUTPUT PIN output_top_field_first at each
# presented frame -- the value dvd/resample_addrgen.v orders the fields from --
# against a truth derived independently in Python from the SPEC (coded parity +
# 6.1.1.11's display reorder). Never the signal the fix names.
#
# THE FIXTURES ARE NOT COMMITTED, and deliberately: bench/dvd/test_vobs/ is
# gitignored and only freely-redistributable cuts (the VCD/SVCD and BBB material)
# are force-added. These are cuts of a commercial disc, like seek_realign.hex and
# m1v_test.hex, so they are regenerated locally.
#
# ⚠ AND NOT FROM JUST ANY DISC. This gate needs a FIELD-CODED one, which is a
# small genre (laserdisc-era interactive FMV): Thayer's Quest, Dragon's Lair II,
# Mad Dog McCree 2, Time Traveler, plus a few older films. Point FIELD_ORDER_ISO
# at one; `tools/video_cadence_census.py --field-order --all-vts <iso>` says
# whether a candidate qualifies, and which VTS to cut from. Without a fixture
# every arm SKIPs loudly rather than passing on an empty array.
#
#   ./bench/dvd/run_field_order.sh          # GREEN arms + controls + mutations
#   ./bench/dvd/run_field_order.sh --red    # also the RED arm first (must FAIL)
set -uo pipefail
cd "$(dirname "$0")/../.."

ISO_DIR="${DVD_ISO_DIR:-$HOME/dvd-isos}"
FLD=bench/dvd/test_vobs/field_order_thayer
FRM=bench/dvd/test_vobs/field_order_frame
IV="iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2"
RTL="rtl/mpeg2/vld.v rtl/mpeg2/getbits.v rtl/mpeg2/motcomp_picbuf.v"
TB=bench/dvd/field_order_tb.sv
rc=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---- fixtures -----------------------------------------------------------------
# field_order_fixture.py REFUSES a cut that is not field-coded, or whose pairs are
# mostly BOTTOM-first (the pre-fix ordering is accidentally right on those): such a
# fixture would make the RED arm measure ~0 and the whole gate vacuous. Walk the
# VTSes until one qualifies rather than trusting a guess.
if [ ! -f "$FLD.hex" ] && [ -n "${FIELD_ORDER_ISO:-}" ] && [ -f "$FIELD_ORDER_ISO" ]; then
  echo "== cutting a FIELD-coded fixture from $(basename "$FIELD_ORDER_ISO") =="
  for v in 1 2 3 5 7 10 11; do
    if python3 tools/field_order_fixture.py "$FIELD_ORDER_ISO" --vts $v --sectors 260          --out "$FLD" 2>/dev/null; then break; fi
  done
  echo "== cutting a FRAME-coded control from the same disc =="
  for v in 9 11 1 2; do
    if python3 tools/field_order_fixture.py "$FIELD_ORDER_ISO" --vts $v --sectors 260          --frame-coded --out "$FRM" 2>/dev/null; then break; fi
  done
fi

if [ ! -f "$FLD.hex" ] || [ ! -f "$FRM.hex" ]; then
  echo "== field_order: SKIPPED -- fixtures missing (they are not committed)."
  echo "   This gate needs a FIELD-CODED disc; the genre is laserdisc-era FMV"
  echo "   (Thayer's Quest, Dragon's Lair II, Mad Dog 2, Time Traveler)."
  echo "   Check a candidate:"
  echo "     tools/video_cadence_census.py --field-order --all-vts <iso>"
  echo "   Then either:"
  echo "     FIELD_ORDER_ISO=<iso> $0 ${1:-}"
  echo "   or build them by hand:"
  echo "     tools/field_order_fixture.py <iso> --vts 1 --sectors 260 --out $FLD"
  echo "     tools/field_order_fixture.py <iso> --vts 9 --sectors 260 --frame-coded --out $FRM"
  exit 0
fi

run() {  # sim  args...  -> echoes the SUMMARY/RESULT lines, returns the verdict
  local sim=$1; shift
  timeout 900 vvp "$sim" "$@" 2>&1 | grep -vE '^WARNING'
}

$IV -o "$TMP/green_sim" $RTL $TB || { echo "build failed"; exit 1; }
$IV -Pfield_order_tb.SEAM=0 -o "$TMP/red_sim" $RTL $TB || { echo "build failed"; exit 1; }

# ---- RED: the PRE-FIX SEAM on the real shipped modules -----------------------
# Not a hand-made mutation: SEAM=0 feeds picbuf vld's RAW top_field_first, which
# is exactly what rtl/mpeg2/mpeg2video.v did before the fix.
if [ "${1:-}" = "--red" ]; then
  echo "== RED (SEAM=0, the pre-fix wiring): must FIND the defect =="
  out=$(run "$TMP/red_sim" +ES=$FLD.hex +TRUTH=$FLD.truth)
  echo "$out" | grep -E 'MISMATCH|SUMMARY|RESULT' | head -8
  if echo "$out" | grep -q '^RESULT: FAIL'; then
    echo "  RED ok -- every displayed picture shown BOTTOM-first on a TOP-first disc"
  else
    echo "  *** RED DID NOT REPRODUCE -- the gate is vacuous ***"; rc=1
  fi
fi

echo "== [1] GREEN: field-coded content displays the parity the disc coded first =="
run "$TMP/green_sim" +ES=$FLD.hex +TRUTH=$FLD.truth | grep -E 'SUMMARY|RESULT' || rc=1

echo "== [2] IMMOVABILITY: frame-coded content must be IDENTICAL under both seams =="
echo "==     (this is why 291 of 296 sampled discs cannot be moved by the change) =="
run "$TMP/green_sim" +ES=$FRM.hex +TRUTH=$FRM.truth | grep -E 'SUMMARY|RESULT' \
    | sed 's/seam=[01]/seam=X/' > "$TMP/frm_green"
run "$TMP/red_sim"   +ES=$FRM.hex +TRUTH=$FRM.truth | grep -E 'SUMMARY|RESULT' \
    | sed 's/seam=[01]/seam=X/' > "$TMP/frm_red"
cat "$TMP/frm_green"
if ! grep -q '^RESULT: PASS' "$TMP/frm_green"; then
  echo "  FAIL: the frame-coded control does not pass"; rc=1
elif diff -q "$TMP/frm_green" "$TMP/frm_red" >/dev/null; then
  echo "  identical under both seams -- frame-coded content cannot move"
else
  echo "  FAIL: the seam changed frame-coded behaviour"; diff "$TMP/frm_green" "$TMP/frm_red"; rc=1
fi

echo "== [3] MPEG-1 control: no coding extension, so every picture stays BOTTOM-first =="
if [ -f bench/dvd/test_vobs/m1v_test.hex ]; then
  run "$TMP/green_sim" +ES=bench/dvd/test_vobs/m1v_test.hex +EXPECT=0 +MAXPIC=40 \
      | grep -E 'SUMMARY|RESULT' || rc=1
else
  echo "  SKIPPED -- m1v_test.hex missing"
fi

echo "== [4] DROP arm: field pairs drop ATOMICALLY, so the order must survive it =="
run "$TMP/green_sim" +ES=$FLD.hex +TRUTH=$FLD.truth +REQ=1 | grep -E 'SUMMARY|RESULT' || rc=1

# ---- the SEAM itself: no module bench can see a wrong port connection --------
echo "== [5] the seam in rtl/mpeg2/mpeg2video.v =="
python3 tools/check_field_order_wiring.py || rc=1

# ---- MUTATIONS: each must FAIL, and only its own arm -------------------------
# ⚠ No mutation for the ~drop_this_picture term in vld.v's latch: it is defence
# in depth, not load-bearing (a dropped picture's value is always overwritten by
# the next slot owner before anything is emitted), so no arm can catch its
# removal. Saying so beats inventing an arm that cannot fail.
echo "== MUTATIONS (each must FAIL its own arm) =="
# The five are independent, so run them concurrently: serially this section is
# ~5x the runtime of every other arm put together.
RESDIR=$(mktemp -d); trap 'rm -rf "$TMP" "$RESDIR"' EXIT
mut() { _mut_one "$@" & }
_mut_one() {  # name  old  new  which-fixture  expect-regex
  local name=$1 old=$2 new=$3 fix=$4 want=$5
  local d="$TMP/$name"; mkdir -p "$d"
  python3 - "$d" "$old" "$new" <<'PYEOF' || { echo "  $name: anchor not found" > "$RESDIR/$name"; return; }
import sys
d, old, new = sys.argv[1:4]
s = open('rtl/mpeg2/vld.v').read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(d + '/vld.v', 'w').write(s.replace(old, new))
PYEOF
  $IV -o "$d/sim" "$d/vld.v" rtl/mpeg2/getbits.v rtl/mpeg2/motcomp_picbuf.v $TB \
      >/dev/null 2>&1 || { echo "  $name: BUILD FAILED (a mutation that does not compile proves nothing)" > "$RESDIR/$name"; return; }
  local out
  if [ "$fix" = "mpeg1" ]; then
    out=$(run "$d/sim" +ES=bench/dvd/test_vobs/m1v_test.hex +EXPECT=0 +MAXPIC=40)
  else
    out=$(run "$d/sim" +ES=$fix.hex +TRUTH=$fix.truth)
  fi
  if echo "$out" | grep -qE "$want"; then
    echo "  $name: caught ($(echo "$out" | grep -oE 'mismatches=[0-9]+' | head -1))" > "$RESDIR/$name"
  else
    { echo "  $name: *** NOT CAUGHT -- the bench cannot see this defect ***"
      echo "$out" | grep -E 'SUMMARY|RESULT' | head -2
      echo "MUTFAIL"; } > "$RESDIR/$name"
  fi
}

EXPR_OLD='(getbits[21:20] == FRAME_PICTURE) ? getbits[19]                 // frame picture: the syntax element means what it says
                                                           : (getbits[21:20] == TOP_FIELD); // field picture: the parity coded first'

# M1 -- THE DEFECT ITSELF, in the vld this time: order from tff alone.
mut M1 "$EXPR_OLD" "getbits[19];" "$FLD" '^RESULT: FAIL'
# M2 -- drop the pic_hdr_upd gate. The pair's SECOND field then re-commits with
# the opposite parity and clobbers the answer on every pair. This is the arm that
# proves that gate is load-bearing.
mut M2 "(state == STATE_PICTURE_CODING_EXT0) && pic_hdr_upd && ~drop_this_picture" \
       "(state == STATE_PICTURE_CODING_EXT0) && ~drop_this_picture" "$FLD" '^RESULT: FAIL'
# M3 -- test the wrong parity.
mut M3 "(getbits[21:20] == TOP_FIELD); // field picture" \
       "(getbits[21:20] == BOTTOM_FIELD); // field picture" "$FLD" '^RESULT: FAIL'
# M4 -- invert the frame/field discrimination: FRAME pictures lose their tff.
#       Caught by the IMMOVABILITY fixture, which proves that arm has teeth.
mut M4 "(getbits[21:20] == FRAME_PICTURE) ? getbits[19]" \
       "(getbits[21:20] != FRAME_PICTURE) ? getbits[19]" "$FRM" '^RESULT: FAIL'
# M5 -- drop the mpeg1 arm.
mut M5 "else if (clk_en && mpeg1 && (state == STATE_PICTURE_HEADER)) first_field_top <= 1'b0;" \
       "else if (1'b0) first_field_top <= 1'b0;" "mpeg1" '^RESULT: FAIL'

wait
for f in M1 M2 M3 M4 M5; do
  if [ -f "$RESDIR/$f" ]; then cat "$RESDIR/$f"; grep -q MUTFAIL "$RESDIR/$f" && rc=1
  else echo "  $f: NO RESULT"; rc=1; fi
done

echo
[ $rc -eq 0 ] && echo "run_field_order: ALL GREEN" || echo "run_field_order: FAILURES (rc=$rc)"
exit $rc
