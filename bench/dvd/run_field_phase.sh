#!/usr/bin/env bash
#
# run_field_phase.sh — do the two displayed fields carry DIFFERENT source lines,
# on the matching raster parity? (bench/dvd/field_phase_tb.sv; docs/field_parity.md.)
#
# This is the bench that can see the HW defect field_parity_tb could not: it feeds the
# behavioural framestore LINE-STAMPED data and measures what the mixer EMITTED for
# consecutive fields, instead of restating the RTL's own parity convention. It is the
# gate for the field-parity corrector (issue #41).
#
# It checks three invariants per window (see the testbench header):
#   A  consecutive fields must carry DIFFERENT source lines  (the +0.50 field offset a
#      real interlaced still measures; the withdrawn corrector made it +0.00)
#   B  the emitted content repeats with period 2
#   C  an even (top) source line lands in an even (top) raster field — derived from the
#      DATA, so it does not agree with the RTL by construction
#
# Both raster-phase arms must pass. Add +dbg to either vvp line for a per-field table.
#
# Runtime: ~10 minutes per arm. Most of it is scenario [1] and [7], whose settle windows
# have to be long enough for the FEEDBACK arm to confirm (PAR_CONFIRM refreshes in
# dvd/resample_addrgen.v) — shortening them would make the bench green against a
# corrector that never heals.
set -e
cd "$(dirname "$0")/../.."

iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/field_phase_sim \
  rtl/mpeg2/resample.v dvd/resample_addrgen.v rtl/mpeg2/resample_dta.v \
  rtl/mpeg2/resample_bilinear.v rtl/mpeg2/mem_addr.v rtl/mpeg2/mixer.v \
  rtl/mpeg2/pixel_queue.v rtl/mpeg2/syncgen.v rtl/mpeg2/read_write.v \
  rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xilinx_fifo_dc.v \
  rtl/mpeg2/xfifo_sc.v bench/dvd/field_phase_tb.sv

# ⚠ `vvp ... | grep ... || fail=1` reads GREP's exit status, never vvp's: a $fatal arm
# prints FAIL, exits non-zero, and the pipe swallows it while the suite reports success.
# That is the defect PR #63 fixed in the STC field suites (a9b8bb6); it was still here.
# PIPESTATUS[0] is the simulator's own status.
fail=0
for p in 0 1; do
  echo
  echo "============ +phase=$p ============"
  vvp bench/dvd/field_phase_sim +phase=$p | grep -vE '^\s*$'; [ "${PIPESTATUS[0]}" -eq 0 ] || fail=1
done

# ---- P1O[48] Field Order = Swap ------------------------------------------------------
# The knob XORs mpeg2video's sync_raster_par_err, which is equivalent to inverting
# mixer.v's content-vs-raster parity comparison. This arm inverts check C's expectation
# with it and leaves A and B alone, so it proves the content really does land in the
# OTHER raster slot AND that alternation survives — a swap that broke the interleave
# would be a regression, not a diagnostic. One phase is enough: the knob is a polarity,
# not a timing change. Add --swap-only to run just this arm.
if [ "${1:-}" != "--no-swap" ]; then
  echo
  echo "============ +swap=1 (Field Order = Swap) ============"
  vvp bench/dvd/field_phase_sim +phase=0 +swap=1 | grep -vE '^\s*$'; [ "${PIPESTATUS[0]}" -eq 0 ] || fail=1
fi
exit $fail
