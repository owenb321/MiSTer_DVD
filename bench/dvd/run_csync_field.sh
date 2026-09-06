#!/usr/bin/env bash
#
# run_csync_field.sh — composite-sync field symmetry of the interlaced main raster
# (bench/dvd/csync_field_tb.sv; docs/single_raster_analog.md §3.8, §3.10).
#
#   bash bench/dvd/run_csync_field.sh          all three arms, NTSC and PAL
#   bash bench/dvd/run_csync_field.sh --red    every RED arm must FAIL
#
# The framework `csync` module and sys_top's CS_PIPE are extracted from sys/sys_top.v
# at run time (bench/dvd/csync_extract.sh) so the bench always tests the REAL code.
set -e
cd "$(dirname "$0")/../.."
. bench/dvd/csync_extract.sh
csync_extract "$PWD"

SIM=bench/dvd/csync_field_sim
SRC_GEN=dvd/csync_smpte.sv

build() {   # $1 = generator source to compile
  iverilog -g2012 -I rtl/mpeg2 -o "$SIM" \
    rtl/mpeg2/syncgen.v "$1" bench/dvd/csync_ref_gen.v bench/dvd/csync_field_tb.sv
}

# ---------------------------------------------------------------------------
# RED: each mutation must make the bench FAIL. Three are sed-mutated copies of the
# generator (the bench cannot mutate a module it merely instantiates), one is a
# TB-side plusarg. Without these, [G4] and [G5] are assertions nobody has shown can
# fire — the failure mode that let the field-parity corrector defect ship green
# (docs/single_raster_analog.md §3.9).
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--red" ]; then
  mut=bench/dvd/csync_smpte_red.sv
  fails=0

  red_case() {   # $1 = label, $2 = sed program (empty for none), $3 = extra plusargs
    echo "== RED [$1] =="
    if [ -n "$2" ]; then sed "$2" "$SRC_GEN" > "$mut"; else cp "$SRC_GEN" "$mut"; fi
    # ⚠ A sed pattern that no longer matches the source silently produces an UNMUTATED
    # copy, which then passes — a RED arm that quietly became a second GREEN arm. This has
    # already happened once here (a `fpar` -> `fpar_now` rename in the module), so it is a
    # hard failure, not a warning.
    if [ -n "$2" ] && cmp -s "$mut" "$SRC_GEN"; then
      echo "  FAIL: the mutation did not apply — the pattern no longer matches $SRC_GEN"
      fails=$((fails+1)); return
    fi
    build "$mut"
    if vvp "$SIM" $3 > bench/dvd/csync_red_arm.log 2>&1; then
      echo "  FAIL: the RED arm PASSED — the bench cannot detect this defect"
      grep -E "^(PASS|FAIL|csync_field_tb: \[)" bench/dvd/csync_red_arm.log | head -6
      fails=$((fails+1))
    else
      echo "  failed as required:"
      grep -E "^FAIL" bench/dvd/csync_red_arm.log | head -3 | sed 's/^/    /'
    fi
  }

  # 1. Block anchored on the plain line grid: field B loses its half-line offset, so
  #    the two fields no longer present the same waveform and the separators no longer
  #    see 262.5 lines. Breaks [G5] and [G6] — the stock defect, reintroduced.
  red_case "grid: block not offset by a half-line on field B" \
           's/+ {11.d0, fpar_now};/+ 12'"'"'d0;/' "+arm=0"
  # 2. Equalizing pulses emitted at broad-pulse width. Breaks [G4] only — the gate that
  #    checks we built the SPECIFIED shape rather than merely a symmetric one.
  red_case "eqwide: equalizing pulses at broad width" \
           's/is_broad ? broad_w : eq_w;/is_broad ? broad_w : broad_w;/' "+arm=0"
  # 3. The pre-equalizing segment dropped: the 2H shape presented as SMPTE.
  red_case "nopre: no pre-equalizing pulses" \
           's/wire \[3:0\]  n_pre   = smpte ? (pal ? SEG_P : SEG_N) : 4.d0;/wire [3:0]  n_pre   = 4'"'"'d0;/' "+arm=0"
  # 4. One extra clock of pipeline on the generated bit. Breaks [G1\/G3] — the
  #    integration mistake a pulse-shape census would never see.
  red_case "lag: generated sync one clock late" "" "+arm=0 +red_lag=1"

  rm -f "$mut"
  if [ "$fails" -ne 0 ]; then echo "RED SUITE FAILED: $fails arm(s) passed when they must fail"; exit 1; fi
  echo "RED suite OK: every mutation was caught."
  exit 0
fi

# ---------------------------------------------------------------------------
# GREEN
# ---------------------------------------------------------------------------
build "$SRC_GEN"
names=(SMPTE 2H Stock)
fails=0
for pal in 0 1; do
  for arm in 0 1 2; do
    echo "== ${names[$arm]} $( [ $pal = 1 ] && echo 'PAL 576i' || echo 'NTSC 480i') =="
    # Every arm runs even if an earlier one failed: when the sync shape is wrong it is
    # usually wrong in a way the OTHER arms' numbers explain, and aborting on the first
    # throws that away.
    if vvp "$SIM" +arm=$arm +pal=$pal; then :; else fails=$((fails+1)); fi
  done
done
if [ "$fails" -ne 0 ]; then echo "csync_field: $fails arm(s) FAILED"; exit 1; fi
echo "csync_field: all 6 arms green."
