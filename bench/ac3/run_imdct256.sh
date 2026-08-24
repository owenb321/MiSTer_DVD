#!/usr/bin/env bash
# Build + run the imdct_512 SHORT-path (256-pt, blksw==1) unit test under Icarus.
#
# Step 0 regenerates dvd/ac3/ac3_imdct_tables.svh (gen_imdct_tables.c self-checks
# BOTH the long ifft128 schedule vs a52_imdct_512 and the short two-ifft64
# schedule vs a52_imdct_256 before emitting).  Step 1 builds the short golden
# vector (gen_imdct256_vec.c calls a52_imdct_256 for two channels of random Q1.23
# coeffs).  Step 2 runs the RTL TB with blksw=1, checking every Q8.23 output
# sample against the requantized liba52 golden with a bounded-error tolerance.
#
# Usage: bench/ac3/run_imdct256.sh [--dump]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/bench/ac3/obj"
mkdir -p "$OUT"

DUMP_ARG=""
[[ "${1:-}" == "--dump" ]] && DUMP_ARG="+dump"

# 0) regenerate the IMDCT tables + schedules (self-checks vs liba52, both paths).
cc -O2 -Wall -o "$OUT/gen_imdct_tables" "$ROOT/bench/ac3/gen_imdct_tables.c" -la52 -lm
( cd "$ROOT/dvd/ac3" && "$OUT/gen_imdct_tables" ac3_imdct_tables.svh )

# 1) generate the short golden vector with liba52 (mem files land in $OUT).
cc -O2 -Wall -o "$OUT/gen_imdct256_vec" "$ROOT/bench/ac3/gen_imdct256_vec.c" -la52 -lm
( cd "$OUT" && ./gen_imdct256_vec )

# 2) build + run the RTL TB (reads the mem files from $OUT, so run there).
# -D AC3_COSIM exposes imdct_512's combinational pcm verification tap (the TB
# reads pcm asynchronously; in hardware that read is a registered M10K read).
iverilog -g2012 -Wall -D AC3_COSIM \
    -I "$ROOT/dvd/ac3" \
    -o "$OUT/imdct_256_sim" \
    "$ROOT/dvd/ac3/imdct_512.sv" \
    "$ROOT/bench/ac3/imdct_256_tb.sv"

( cd "$OUT" && vvp "$OUT/imdct_256_sim" $DUMP_ARG )
