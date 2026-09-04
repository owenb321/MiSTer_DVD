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

# The OSD version string, read from the single source of truth. It is part of
# CONF_STR = part of the synthesis netlist, so it changes at most ONCE PER BRANCH
# (see CLAUDE.md "Versioning"). Recorded in the provenance manifest below, and
# gated for shape further down.
HERE="$(cd "$(dirname "$0")" && pwd)"
CORE_VERSION="$(sed -n 's/.*`define CORE_VERSION "\([^"]*\)".*/\1/p' "$HERE/dvd/emu.sv" | head -1)"
if [[ -z "$CORE_VERSION" ]]; then
    echo "ERROR: no \`define CORE_VERSION found in dvd/emu.sv." >&2
    exit 1
fi

# --- Version identity gate --------------------------------------------------
# Runs BEFORE the compile so a wrong version costs a second, not 40 minutes.
# The invariant (dvd/emu.sv, CLAUDE.md "Versioning"): a bare semver lives in
# exactly ONE commit per release; every other commit carries dev-<slug>.
#
# "Publishable" is --release WITHOUT --name — the same condition that selects the
# DVD_YYYYMMDD.rbf naming below. tools/seed_sweep.sh passes --release WITH --name
# purely for the hard timing gate, so it lands in the dev arm and is unaffected;
# that is the one non-obvious caller.
if [[ ${#CORE_VERSION} -gt 18 ]]; then
    echo "ERROR: CORE_VERSION '$CORE_VERSION' is ${#CORE_VERSION} chars; the limit is 18." >&2
    echo "       stock menu.cpp (MENU_ABOUT2) truncates the whole 'DVD <ver> <date>'" >&2
    echo "       About line at 30 chars, and 'DVD ' + ' ' + 'yymmdd' already uses 12." >&2
    exit 1
fi
case "$CORE_VERSION" in
    *,*|*\;*|*\"*)
        echo "ERROR: CORE_VERSION '$CORE_VERSION' contains , ; or \" — all three break CONF_STR." >&2
        echo "       ';' ends the entry and user_io.cpp's V arm splits on commas, so the" >&2
        echo "       version would be silently TRUNCATED rather than rejected." >&2
        exit 1 ;;
esac

if [[ "$RELEASE_GATE" -eq 1 && "$NAME_SET" -eq 0 ]]; then
    if [[ ! "$CORE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "ERROR: a publishable --release build needs the release semver in dvd/emu.sv," >&2
        echo "       e.g. \`define CORE_VERSION \"v0.4.0\"  — found \"$CORE_VERSION\"." >&2
        echo "       Set it on the release commit, together with the mkdocs.yml and manual" >&2
        echo "       updates, so one commit and one compile carry the whole release." >&2
        exit 1
    fi
else
    if [[ ! "$CORE_VERSION" =~ ^dev-[a-z0-9][a-z0-9.-]*$ ]]; then
        echo "ERROR: dev builds must carry a feature-identifying CORE_VERSION 'dev-<slug>'," >&2
        echo "       e.g. \`define CORE_VERSION \"dev-seekrealign\"  — found \"$CORE_VERSION\"." >&2
        echo "       A bare semver on a dev build is exactly the bug this gate exists to" >&2
        echo "       stop: testers quote the OSD line and report it as a released version." >&2
        exit 1
    fi
    # Advisory only — a slug and a branch name legitimately differ, but a slug left
    # over from ANOTHER branch is a real and easy mistake.
    _br="${GIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')}"
    _brslug="$(printf '%s' "${_br##*/}" | tr -cd 'a-z0-9')"
    _vslug="$(printf '%s' "${CORE_VERSION#dev-}" | tr -cd 'a-z0-9')"
    if [[ -n "$_brslug" && "$_brslug" != "main" && "$_brslug" != *"$_vslug"* && "$_vslug" != *"$_brslug"* ]]; then
        echo "NOTE: CORE_VERSION '$CORE_VERSION' does not resemble branch '$_br' — left over from another branch?" >&2
    fi
fi

# The .rbf, the zip and the OSD should all name the same thing, so a dev build's
# name FOLLOWS the version slug instead of needing --name every time. (This
# replaces the old "always pass --name" rule, and the meaningless DVD_ps_demux
# default it existed to work around.) An explicit --name still wins.
if [[ "$NAME_SET" -eq 0 && "$RELEASE_GATE" -eq 0 ]]; then
    NAME="${PROJECT}_${CORE_VERSION#dev-}"
fi

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

# --- Build provenance manifest ---------------------------------------------
# One JSON sidecar per .rbf, "<rbf>.json". releases/ and build_id.v are BOTH
# git-ignored, so without this an .rbf found on a tester's SD card months from
# now is unidentifiable — the filename is its only metadata. Three consumers:
#   * .github/workflows/package.yml validates the uploaded release asset against
#     it, and learns WHICH COMMIT to check out (a draft release has no git tag).
#   * a mystery build: which tree, which seed, what timing.
#   * DVD.qsf's hand-written seed ledger — its entries quote exactly these
#     numbers, so this is machine-readable input for that paragraph.
# Everything here comes from files this script has already produced; nothing is
# recomputed and there is no python3 dependency inside the Quartus container.
MANIFEST="${OUT}.json"
FIT_SUMMARY="output_files/${PROJECT}.fit.summary"
# `Key : value` lookup in the fitter summary. Keys contain ( ) which are literal in BRE.
fitval() { sed -n "s/^$1 : *//p" "$FIT_SUMMARY" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//' || true; }
# The pinned fitter seed. quartus_fit --seed=N writes this assignment back into the
# qsf, so the LAST one is what actually built this netlist.
SEED_V=$(sed -n 's/^set_global_assignment -name SEED  *//p' "$HERE/${PROJECT}.qsf" 2>/dev/null | tail -1 || true)
# From "clk_dec Restricted Fmax: 94.06 MHz @100C, 93.11 MHz @-40C (target 86.0)".
F100=$(printf '%s' "$FMAX_LINE" | sed -n 's/.*Fmax: *\([0-9.]*\) MHz @100C.*/\1/p')
FM40=$(printf '%s' "$FMAX_LINE" | sed -n 's/.*, *\([0-9.]*\) MHz @-40C.*/\1/p')
FTGT=$(printf '%s' "$FMAX_LINE" | sed -n 's/.*(target *\([0-9.]*\)).*/\1/p')
BDATE=$(sed -n 's/.*`define BUILD_DATE "\([^"]*\)".*/\1/p' "$HERE/build_id.v" 2>/dev/null || true)
RBF_SHA=$(sha256sum "$OUT" 2>/dev/null | cut -d' ' -f1 || true)
# GIT_* normally arrive from tools/docker_reexec.sh, which resolves them on the
# host. This fallback covers a direct (non-Docker) run.
G_BRANCH="${GIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
G_SHA="${GIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
G_DIRTY="${GIT_DIRTY:-$([ -n "$(git -C "$HERE" status --porcelain --untracked-files=no 2>/dev/null)" ] && echo true || echo false)}"
[[ "$G_DIRTY" == "true" || "$G_DIRTY" == "false" ]] || G_DIRTY=null

cat > "$MANIFEST" <<EOF
{
  "schema": 1,
  "core_version": "${CORE_VERSION}",
  "build_date": "${BDATE}",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "rbf": {
    "name": "$(basename "$OUT")",
    "bytes": ${SIZE},
    "sha256": "${RBF_SHA}",
    "marginal": $([ -n "$FMAX_TAG" ] && echo true || echo false)
  },
  "git": {
    "branch": "${G_BRANCH}",
    "sha": "${G_SHA}",
    "dirty": ${G_DIRTY}
  },
  "fit": {
    "seed": ${SEED_V:-null},
    "alm": "$(fitval 'Logic utilization (in ALMs)')",
    "registers": "$(fitval 'Total registers')",
    "ram_blocks": "$(fitval 'Total RAM Blocks')",
    "dsp_blocks": "$(fitval 'Total DSP Blocks')"
  },
  "timing": {
    "clk_dec_100c_mhz": ${F100:-null},
    "clk_dec_m40c_mhz": ${FM40:-null},
    "threshold_mhz": ${FTGT:-null},
    "pass": $([ -z "$FMAX_TAG" ] && echo true || echo false)
  },
  "toolchain": {
    "quartus": "$(fitval 'Quartus Prime Version')",
    "image": "${QUARTUS_DOCKER_IMAGE:-raetro/quartus:mister}"
  }
}
EOF
echo ">> Manifest: ${MANIFEST}"

# Phone notification (no-op if tools/.notify_url / $NOTIFY_URL unset; NOTIFY_SILENT=1
# suppresses it, e.g. when seed_sweep.sh sends its own summary instead).
if [[ -n "$FMAX_TAG" ]]; then
    notify "⚠️ MiSTer_DVD packed MARGINAL $(basename "$OUT") ($((SIZE/1024)) KB) — ${FMAX_LINE:-no STA data}"
else
    notify "✅ MiSTer_DVD packed $(basename "$OUT") ($((SIZE/1024)) KB) — ${FMAX_LINE:-no STA data}"
fi
