#!/usr/bin/env bash
# run_reader_regress.sh -- bit-identity gate for refactors of dvd/dvd_iso_reader.sv.
#
# Runs every bench that instantiates the reader (41 benches, 50 arms), with
# bench/dvd/reader_trace.sv compiled beside each one, and keeps three things per
# arm: the run log, the vvp exit code, and a trace of every change on the
# reader's kept output ports. Run it once on `main` to make a baseline, then on
# the branch with --baseline: any difference in any verdict, log or trace fails.
#
#   # baseline, from a worktree of main (bench/dvd/reader_trace.sv is taken from
#   # beside THIS script, so run the branch's copy by path):
#   git worktree add .claude/worktrees/readerslim-main main
#   cd .claude/worktrees/readerslim-main
#   /path/to/branch/bench/dvd/run_reader_regress.sh --out /tmp/rr_main
#   # the branch, from its own root:
#   bench/dvd/run_reader_regress.sh --baseline /tmp/rr_main
#
# The sources come from the CURRENT DIRECTORY (the repo root being tested), so the
# same script measures main's reader in main's worktree and the branch's reader
# in the branch. Only reader_trace.sv is taken from beside this script.
#
# Why a trace and not just the verdicts: a bench asserts what its author thought
# to check, and a refactor that moves one cycle of sd_rd or reorders two cellf_*
# strobes can pass every bench. The trace makes "bit-identical" a checked claim.
#
# Module sources are resolved by Icarus's library search (-y dvd -Y .sv), so each
# bench pulls in exactly the modules it instantiates; the arms that need more
# (the AC-3/MP2 audio chain) list their extras explicitly, copied from the runner
# that owns them (run_wav.sh).
#
# Options:  --out DIR       where to write (default .sim/reader_regress)
#           --baseline DIR  compare against a previous --out; exit 1 on any diff
#           --only REGEX    run only the arms whose label matches (awk ERE on the label)
#           -j N            parallel arms (default: nproc)
# Env:      RR_TIMEOUT      per-arm vvp timeout in seconds (default 1800)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TRACE_SV="$HERE/reader_trace.sv"
ROOT="$PWD"
[ -f "$ROOT/dvd/dvd_iso_reader.sv" ] || {
    echo "run_reader_regress: run from a repo root (no dvd/dvd_iso_reader.sv here)" >&2; exit 2; }
[ -f "$TRACE_SV" ] || { echo "run_reader_regress: missing $TRACE_SV" >&2; exit 2; }

OUT="$ROOT/.sim/reader_regress"
BASE=""
ONLY=""
JOBS=$(nproc 2>/dev/null || echo 4)
while [ $# -gt 0 ]; do
    case "$1" in
        --out)      OUT="$2"; shift 2 ;;
        --baseline) BASE="$2"; shift 2 ;;
        --only)     ONLY="$2"; shift 2 ;;
        -j)         JOBS="$2"; shift 2 ;;
        *) echo "run_reader_regress: unknown option $1" >&2; exit 2 ;;
    esac
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

AUDIO_CHAIN="dvd/dvd_audio_decode.sv dvd/lpcm_unpack.sv dvd/mp2/mp2_decode.sv $(ls dvd/ac3/*.sv | tr '\n' ' ')"

# label | bench | reader instance | extra iverilog args | vvp plusargs | extra sources
ARMS=$(cat <<EOF
angle_noagli|angle_noagli_tb|dut|||
cdda_audio|cdda_audio_tb|rdr|-I dvd/ac3||$AUDIO_CHAIN
iso_reader|iso_reader_tb|dut|||
iso_reader_angle|iso_reader_angle_tb|dut|||
iso_reader_atmos|iso_reader_atmos_tb|dut|||
iso_reader_attr|iso_reader_attr_tb|dut|||
iso_reader_auddrain|iso_reader_auddrain_tb|dut|||
iso_reader_auddrain_noaudio|iso_reader_auddrain_tb|dut|-Piso_reader_auddrain_tb.NO_AUDIO_TERM=1||
iso_reader_branch_1|iso_reader_branch_tb|dut|-Piso_reader_branch_tb.ARM=1||
iso_reader_branch_2|iso_reader_branch_tb|dut|-Piso_reader_branch_tb.ARM=2||
iso_reader_branch_3|iso_reader_branch_tb|dut|-Piso_reader_branch_tb.ARM=3||
iso_reader_branch_4|iso_reader_branch_tb|dut|-Piso_reader_branch_tb.ARM=4||
iso_reader_branch_5|iso_reader_branch_tb|dut|-Piso_reader_branch_tb.ARM=5||
iso_reader_branch_6|iso_reader_branch_tb|dut|-Piso_reader_branch_tb.ARM=6||
iso_reader_callss_return|iso_reader_callss_return_tb|dut|||
iso_reader_celldur|iso_reader_celldur_tb|dut|||
iso_reader_chapter|iso_reader_chapter_tb|dut|||
iso_reader_cluedo_menu|iso_reader_cluedo_menu_tb|dut|||
iso_reader_ifo|iso_reader_ifo_tb|dut|||
iso_reader_ilvu|iso_reader_ilvu_tb|dut|||
iso_reader_intitle_link|iso_reader_intitle_link_tb|dut|||
iso_reader_linkptt|iso_reader_linkptt_tb|dut|||
iso_reader_lu|iso_reader_lu_tb|dut|||
iso_reader_menu|iso_reader_menu_tb|dut|||
iso_reader_menudrain|iso_reader_menudrain_tb|dut|||
iso_reader_montage|iso_reader_montage_tb|dut|||
iso_reader_mount|iso_reader_mount_tb|dut|||
iso_reader_pgc|iso_reader_pgc_tb|dut|||
iso_reader_predispatch|iso_reader_predispatch_tb|dut|||
iso_reader_ptt|iso_reader_ptt_tb|dut|||
iso_reader_raw|iso_reader_raw_tb|dut|||
iso_reader_real|iso_reader_real_tb|dut|||
iso_reader_scrub|iso_reader_scrub_tb|dut|||
iso_reader_seek|iso_reader_seek_tb|dut|||
iso_reader_straddle|iso_reader_straddle_tb|dut|||
iso_reader_subpctl|iso_reader_subpctl_tb|dut|||
iso_reader_timedstill|iso_reader_timedstill_tb|dut|||
iso_reader_titlestill|iso_reader_titlestill_tb|dut|||
iso_reader_tmap|iso_reader_tmap_tb|dut|||
iso_reader_tpsw|iso_reader_tpsw_tb|dut|||
iso_reader_tpsw_boot|iso_reader_tpsw_boot_tb|dut|||
iso_reader_vm|iso_reader_vm_tb|dut|||
iso_reader_vmgm|iso_reader_vmgm_tb|dut|||
iso_reader_zerocell|iso_reader_zerocell_tb|dut|||
mode_realign_chain|mode_realign_chain_tb|dut|||
mode_realign_chain_prefix|mode_realign_chain_tb|dut||+realign=0|
title_span|title_span_tb|dut|||
title_span_late0|title_span_tb|dut|-DTITLE_SPAN_LATE0||
title_span_gap|title_span_tb|dut|-DTITLE_SPAN_GAP||
wav_probe|wav_probe_tb|dut|||
EOF
)

run_arm() {
    local label tb inst ivx plus extra
    IFS='|' read -r label tb inst ivx plus extra <<<"$1"
    local d="$OUT/$label"
    rm -rf "$d"; mkdir -p "$d"
    # shellcheck disable=SC2086
    if ! iverilog -g2012 -I rtl/mpeg2 -y dvd -Y .sv $ivx \
            -DRTRACE_DUT="$tb.$inst" -o "$d/sim" \
            dvd/dvd_iso_reader.sv $extra "bench/dvd/$tb.sv" "$TRACE_SV" \
            > "$d/build.log" 2>&1; then
        echo "BUILD_FAIL" > "$d/verdict"; return
    fi
    # shellcheck disable=SC2086
    timeout "${RR_TIMEOUT:-1800}" vvp -n "$d/sim" +RTRACE="$d/trace" $plus \
        > "$d/run.raw" 2>&1
    local rc=$?
    # A bench's own $finish/$fatal messages carry file:line, which move when a
    # bench is edited (the port sweep does exactly that). Normalise them away.
    sed -E 's/([A-Za-z0-9_./-]+\.s?v):[0-9]+/\1:N/g' "$d/run.raw" > "$d/run.log"
    local np nf
    np=$(grep -cE 'PASS' "$d/run.log")
    nf=$(grep -cE '(^|[^A-Z])FAIL' "$d/run.log")
    echo "rc=$rc pass_lines=$np fail_lines=$nf" > "$d/verdict"
    # Traces run to tens of MB (stream_data changes every byte). gzip -n drops the
    # name and time stamp, so the compressed file is a pure function of its content
    # and cmp on it is still an exact comparison.
    [ -f "$d/trace" ] || : > "$d/trace"   # vvp died before $fopen
    wc -l < "$d/trace" > "$d/trace.lines"
    gzip -n -1 -f "$d/trace"
    rm -f "$d/sim" "$d/run.raw"
}
export -f run_arm
export OUT TRACE_SV

echo "run_reader_regress: $(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null) in $ROOT -> $OUT"
printf '%s\n' "$ARMS" | awk -F'|' -v re="${ONLY:-.}" '$1 ~ re' \
    | xargs -d '\n' -P "$JOBS" -I{} bash -c 'run_arm "$1"' _ {}

# Summary, one line per arm, sorted -- the file a baseline is compared on.
: > "$OUT/verdicts.txt"
for d in "$OUT"/*/; do
    l=$(basename "$d")
    [ -f "$d/verdict" ] || continue
    tb=$(cat "$d/trace.lines" 2>/dev/null || echo 0)
    printf '%-30s %s trace_lines=%s\n' "$l" "$(cat "$d/verdict")" "$tb" >> "$OUT/verdicts.txt"
done
sort -o "$OUT/verdicts.txt" "$OUT/verdicts.txt"
cat "$OUT/verdicts.txt"

[ -z "$BASE" ] && exit 0

echo
echo "== compare against $BASE =="
rc=0
for d in "$OUT"/*/; do
    l=$(basename "$d")
    [ -f "$d/verdict" ] || continue
    b="$BASE/$l"
    if [ ! -d "$b" ]; then echo "  NEW   $l (no baseline arm)"; rc=1; continue; fi
    for f in verdict run.log trace.gz; do
        if ! cmp -s "$d/$f" "$b/$f"; then
            echo "  DIFF  $l/$f"
            if [ "$f" = trace.gz ]; then
                diff <(zcat "$b/$f") <(zcat "$d/$f") | head -4 | cut -c1-200 | sed 's/^/          /'
            else
                diff "$b/$f" "$d/$f" | head -6 | sed 's/^/          /'
            fi
            rc=1
        fi
    done
done
if [ $rc -eq 0 ]; then echo "  IDENTICAL: every verdict, log and trace matches the baseline"; fi
exit $rc
