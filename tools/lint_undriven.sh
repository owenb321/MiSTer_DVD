#!/usr/bin/env bash
# lint_undriven.sh -- fail on any signal that is DECLARED, CONSUMED and NEVER DRIVEN.
#
# WHY (2026-09-07). Two defects of exactly this shape shipped in one feature and
# survived two hardware rounds:
#
#   dvd/emu.sv          dec_pts_in / dec_pts_in_valid were wired into mpeg2video
#                       and the CDC that drives them was never instantiated, so the
#                       decoder never received a video PTS at all.
#   resample_addrgen.v  frame_late was left `output reg` with its always block
#                       deleted by the Stage-1 governor surgery, so the entire
#                       lateness -> frame_drop_ctl ledger was dead.
#
# Neither is an implicit net -- both wires were properly declared -- so
# `default_nettype none` and the Quartus 10236 gate stay silent: those catch a
# missing DECLARATION, these were missing DRIVERS. Neither is visible in
# simulation either, because the module benches drive the input directly and there
# is no emu-level bench. Quartus ties the net low and everything downstream keeps
# compiling, fitting and running.
#
# ★ The file list comes from DVD.qsf, not from a glob. That matters: the fork
# swaps dvd/resample_addrgen.v in for rtl/mpeg2/resample_addrgen.v, and a glob
# lints whichever copy it happens to reach first -- i.e. possibly not the one that
# is built.
#
# Validated against the real defect: run over the commit before the pts_cdc fix it
# reports dec_pts_in and dec_pts_in_valid by name.
set -u
cd "$(dirname "$0")/.."

# Stock MiSTer framework, inside the `if(PS2DIV)` block that this core disables.
# Present since the upstream import; not ours, and not reachable.
ALLOW='kbd_data_host|mouse_data_host'

FILES=$(sed -n 's/^[[:space:]]*set_global_assignment[[:space:]]\+-name[[:space:]]\+\(VERILOG_FILE\|SYSTEMVERILOG_FILE\)[[:space:]]\+//p' DVD.qsf \
        | grep -vE '\.vhd$')
[ -n "$FILES" ] || { echo "lint_undriven: no source files found in DVD.qsf"; exit 2; }

OUT=$(verilator --lint-only -Wno-fatal --top-module emu -Wwarn-UNDRIVEN \
        +incdir+rtl/mpeg2 +incdir+dvd +incdir+dvd/ac3 +incdir+dvd/mem_override +incdir+sys \
        $FILES dvd/emu.sv 2>&1 | grep "Signal is not driven" | grep -vE "'($ALLOW)'")

if [ -n "$OUT" ]; then
  echo "lint_undriven: FAIL -- a declared, consumed signal has no driver."
  echo "  Quartus ties it low; every bench that drives it directly still passes."
  echo "$OUT" | sed 's/^/  /'
  exit 1
fi
echo "lint_undriven: PASS (no undriven signals outside the stock hps_io allowlist)"
