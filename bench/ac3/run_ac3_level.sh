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
#   pre-fix datapath, and requires the ratio to change.  Without the RED arm this
#   would be a bench that cannot fail: a gate that only ever asserts "we match"
#   passes just as happily on a scalar of 1.0 as on the correct one.
#
# ★ The RED expectation is DERIVED, not a constant: 16384/lvl_q.  That reads 0.5
#   on acmod 1/2 (lvl_q = 32768, a clean x2) but ~1.21 on 5.1, where the omitted
#   downmix normalisation pushed the OTHER way and the two errors partly
#   cancelled.  Hardcoding 0.5 made the 5.1 arm fail for entirely the wrong
#   reason.
#
# Requires: iverilog, a52dec.  Skips (rc 0) if a52dec is missing -- it is not
# part of the core toolchain.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TOL_DB=0.15

# ★ Sample pairs per arm, counted from the first NON-SILENT pair.  512 is not a
# figure picked by feel -- runtime is wildly NON-LINEAR in it.  MEASURED on the
# 5.1 vector: 512 pairs completes in 2 SECONDS, while 1792 drives the decoder
# into a stall regime and takes over ten minutes to reach the same verdict.  512
# still yields hundreds of loud samples, ample for a median ratio.  Raise it only
# with a stopwatch in hand.
NPAIRS=${NPAIRS:-512}

# ★ ARMS RUN IN PARALLEL, following bench/dvd/run_disp_sched.sh (2026-09-07).
# Each arm is an independent vvp process sharing nothing but read-only inputs,
# and Icarus is single-threaded per process, so the six arms fan out across cores
# that were otherwise idle.  Verdicts go to files because a background subshell
# cannot set `fail` in the parent.
JOBS=${JOBS:-6}

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

VECTORS="tools/streams/noise_48k_stereo_640k.ac3:2
bench/ac3/vectors/bbb_mono.ac3:1
bench/ac3/vectors/bbb_short_5p1.ac3:7"

RESDIR=$(mktemp -d)

arm() {   # $1 = vector path, $2 = GREEN|RED
    local V=$1 KIND=$2
    local B; B=$(basename "$V" .ac3)
    local tag="$KIND $B"
    local outf="$OUT/$B.$KIND.txt" logf="$OUT/$B.$KIND.log"
    local extra=""
    [ "$KIND" = "RED" ] && extra="+lvl=16384"

    vvp bench/ac3/ac3_level_sim "+hex=$OUT/$B.hex" "+out=$outf" \
        "+n=$NPAIRS" $extra > "$logf" 2>&1

    # ★ lvl_q_dut is the scalar the DUT COMPUTED, and the bench prints it in both
    # arms regardless of any +lvl override -- so RED scales from its OWN log and
    # needs no ordering against GREEN.  That is what lets all six arms run at once.
    local LVLQ EXP
    LVLQ=$(sed -n 's/.*(dut \([0-9]*\)).*/\1/p' "$logf" | head -1)
    if [ -z "$LVLQ" ] || [ "$LVLQ" = "0" ]; then
        { echo "  FAIL $tag: could not read lvl_q from the DUT"; echo "__FAIL__"; } \
            > "$RESDIR/$B.$KIND"
        return
    fi
    if [ "$KIND" = "GREEN" ]; then EXP=1.0; else EXP=$(python3 -c "print(16384.0/$LVLQ)"); fi

    { grep -E "^ac3_level:" "$logf" | sed 's/^/  /'
      python3 bench/ac3/level_cmp.py "$OUT/$B.ref.wav" "$outf" \
          "$EXP" "$TOL_DB" "$tag" || echo "__FAIL__"
    } > "$RESDIR/$B.$KIND" 2>&1
}

# references + hex first: cheap, and every arm reads them
for ENTRY in $VECTORS; do
    V="${ENTRY%%:*}"
    [ -f "$V" ] || { echo "  (missing $V -- skipped)"; continue; }
    B=$(basename "$V" .ac3)
    a52dec -o wav "$V" > "$OUT/$B.ref.wav" 2>/dev/null
    python3 -c "
import sys
d = open(sys.argv[1],'rb').read()
open(sys.argv[2],'w').write('\n'.join('%02x' % b for b in d))
" "$V" "$OUT/$B.hex"
done

echo "=== 3 vectors x 2 arms, up to $JOBS at once, n=$NPAIRS ==="
for ENTRY in $VECTORS; do
    V="${ENTRY%%:*}"
    [ -f "$V" ] || continue
    for KIND in GREEN RED; do
        while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || break; done
        arm "$V" "$KIND" &
    done
done
wait

for ENTRY in $VECTORS; do
    V="${ENTRY%%:*}"
    [ -f "$V" ] || continue
    B=$(basename "$V" .ac3)
    AC="${ENTRY##*:}"
    echo
    echo "=== $B (acmod $AC) ==="
    for KIND in GREEN RED; do
        if [ ! -f "$RESDIR/$B.$KIND" ]; then
            echo "  FAIL $KIND $B: no result file"; rc=1; continue
        fi
        grep -v '^__FAIL__$' "$RESDIR/$B.$KIND"
        grep -q '^__FAIL__$' "$RESDIR/$B.$KIND" && rc=1
    done
done
rm -rf "$RESDIR"

echo
if [ "$rc" -eq 0 ]; then echo "run_ac3_level.sh: ALL GREEN"; else echo "run_ac3_level.sh: FAILURES"; fi
exit $rc
