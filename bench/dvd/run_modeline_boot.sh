#!/usr/bin/env bash
#
# run_modeline_boot.sh — the boot-time modeline-walk reset race
# (bench/dvd/modeline_boot_tb.sv; found on HW round 1 of the Video Output
# consolidation: `Auto` + analog ini bits booted a progressive raster with
# VGA_F1 toggling and a dead CRT).
#
# Runs the GREEN variant (+holdoff=1, matching the emu.sv dec_ready gate).
# +holdoff=0 reproduces the pre-fix swallow (expected FAIL) for reference.
set -e
cd "$(dirname "$0")/../.."
iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/modeline_boot_sim \
  rtl/mpeg2/reset.v rtl/mpeg2/synchronizer.v rtl/mpeg2/regfile.v \
  rtl/mpeg2/mem_addr.v bench/dvd/modeline_boot_tb.sv
vvp bench/dvd/modeline_boot_sim +holdoff=1
