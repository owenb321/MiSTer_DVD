#!/usr/bin/env bash
#
# run_mode_realign.sh — the issue #42 gate: a mid-title `Video Output` change must
# re-align the reader instead of flushing mid-parse, and a garbage sequence header must
# not flip the PAL/NTSC verdict.
#
# Design: docs/single_raster_analog.md §6.  Modules: dvd/mode_realign.sv, dvd/pal_detect.sv.
#
# Default: the GREEN suite (the shipped RTL). Everything must pass.
#
# --red: run the PRE-FIX variants FIRST (failures EXPECTED, printed for reference), then
# the GREEN suite. The pre-fix behaviour is modelled inside each bench and selected by a
# plusarg, so one compile covers both arms:
#   mode_realign_tb       +realign=0  -> mode_switch straight into flush_ctl, no seek
#   mode_realign_chain_tb +realign=0  -> the reader never moves; the flush lands mid-VOBU
#   pal_detect_tb         +hyst=0     -> the old two-line verdict rule, verbatim
#
set -e
cd "$(dirname "$0")/../.."

echo "### build"
iverilog -g2012 -o bench/dvd/mode_realign_sim \
  dvd/mode_realign.sv bench/dvd/mode_realign_tb.sv
iverilog -g2012 -o bench/dvd/mode_realign_chain_sim \
  dvd/dvd_iso_reader.sv dvd/bcd_time_add.sv dvd/flush_ctl.sv dvd/mode_realign.sv \
  bench/dvd/mode_realign_chain_tb.sv
iverilog -g2012 -o bench/dvd/pal_detect_sim \
  dvd/pal_detect.sv bench/dvd/pal_detect_tb.sv
# The re-align rides the reader's existing raw-RBN seek + VOBU-snap contract, so that
# bench is part of this gate: TEST9 is the one-probe cost claim the design leans on.
iverilog -g2012 -o bench/dvd/iso_reader_seek_sim \
  dvd/dvd_iso_reader.sv dvd/bcd_time_add.sv bench/dvd/iso_reader_seek_tb.sv
# flush_ctl is unchanged by this work; its matrix (rows [7]-[9] = the fallback leg) is a
# regression, not a new test.
iverilog -g2012 -o bench/dvd/flush_ctl_sim \
  dvd/flush_ctl.sv bench/dvd/flush_ctl_tb.sv

if [ "$1" = "--red" ]; then
  echo
  echo "### RED — pre-fix variants, FAILURES EXPECTED"
  echo "--- mode_realign_tb +realign=0"
  vvp bench/dvd/mode_realign_sim +realign=0 || true
  echo "--- mode_realign_chain_tb +realign=0"
  vvp bench/dvd/mode_realign_chain_sim +realign=0 || true
  echo "--- pal_detect_tb +hyst=0"
  vvp bench/dvd/pal_detect_sim +hyst=0 || true
fi

echo
echo "### GREEN"
fail=0
for t in mode_realign mode_realign_chain pal_detect iso_reader_seek flush_ctl; do
  echo "--- $t"
  vvp "bench/dvd/${t}_sim" || fail=1
done
if [ "$fail" != "0" ]; then echo; echo "run_mode_realign.sh: FAILURES"; exit 1; fi
echo
echo "run_mode_realign.sh: all green"
