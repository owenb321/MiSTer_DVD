#!/usr/bin/env bash
# Build + run the bit_allocation unit test under Icarus Verilog.
#
# gen_balloc_vec.c builds a hand-picked two-channel problem (varied exponents,
# realistic BAI/SNR sub-codes, plus a DELTA_BIT_NEW channel) and calls liba52's
# exported a52_bit_allocate() to emit the golden bap + the shared exp/deltba/
# param mem files.  bit_allocation_tb.sv then drives the RTL from those mem
# files and checks every bap against the golden — bit-exact (integer stage).
#
# Usage: bench/ac3/run_balloc.sh [--dump]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/bench/ac3/obj"
mkdir -p "$OUT"

DUMP_ARG=""
[[ "${1:-}" == "--dump" ]] && DUMP_ARG="+dump"

# 1) generate the golden + input vectors with liba52 (mem files land in $OUT).
cc -O2 -o "$OUT/gen_balloc_vec" "$ROOT/bench/ac3/gen_balloc_vec.c" -la52
( cd "$OUT" && ./gen_balloc_vec )

# 2) build + run the RTL TB (reads the mem files from $OUT, so run there).
iverilog -g2012 -Wall -D AC3_COSIM \
    -I "$ROOT/dvd/ac3" \
    -o "$OUT/bit_allocation_sim" \
    "$ROOT/dvd/ac3/bit_allocation.sv" \
    "$ROOT/bench/ac3/bit_allocation_tb.sv"

( cd "$OUT" && vvp "$OUT/bit_allocation_sim" $DUMP_ARG )
