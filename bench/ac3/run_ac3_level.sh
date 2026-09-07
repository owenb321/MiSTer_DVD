#!/usr/bin/env bash
# run_ac3_level.sh -- END-TO-END output level gate for the AC-3 path.
#
# Decodes real .ac3 streams through ac3_front -> pcm_out and compares the s16
# output against a52dec's decode of the same file.
#
# ★ WHY THIS EXISTS.  Every other AC-3 gate compares pcm_mem, which sits BEFORE
#   pcm_out's level scalar -- so none of them can see an output-level error at
#   all.  That is exactly how this fork shipped 6.02 dB under every normal
#   decoder with a full board of green tests.  a52dec (liba52) is an INDEPENDENT
#   decoder, so this gate cannot pass by agreeing with our own arithmetic.
#
# ★ Both arms are run.  GREEN is the shipped scalar (expected ratio 1.0 -- we
#   match the reference).  RED forces lvl_q to unity via +lvl=16384, which is the
#   pre-fix datapath, and REQUIRES the measured ratio to be 0.5.  Without the RED
#   arm this would be a bench that cannot fail: a gate that only ever asserts
#   "we match" passes just as happily on a scalar of 1.0 as on the correct one.
#
# Requires: iverilog, a52dec.  Skips (rc 0) if a52dec is missing -- it is not
# part of the core toolchain.
#
# RUNTIME ~12 min, nearly all of it the 5.1 vector.  This is a verification gate,
# not a per-commit smoke test.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TOL_DB=0.15
# Sample pairs to capture per arm.  ★ This bounds the RUNTIME, which is dominated
# by the 5.1 vector: five IMDCTs per block means ~10 minutes for this many pairs,
# against seconds for stereo.  1792 is well past the leading silence and gives a
# few hundred loud samples, which is ample for a median.  Decoding whole files
# would push the suite past half an hour and nobody would run it.
NPAIRS=1792
OUT=bench/ac3/.level
mkdir -p "$OUT"
rc=0

if ! command -v a52dec >/dev/null 2>&1; then
    echo "run_ac3_level.sh: SKIP -- a52dec not installed (it is the reference decoder)"
    exit 0
fi

echo "=== building ac3_level_tb ==="
iverilog -g2012 -I dvd/ac3 -s ac3_level_tb -o bench/ac3/ac3_level_sim \
    dvd/ac3/*.sv bench/ac3/ac3_level_tb.sv 2>&1 \
    | grep -viE "static variable|sorry:" || true

# vector                                   acmod
VECTORS="tools/streams/noise_48k_stereo_640k.ac3:2
bench/ac3/vectors/bbb_mono.ac3:1
bench/ac3/vectors/bbb_short_5p1.ac3:7"

for ENTRY in $VECTORS; do
    V="${ENTRY%%:*}"
    AC="${ENTRY##*:}"
    [ -f "$V" ] || { echo "  (missing $V -- skipped)"; continue; }
    B=$(basename "$V" .ac3)
    echo
    echo "=== $B (acmod $AC) ==="

    # reference: a52dec at DEFAULT flags == liba52 level 1.0 + A52_ADJUST_LEVEL,
    # which is what a52dec, a set-top player and (bar the mono +3 dB) ffmpeg give
    a52dec -o wav "$V" > "$OUT/$B.ref.wav" 2>/dev/null

    python3 -c "
import sys
d = open(sys.argv[1],'rb').read()
open(sys.argv[2],'w').write('\n'.join('%02x' % b for b in d))
" "$V" "$OUT/$B.hex"

    # GREEN: shipped scalar -- must MATCH the reference
    vvp bench/ac3/ac3_level_sim "+hex=$OUT/$B.hex" "+out=$OUT/$B.dut.txt" \
        "+n=$NPAIRS" > "$OUT/$B.green.log" 2>&1
    grep -E "^ac3_level:" "$OUT/$B.green.log" | sed 's/^/  /'
    python3 bench/ac3/level_cmp.py "$OUT/$B.ref.wav" "$OUT/$B.dut.txt" \
        1.0 "$TOL_DB" "GREEN $B" || rc=1

    # RED: force the scalar to unity -- i.e. the PRE-FIX datapath.  The expected
    # ratio is NOT a constant: it is 16384/lvl_q, so it reads 0.5 on acmod 1/2
    # (lvl_q = 32768, a clean x2) but ~1.21 on 5.1, where the omitted downmix
    # normalisation pushed the OTHER way and the two errors partly cancelled.
    # Deriving it from the scalar the DUT actually reported keeps the arm honest
    # for any acmod without a hardcoded table.
    LVLQ=$(sed -n 's/.*(dut \([0-9]*\)).*/\1/p' "$OUT/$B.green.log" | head -1)
    if [ -z "$LVLQ" ] || [ "$LVLQ" = "0" ]; then
        echo "  FAIL $B: could not read lvl_q from the DUT (RED arm cannot be scaled)"
        rc=1
    else
        EXP=$(python3 -c "print(16384.0/$LVLQ)")
        vvp bench/ac3/ac3_level_sim "+hex=$OUT/$B.hex" "+out=$OUT/$B.pre.txt" \
            +lvl=16384 "+n=$NPAIRS" > /dev/null 2>&1
        python3 bench/ac3/level_cmp.py "$OUT/$B.ref.wav" "$OUT/$B.pre.txt" \
            "$EXP" "$TOL_DB" "RED   $B" || rc=1
    fi
done

echo
if [ "$rc" -eq 0 ]; then echo "run_ac3_level.sh: ALL GREEN"; else echo "run_ac3_level.sh: FAILURES"; fi
exit $rc
