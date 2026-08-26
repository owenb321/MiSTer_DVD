#!/bin/bash
# build_release.sh — Compile the core and/or pack a MiSTer-loadable .rbf.
#
# MiSTer's HPS FPGA loader expects a COMPRESSED Raw Binary File. A plain
# `quartus_cpf -c x.sof x.rbf` produces an UNCOMPRESSED bitstream (~7 MB) that
# fails to configure the FPGA — you get no video on HDMI or analog. The correct
# output is ~2.9 MB. This script always passes `-o bitstream_compression=on`.
#
# Usage:
#   ./build_release.sh                 # convert existing .sof -> releases/<name>_<date>.rbf
#   ./build_release.sh --compile       # run the full Quartus compile first, then convert
#   ./build_release.sh --name DVD_foo  # override the release base name
#   ./build_release.sh --release      # PUBLIC RELEASE build. Two things:
#                                     #  (1) HARD timing gate — refuse to pack if clk_dec
#                                     #      Fmax is below tools/fmax_check.sh's threshold
#                                     #      at either slow corner (the chroma-fringe
#                                     #      lottery; currently 86 MHz). Default
#                                     #      (testing) builds only WARN and tag the pack
#                                     #      MARGINAL — fringe is acceptable while testing
#                                     #      features unrelated to video quality.
#                                     #  (2) MiSTer release NAMING — packs as
#                                     #      releases/DVD_YYYYMMDD.rbf (the convention every
#                                     #      other core and the MiSTer update scripts use),
#                                     #      ignoring --name. Feature builds keep the
#                                     #      <name>_<date>_<time> form so they stay
#                                     #      distinguishable on an SD card; a release is
#                                     #      the one artifact a user installs and cites in
#                                     #      a bug report, so it gets the plain name.
#
# Requires quartus_sh / quartus_cpf on PATH (Quartus 17.0.2). Or run the whole thing
# in the pinned Quartus container with USE_DOCKER=1 (see tools/docker_reexec.sh):
#   USE_DOCKER=1 ./build_release.sh --compile

set -euo pipefail

# Optional: re-exec inside the pinned Quartus 17.0.2 Docker image when USE_DOCKER=1
# (no-op otherwise; never returns when it re-execs). Must run before any quartus call.
source "$(dirname "$0")/tools/docker_reexec.sh"
maybe_reexec_in_docker "$0" "$@"

PROJECT="DVD"                       # Quartus revision -> output_files/${PROJECT}.sof
NAME="DVD_ps_demux"                 # release base name
NAME_SET=0                          # 1 = caller passed --name explicitly
DO_COMPILE=0
RELEASE_GATE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --compile) DO_COMPILE=1; shift ;;
        --release) RELEASE_GATE=1; shift ;;
        --name)    NAME="$2"; NAME_SET=1; shift 2 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

SOF="output_files/${PROJECT}.sof"
mkdir -p releases
# Release builds take the MiSTer convention (CoreName_YYYYMMDD.rbf); feature builds keep
# the name+timestamp form so parallel experiments stay distinguishable on the SD card.
# An EXPLICIT --name always wins: tools/seed_sweep.sh passes --release purely for the hard
# timing gate and still needs its own name, and without this it (a) packed sweep artifacts
# under the release name, which reads as an official build, and (b) then failed to find
# them via `ls releases/${NAME}_*.rbf` and reported a STALE marginal rbf as the result.
if [[ "$RELEASE_GATE" -eq 1 && "$NAME_SET" -eq 0 ]]; then
    OUT="releases/${PROJECT}_$(date +%Y%m%d).rbf"
else
    OUT="releases/${NAME}_$(date +%Y%m%d_%H%M).rbf"
fi

notify() { "$(dirname "$0")/tools/notify.sh" "$1" || true; }

# Notify on failure (compile can't route / any error) so a walked-away build still
# pings. `set -e` triggers this on the first failing command; the success path sends
# its own notification below and exits 0, so this fires only for rc != 0.
trap 'rc=$?; [[ $rc -ne 0 ]] && notify "❌ MiSTer_DVD build FAILED (${NAME}, exit $rc) — check log"; exit $rc' EXIT

if [[ "$DO_COMPILE" -eq 1 ]]; then
    echo ">> Compiling ${PROJECT} (this takes ~15-40 min)..."
    quartus_sh --flow compile "$PROJECT"
fi

# --- Implicit-net gate (instituted 2026-08-26, closed-captions round 3) -----
# An edit deleted a wire declaration; Verilog silently created an undriven
# implicit net, Quartus tied it to GROUND (Warning 10236) and the feature went
# dead on hardware while every testbench still passed. iverilog does not catch
# this either unless the file uses `default_nettype none. Zero tolerance: any
# 10236 in the map report fails the build. If one is ever intentional, declare
# the wire instead.
MAP_RPT="output_files/${PROJECT}.map.rpt"
if [[ -f "$MAP_RPT" ]] && grep -q "Warning (10236)" "$MAP_RPT"; then
    echo "ERROR: implicit net(s) created during synthesis — every one of these is an undeclared/undriven wire bug:" >&2
    grep "Warning (10236)" "$MAP_RPT" | sed 's/^/    /' >&2
    exit 1
fi

if [[ ! -f "$SOF" ]]; then
    echo "ERROR: $SOF not found. Run with --compile, or compile in Quartus first." >&2
    exit 1
fi

# clk_dec timing gate (tools/fmax_check.sh): the chroma-fringe/striping placement lottery
# is clk_dec failing setup at a slow corner. The threshold lives in fmax_check.sh and is
# 86.0 MHz (raised from 81.0 on 2026-08-01 by feature/fringe-sdc-clock-groups — do not
# quote a number here, it goes stale; this comment said 81 long after the gate was 86).
# Verify every pack; --release refuses a marginal fit, default warns + tags the name so a
# fringing rbf is instantly explainable.
FMAX_TAG=""
FMAX_LINE=""
if FMAX_OUT=$("$(dirname "$0")/tools/fmax_check.sh" "output_files/${PROJECT}.sta.rpt" 2>&1); then
    echo "$FMAX_OUT"
    FMAX_LINE=$(echo "$FMAX_OUT" | grep -m1 'clk_dec Restricted Fmax' || true)
else
    rc=$?
    echo "$FMAX_OUT"
    FMAX_LINE=$(echo "$FMAX_OUT" | grep -m1 'clk_dec Restricted Fmax' || true)
    if [[ "$RELEASE_GATE" -eq 1 ]]; then
        echo "ERROR: --release build refused: clk_dec timing gate failed (rc=$rc). Re-sweep seeds (tools/seed_sweep.sh) or retime." >&2
        notify "❌ MiSTer_DVD RELEASE build REFUSED — ${FMAX_LINE:-no STA data} (fringe-lottery fit)"
        trap - EXIT
        exit 1
    fi
    echo "WARNING: packing a TIMING-MARGINAL build (testing mode) — expect the chroma-fringe lottery on HW." >&2
    FMAX_TAG="_MARGINAL"
    OUT="releases/${NAME}${FMAX_TAG}_$(date +%Y%m%d_%H%M).rbf"
fi

echo ">> Packing compressed .rbf -> ${OUT}"
quartus_cpf -c -o bitstream_compression=on "$SOF" "$OUT"

SIZE=$(stat -c%s "$OUT")
echo ">> Done: ${OUT} ($((SIZE/1024)) KB)"
# Working builds of this core land near ~4.2 MB compressed (grown from ~2.9 MB with the
# DVD features/BRAM init). An uncompressed pack is ~7 MB and silently fails to configure
# the FPGA — flag anything past 4.5 MB so it isn't discovered as a dead screen on hardware.
if [[ "$SIZE" -gt 4500000 ]]; then
    echo "WARNING: .rbf is larger than expected (~4.2 MB typical). Compression may not have applied." >&2
fi

# Phone notification (no-op if tools/.notify_url / $NOTIFY_URL unset; NOTIFY_SILENT=1
# suppresses it, e.g. when seed_sweep.sh sends its own summary instead).
if [[ -n "$FMAX_TAG" ]]; then
    notify "⚠️ MiSTer_DVD packed MARGINAL $(basename "$OUT") ($((SIZE/1024)) KB) — ${FMAX_LINE:-no STA data}"
else
    notify "✅ MiSTer_DVD packed $(basename "$OUT") ($((SIZE/1024)) KB) — ${FMAX_LINE:-no STA data}"
fi
