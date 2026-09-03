#!/usr/bin/env bash
#
# run_modeline_boot.sh — the boot-time modeline-walk reset race
# (bench/dvd/modeline_boot_tb.sv; found on HW round 1 of the Video Output
# consolidation: `Auto` + analog ini bits booted a progressive raster with
# VGA_F1 toggling and a dead CRT) — plus, since 2026-09-03, phase [4]: a
# watchdog expiry must not re-phase the running raster (the RGBS/YPbPr
# "shakes every second" reports; syncgen_intf's modeline copies moved off
# dot_rst onto the dot-domain hard reset).
#
# Default: the GREEN variant (+holdoff=1 +wdraster=1, matching dvd/emu.sv's
# dec_ready gate and rtl/mpeg2/mpeg2video.v's dot_hard_rst).
# --red: also run the two RED variants (expected to FAIL) for reference:
#   +holdoff=0  reproduces the pre-fix boot swallow
#   +wdraster=0 reproduces the watchdog raster re-phase
set -e
cd "$(dirname "$0")/../.."
iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/modeline_boot_sim \
  rtl/mpeg2/reset.v rtl/mpeg2/synchronizer.v rtl/mpeg2/regfile.v \
  rtl/mpeg2/mem_addr.v rtl/mpeg2/syncgen_intf.v rtl/mpeg2/syncgen.v \
  bench/dvd/modeline_boot_tb.sv
if [ "$1" = "--red" ]; then
  echo "### RED (boot race, +holdoff=0) — failure EXPECTED"
  vvp bench/dvd/modeline_boot_sim +holdoff=0 +wdraster=1 || true
  echo "### RED (watchdog raster, +wdraster=0) — failure EXPECTED"
  vvp bench/dvd/modeline_boot_sim +holdoff=1 +wdraster=0 || true
  echo "### GREEN"
fi
vvp bench/dvd/modeline_boot_sim +holdoff=1 +wdraster=1
