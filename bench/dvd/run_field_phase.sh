#!/usr/bin/env bash
#
# run_field_phase.sh — do the two displayed fields carry DIFFERENT source lines?
# (bench/dvd/field_phase_tb.sv; docs/single_raster_analog.md §3.10.)
#
# This is the bench that can see the HW defect field_parity_tb could not: it feeds the
# behavioural framestore address-derived data and compares what the mixer EMITTED for
# consecutive fields, instead of restating the RTL's own parity convention.
#
# Both raster-phase arms must pass.
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
