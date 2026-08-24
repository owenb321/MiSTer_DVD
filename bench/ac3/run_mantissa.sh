#!/usr/bin/env bash
# Build + run the mantissa_dequant unit test under Icarus Verilog:
# FIFO -> bit_reader -> mantissa_dequant on a hand-shaped two-channel problem.
#
# gen_mant_vec.c walks the coefficients exactly as the RTL reads them, emitting
# the mantissa bitstream plus two goldens: an exact Q1.23 target (same rounded
# level ROMs + (m16<<8)>>exp truncation as the RTL) checked bit-for-bit, and
# liba52's float reconstruction (Q1.23) used to bound the quantization error.
# The vector covers every bap class (zero, dither, q1/q2/q4 grouped, q3/q5
# direct tables, direct widths 5..16) and a grouped run that straddles the
# ch0->ch1 boundary so the shared quantizer cache must persist across channels.
#
# Usage: bench/ac3/run_mantissa.sh [--dump]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/bench/ac3/obj"
mkdir -p "$OUT"

DUMP_ARG=""
[[ "${1:-}" == "--dump" ]] && DUMP_ARG="+dump"

# 1) generate the bitstream + goldens (mem files land in $OUT).  No liba52 link
#    needed — the golden replicates liba52's coeff_get math directly.
cc -O2 -o "$OUT/gen_mant_vec" "$ROOT/bench/ac3/gen_mant_vec.c" -lm
( cd "$OUT" && ./gen_mant_vec )

# 2) build + run the RTL TB (reads the mem files from $OUT, so run there).
iverilog -g2012 -Wall -D AC3_COSIM \
    -I "$ROOT/dvd/ac3" \
    -o "$OUT/mantissa_dequant_sim" \
    "$ROOT/dvd/ac3/bit_fifo.sv" \
    "$ROOT/dvd/ac3/bit_reader.sv" \
    "$ROOT/dvd/ac3/mantissa_dequant.sv" \
    "$ROOT/bench/ac3/mantissa_dequant_tb.sv"

( cd "$OUT" && vvp "$OUT/mantissa_dequant_sim" $DUMP_ARG )
