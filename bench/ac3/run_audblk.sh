#!/usr/bin/env bash
# Build + run the audblk_parse unit test under Icarus Verilog:
# FIFO -> bit_reader -> audblk_parse on a hand-built block side-info bitstream.
# Checks the exact consumed bit count, every staged side-info field, the packed
# exponents in the staging RAM, and the three scope asserts (short/cpl/remat).
#
# Usage: bench/ac3/run_audblk.sh [--dump]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/bench/ac3/obj"
mkdir -p "$OUT"

DUMP_ARG=""
[[ "${1:-}" == "--dump" ]] && DUMP_ARG="+dump"

iverilog -g2012 -Wall \
    -I "$ROOT/dvd/ac3" \
    -o "$OUT/audblk_parse_sim" \
    "$ROOT/dvd/ac3/bit_fifo.sv" \
    "$ROOT/dvd/ac3/bit_reader.sv" \
    "$ROOT/dvd/ac3/audblk_parse.sv" \
    "$ROOT/bench/ac3/audblk_parse_tb.sv"

vvp "$OUT/audblk_parse_sim" $DUMP_ARG
