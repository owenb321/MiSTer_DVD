#!/usr/bin/env bash
# Build + run the AC-3 front-end chain unit test under Icarus Verilog:
# FIFO -> bit_reader -> sync_crc -> bsi_parse -> body skip, on a synthetic
# two-frame stream (each frame carries a real syncinfo header and BSI).
#
# Usage: bench/ac3/run_sync_crc.sh [--dump]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/bench/ac3/obj"
mkdir -p "$OUT"

DUMP_ARG=""
[[ "${1:-}" == "--dump" ]] && DUMP_ARG="+dump"

iverilog -g2012 -Wall \
    -I "$ROOT/dvd/ac3" \
    -o "$OUT/ac3_front_sim" \
    "$ROOT/dvd/ac3/bit_fifo.sv" \
    "$ROOT/dvd/ac3/bit_reader.sv" \
    "$ROOT/dvd/ac3/sync_crc.sv" \
    "$ROOT/dvd/ac3/bsi_parse.sv" \
    "$ROOT/dvd/ac3/audblk_parse.sv" \
    "$ROOT/dvd/ac3/exponent_decode.sv" \
    "$ROOT/dvd/ac3/bit_allocation.sv" \
    "$ROOT/dvd/ac3/mantissa_dequant.sv" \
    "$ROOT/dvd/ac3/imdct_512.sv" \
    "$ROOT/dvd/ac3/ac3_parse.sv" \
    "$ROOT/dvd/ac3/ac3_front.sv" \
    "$ROOT/bench/ac3/ac3_front_tb.sv"

vvp "$OUT/ac3_front_sim" $DUMP_ARG
