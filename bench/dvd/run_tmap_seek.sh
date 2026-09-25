#!/usr/bin/env bash
#
# run_tmap_seek.sh -- TIME seek through the disc's VTS time map (Phase 8b reopened,
# issue #127; dvd/dvd_iso_reader.sv S_TMAP; docs/dvd_nav.md "Time map seek").
#
#   ./bench/dvd/run_tmap_seek.sh          # GREEN: the TMAP bench + the reader
#                                         # scrub/seek benches it must not disturb
#   ./bench/dvd/run_tmap_seek.sh --red    # ...then one mutation per claim
#
# iso_reader_tmap_tb scores the LANDING SECTOR, read out of the delivered bytes
# (every fixture sector carries its own RBN), never a signal the lookup names.
# Each mutant must fail, and must fail the check NAMED for it (memory:
# bench-that-cannot-fail). A mutant that does not compile is BROKEN, not caught.
set -u -o pipefail
cd "$(dirname "$0")/../.."

IV="iverilog -g2012"
rc=0
SCR=$(mktemp -d)
trap 'rm -rf "$SCR"' EXIT
RD="dvd/dvd_iso_reader.sv dvd/bcd_time_add.sv"

run_tb() {   # name -> passes if its own PASS banner prints
  local tb=$1 banner=$2
  if $IV -o "$SCR/$tb" $RD "bench/dvd/$tb.sv" > "$SCR/$tb.build" 2>&1 \
     && vvp "$SCR/$tb" > "$SCR/$tb.log" 2>&1 && grep -q "$banner" "$SCR/$tb.log"; then
    echo "  ok   $tb"
  else
    echo "  FAIL $tb"; grep -E "FAIL|TIMEOUT|error" "$SCR/$tb.log" "$SCR/$tb.build" | head -5; rc=1
  fi
}

echo "### GREEN"
$IV -o "$SCR/tm" $RD bench/dvd/iso_reader_tmap_tb.sv 2>/dev/null || rc=1
vvp "$SCR/tm" > "$SCR/tm.log" 2>&1 || rc=1
grep -E "ok:|FAIL|PASSED" "$SCR/tm.log"
echo "-- the reader seek benches it must not disturb"
run_tb iso_reader_scrub_tb "ALL TESTS PASSED"
run_tb iso_reader_seek_tb  "ALL TESTS PASSED"
run_tb iso_reader_chapter_tb "PASS"
echo "-- scrub_ctrl: the held scrub counts seconds (T21-T27)"
if $IV -o "$SCR/sc" dvd/scrub_ctrl.sv bench/dvd/scrub_ctrl_tb.sv > /dev/null 2>&1 \
   && vvp "$SCR/sc" > "$SCR/sc.log" 2>&1 && grep -q "ALL TESTS PASSED" "$SCR/sc.log"; then
  echo "  ok   scrub_ctrl_tb"
else
  echo "  FAIL scrub_ctrl_tb"; grep FAIL "$SCR/sc.log" | head -5; rc=1
fi

# emu.sv has no bench: the seam that hands the reader its time is read out of the file.
echo "-- emu wiring"
python3 tools/check_tmap_seek_wiring.py || rc=1

[ "${1:-}" = "--red" ] || exit $rc

echo "### RED: the wiring gate must fail main's emu.sv and each re-regression"
python3 tools/check_tmap_seek_wiring.py --red || rc=1

echo "### RED (each mutant must fail its own check)"
mutant() {   # label, sed expression, grep for the check that must fail
  local label=$1 sedx=$2 want=$3
  local mut="$SCR/dvd_iso_reader.sv"
  sed -E "$sedx" dvd/dvd_iso_reader.sv > "$mut"
  if cmp -s "$mut" dvd/dvd_iso_reader.sv; then
    echo "  BROKEN $label: the sed matched nothing"; rc=1; return
  fi
  if ! $IV -o "$SCR/m" "$mut" dvd/bcd_time_add.sv bench/dvd/iso_reader_tmap_tb.sv > "$SCR/mb.log" 2>&1; then
    echo "  BROKEN $label: mutant does not compile (a build error is not a catch)"; rc=1; return
  fi
  timeout 600 vvp "$SCR/m" > "$SCR/m.log" 2>&1
  if grep -q "FAIL: $want" "$SCR/m.log"; then
    echo "  ok     $label -> $(grep "FAIL: $want" "$SCR/m.log" | head -1 | sed 's/^ *//' | cut -c1-110)"
  else
    echo "  MISSED $label: no 'FAIL: $want'"; grep FAIL "$SCR/m.log" | head -3; rc=1
  fi
}

mutant "M1 discontinuity bit not masked"   's/\{1.b0, vts_pgcit_ptr\[30:0\]\}/vts_pgcit_ptr/g' "A1"
mutant "M2 entry index off by one"          's/:                            \(tm_k - 16.d1\);/:                            tm_k;/' "A1"
mutant "M3 no plausibility check"           's/tm_hi > title_last_rbn \|\|/1'"'"'b0 ||/' "D "
mutant "M4 the header is never cached"      's/tm_ph <= tm_v \? TM_DIV : TM_MAT;/tm_ph <= TM_MAT;/' "A4"
mutant "M5 the cache survives a remount"    '/tm_v +<= 1.b0; +\/\/ a (new disc|new PGC)/d' "B1"
mutant "M6 no interpolation"                's/tm_q   <= \{tm_q\[30:0\], tm_qd_ge\};/tm_q   <= 32'"'"'d0;/' "B1"
mutant "M7 the time request is ignored"     's/seek_tm      <= seek_tm_req;/seek_tm      <= 1'"'"'b0;/' "A1"
mutant "M8 t=0 lands on entry 0"            's/\(tm_k == 16.d0\) \? title_start_rbn :/(1'"'"'b0) ? title_start_rbn :/' "A2"

echo "### RED: scrub_ctrl's time accumulator (each must fail its own arm)"
smutant() {  # label, sed expression, grep for the arm that must fail
  local label=$1 sedx=$2 want=$3
  local mut="$SCR/scrub_ctrl.sv"
  sed -E "$sedx" dvd/scrub_ctrl.sv > "$mut"
  if cmp -s "$mut" dvd/scrub_ctrl.sv; then echo "  BROKEN $label: the sed matched nothing"; rc=1; return; fi
  if ! $IV -o "$SCR/sm" "$mut" bench/dvd/scrub_ctrl_tb.sv > "$SCR/smb.log" 2>&1; then
    echo "  BROKEN $label: mutant does not compile"; rc=1; return; fi
  vvp "$SCR/sm" > "$SCR/sm.log" 2>&1
  if grep -q "FAIL: $want" "$SCR/sm.log"; then
    echo "  ok     $label -> $(grep "FAIL: $want" "$SCR/sm.log" | head -1 | sed 's/^ *//')"
  else
    echo "  MISSED $label: no 'FAIL: $want'"; grep FAIL "$SCR/sm.log" | head -3; rc=1
  fi
}
smutant "S1 the tier-0 time rate is wrong"   "s/TR0 = 12'd14/TR0 = 12'd16/" "T21"
smutant "S2 time seek without a live clock"  's/seek_tm_req <= tm_title \&\& t_ok;/seek_tm_req <= tm_title;/' "T27"
smutant "S3 no clamp at the title's end"     's/\(t_fwd > t_cap\) \? t_cap\[16:0\] :/1'"'"'b0 ? t_cap[16:0] :/' "T24"
smutant "S4 a flip keeps the old time"       '/^                    pend_t <= 22.d0;$/d' "T26"
smutant "S5 a jump inherits the scrub time"  '/t_ok         <= 1.b0;            \/\/ a jump/d' "T25"

exit $rc
