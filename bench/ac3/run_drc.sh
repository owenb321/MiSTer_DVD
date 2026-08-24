#!/usr/bin/env bash
# Build + run the M17 DRC (dynrng) unit test under Icarus Verilog.
#
# Step 0 regenerates the IMDCT tables (shared with run_imdct.sh; self-checks vs
# liba52).  Step 1 builds the golden (gen_drc_vec.c: for several dynrng words
# spanning -24..+24 dB, a52_imdct_512 of coeffs pre-scaled by the canonical gain).
# Step 2 runs the RTL TB, which drives imdct_512 with the UNSCALED coeffs + each
# dynrng word and checks every Q8.23 output sample against the golden with a
# bounded-error tolerance (the unity 0x80 case is a bit-exact identity).
#
# Usage: bench/ac3/run_drc.sh [--dump]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/bench/ac3/obj"
mkdir -p "$OUT"

DUMP_ARG=""
[[ "${1:-}" == "--dump" ]] && DUMP_ARG="+dump"

# 0) regenerate the IMDCT tables + schedule (self-checks vs liba52).
cc -O2 -Wall -o "$OUT/gen_imdct_tables" "$ROOT/bench/ac3/gen_imdct_tables.c" -la52 -lm
( cd "$ROOT/dvd/ac3" && "$OUT/gen_imdct_tables" ac3_imdct_tables.svh )

# 1) generate the golden vector with liba52 (mem files land in $OUT).
cc -O2 -Wall -o "$OUT/gen_drc_vec" "$ROOT/bench/ac3/gen_drc_vec.c" -la52 -lm
( cd "$OUT" && ./gen_drc_vec )

# 2) build + run the RTL TB (reads the mem files from $OUT, so run there).
iverilog -g2012 -Wall -D AC3_COSIM \
    -I "$ROOT/dvd/ac3" \
    -o "$OUT/drc_sim" \
    "$ROOT/dvd/ac3/imdct_512.sv" \
    "$ROOT/bench/ac3/drc_tb.sv"

( cd "$OUT" && vvp "$OUT/drc_sim" $DUMP_ARG )
