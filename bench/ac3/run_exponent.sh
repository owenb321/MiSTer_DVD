#!/usr/bin/env bash
# Build + run the exponent_decode unit test under Icarus Verilog:
# a behavioural packed-exp provider feeds grouped exponents + geometry directly
# to exponent_decode, which ungroups them (D15/D25/D45 + reuse) into absolute
# exponents; the TB checks every decoded exponent against a hand golden.
#
# Usage: bench/ac3/run_exponent.sh [--dump]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/bench/ac3/obj"
mkdir -p "$OUT"

DUMP_ARG=""
[[ "${1:-}" == "--dump" ]] && DUMP_ARG="+dump"

iverilog -g2012 -Wall -D AC3_COSIM \
    -I "$ROOT/dvd/ac3" \
    -o "$OUT/exponent_decode_sim" \
    "$ROOT/dvd/ac3/exponent_decode.sv" \
    "$ROOT/bench/ac3/exponent_decode_tb.sv"

vvp "$OUT/exponent_decode_sim" $DUMP_ARG
