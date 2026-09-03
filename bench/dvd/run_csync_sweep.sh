#!/usr/bin/env bash
#
# run_csync_sweep.sh — A/B the composite-sync separator models across vsync
# placements and integrator time constants (bench/dvd/csync_field_tb.sv).
#
#   run_csync_sweep.sh [<older-syncgen.v>]
#
# Runs the shipped rtl/mpeg2/syncgen.v with the shipped window (243/246), and —
# if an older syncgen.v is given (e.g. `git show <rev>:rtl/mpeg2/syncgen.v >
# /tmp/syncgen_old.v`) — that one with the pre-anchoring window (244/247), for
# tau = 10/20/40/80 us. Prints the first-broad-pulse widths, the width-detector
# spacings and the RC-integrator spacings; no pass/fail (the width detector is
# the gated criterion in run_csync_field.sh).
set -e
cd "$(dirname "$0")/../.."
bash bench/dvd/run_csync_field.sh >/dev/null 2>&1 || true   # (re)generate csync_ref_gen.v
OLD="$1"
iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/csync_sweep_new_sim \
  rtl/mpeg2/syncgen.v bench/dvd/csync_ref_gen.v bench/dvd/csync_field_tb.sv
if [ -n "$OLD" ]; then
  iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/csync_sweep_old_sim \
    "$OLD" bench/dvd/csync_ref_gen.v bench/dvd/csync_field_tb.sv
fi
for tau in 10 20 40 80; do
  echo "### tau=${tau}us shipped syncgen, window 243/246 (hsync-anchored)"
  vvp bench/dvd/csync_sweep_new_sim +tau_us=$tau 2>&1 \
    | grep "first broad\|integrator\|broad-pulse detector" | sed 's/csync_field_tb: //'
  if [ -n "$OLD" ]; then
    echo "### tau=${tau}us $OLD, window 244/247 (dot-0 reference)"
    vvp bench/dvd/csync_sweep_old_sim +tau_us=$tau +vss=244 +vse=247 2>&1 \
      | grep "first broad\|integrator\|broad-pulse detector" | sed 's/csync_field_tb: //'
  fi
done
