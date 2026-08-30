#!/usr/bin/env bash
# run_film_evidence.sh — the film evidence gate: measurement, then arithmetic.
#
# The gate exists because progressive_frame is the ENCODER's claim, not a
# measurement, and on a near-black picture the encoder has nothing to measure —
# so it marks the picture interlaced and the film detector falls out of lock.
# APOLLO_13's fading credits did that NINE times in 46 s. See docs/film_24p_plan.md §14.
#
# Runs:
#   1. film_evidence_tb — REAL getbits_fifo + vld over REAL disc bytes: does the
#      vld's per-picture size match tools/film_evidence_probe.py, and does its
#      informativeness verdict match the golden model, picture for picture?
#   2. film_detect_tb   — the detector arithmetic on top of that verdict.
#   3. cadence_slip_tb  — the cadence-slip corrector must be unaffected.
#
# The fixture is cut from a real disc and is NOT committed (bench/dvd/test_vobs/
# is gitignored). Point DVD_ISO_DIR at an ISO library containing APOLLO_13 and
# it regenerates; without one, step 1 SKIPS rather than silently passing.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

ISO_DIR="${DVD_ISO_DIR:-$HOME/dvd-isos}"
FIX=bench/dvd/test_vobs/film_ev
rc=0

# ---- 1. fixture + the measurement bench ------------------------------------
APOLLO=$(ls "$ISO_DIR"/APOLLO_13*.iso "$ISO_DIR"/APOLLO_13*.ISO 2>/dev/null | head -1 || true)
if [ -n "$APOLLO" ]; then
  echo "== cutting fixture from $(basename "$APOLLO") (credits, spans a fade) =="
  # start-frac lands in the opening credits, where black pictures code 384 B
  # against the title's own ~17 kB median — both populations in one cut.
  python3 tools/film_evidence_probe.py "$APOLLO" \
      --start-frac 0.0028 --sectors 240 --cut "$FIX" --cut-warm 2
elif [ ! -f "$FIX.hex" ]; then
  echo "== film_evidence_tb: SKIPPED — set DVD_ISO_DIR to a library containing APOLLO_13 =="
fi

if [ -f "$FIX.hex" ]; then
  echo "== film_evidence_tb (real vld + getbits over real disc bytes) =="
  iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/film_evidence_sim \
      rtl/mpeg2/vld.v rtl/mpeg2/getbits.v bench/dvd/film_evidence_tb.sv
  vvp bench/dvd/film_evidence_sim || rc=1
fi

# ---- 2/3. the arithmetic on top of the verdict -----------------------------
echo "== film_detect_tb (detector, incl. the gated-pickup cases) =="
iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/film_detect_sim \
    dvd/resample_addrgen.v rtl/mpeg2/mem_addr.v bench/dvd/film_detect_tb.sv
vvp bench/dvd/film_detect_sim || rc=1

echo "== cadence_slip_tb (corrector unaffected by the gate) =="
iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/cadence_slip_sim \
    dvd/resample_addrgen.v rtl/mpeg2/mem_addr.v bench/dvd/cadence_slip_tb.sv
vvp bench/dvd/cadence_slip_sim || rc=1

[ $rc -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES (rc=$rc) =="
exit $rc
