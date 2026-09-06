#!/usr/bin/env bash
#
# run_csync_pipe.sh — does sys_top delay the core's VGA_CS by exactly the framework's
# own hsync latency? (bench/dvd/csync_pipe_tb.sv; docs/single_raster_analog.md §3.10)
#
# Measures VGA_HS -> composite sync through the REAL sys/scanlines.v, sys/osd.v and the
# `csync` extracted from sys/sys_top.v, and compares it against the CS_PIPE constant
# sys_top actually uses. --red proves the bench can fail.
set -e
cd "$(dirname "$0")/../.."
. bench/dvd/csync_extract.sh
csync_extract "$PWD"

build_and_run() {   # $1 = extra iverilog args, $2 = label
  iverilog -g2012 -I bench/dvd -I rtl/mpeg2 -o bench/dvd/csync_pipe_sim $1 \
    sys/scanlines.v sys/osd.v bench/dvd/csync_ref_gen.v bench/dvd/csync_pipe_tb.sv
  vvp bench/dvd/csync_pipe_sim
}

if [ "${1:-}" = "--red" ]; then
  # RED: claim a pipe depth one clock off and require the bench to notice. A latency
  # gate that passes for any value is worse than no gate at all.
  echo "== RED arm: CS_PIPE off by one =="
  sed -i 's/`define CS_PIPE_EXPECT \([0-9]*\)/`define CS_PIPE_EXPECT 99/' bench/dvd/csync_pipe_gen.vh
  if build_and_run "" red; then
    echo "FAIL: the RED arm PASSED — csync_pipe_tb cannot detect a wrong CS_PIPE"
    exit 1
  fi
  echo "RED arm failed as required."
  csync_extract "$PWD"        # restore the real value
  exit 0
fi

build_and_run "" green
