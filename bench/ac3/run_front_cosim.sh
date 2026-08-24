#!/usr/bin/env bash
# Build the Verilator/liba52 co-sim and run it on all generated test streams.
# Regenerates the streams first if they are missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT/bench/ac3"

if ! ls "$ROOT"/tools/streams/*.ac3 >/dev/null 2>&1; then
    echo "[streams] generating test streams"
    "$ROOT/tools/gen_test_stream.sh" >/dev/null
fi

make -f Makefile.cosim >/dev/null

rc=0
for s in "$ROOT"/tools/streams/*.ac3; do
    echo "=== $(basename "$s") ==="
    ./obj_cosim/ac3_front_cosim "$s" || rc=1
done

# Committed vectors that ffmpeg cannot generate (short blocks).  bbb_short_5p1
# exercises the M16 256-pt short transform; run extra frames so multiple short
# blocks are covered (PCM is informational — see bench/ac3/vectors/README.md).
for s in "$ROOT"/bench/ac3/vectors/*.ac3; do
    [ -e "$s" ] || continue
    echo "=== $(basename "$s") (committed; short-block vector) ==="
    AC3_MAX_FRAMES=18 ./obj_cosim/ac3_front_cosim "$s" || rc=1
done
exit $rc
