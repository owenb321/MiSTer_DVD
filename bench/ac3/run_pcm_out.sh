#!/usr/bin/env bash
# Build + run the pcm_out unit test under Icarus Verilog.
#
# pcm_out is the M9 output stage: it drains a block of Q8.23 PCM (imdct_512.
# pcm_mem) into an s16 L/R stream across an asynchronous (Gray-pointer) CDC FIFO,
# paced by a ~48 kHz clock-enable.  The TB drives the two clock domains
# asynchronously, forces a FIFO overrun (small FIFO_AW) to exercise the stall +
# pointer wrap, and checks the Q8.23->s16 format/saturation against an
# independent real-arithmetic reference, plus L/R ordering and underflow-hold.
# No liba52 needed.
#
# Usage: bench/ac3/run_pcm_out.sh [--dump]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/bench/ac3/obj"
mkdir -p "$OUT"

DUMP_ARG=""
[[ "${1:-}" == "--dump" ]] && DUMP_ARG="+dump"

iverilog -g2012 -Wall \
    -I "$ROOT/dvd/ac3" \
    -o "$OUT/pcm_out_sim" \
    "$ROOT/dvd/ac3/pcm_out.sv" \
    "$ROOT/bench/ac3/pcm_out_tb.sv"

vvp "$OUT/pcm_out_sim" $DUMP_ARG
