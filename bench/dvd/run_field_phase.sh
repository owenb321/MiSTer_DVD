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

fail=0
for p in 0 1; do
  echo
  echo "============ +phase=$p ============"
  vvp bench/dvd/field_phase_sim +phase=$p | grep -vE '^\s*$' || fail=1
done
exit $fail
