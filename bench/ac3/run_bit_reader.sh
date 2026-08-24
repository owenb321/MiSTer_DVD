#!/usr/bin/env bash
# Build + run the bit_reader unit test under Icarus Verilog.
# (Verilator-clean too; switch to a verilated harness once verilator is installed.)
#
# Usage: bench/ac3/run_bit_reader.sh [--dump]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/bench/ac3/obj"
mkdir -p "$OUT"

DUMP_ARG=""
[[ "${1:-}" == "--dump" ]] && DUMP_ARG="+dump"

iverilog -g2012 -Wall \
    -I "$ROOT/dvd/ac3" \
    -o "$OUT/bit_reader_sim" \
    "$ROOT/dvd/ac3/bit_reader.sv" \
    "$ROOT/bench/ac3/bit_reader_tb.sv"

vvp "$OUT/bit_reader_sim" $DUMP_ARG
