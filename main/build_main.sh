#!/bin/bash
# build_main.sh — build the MiSTer_DVDcss custom Main (stock Main_MiSTer + our overlay).
#
# The custom Main lets the DVD core play PHYSICAL DVDs (and, later, encrypted ISOs)
# on stock MiSTer via `[DVD] main=MiSTer_DVDcss`. It is stock Main_MiSTer with the
# self-contained overlay under main/ (support/dvd/*, Scripts/install_dvdcss.sh) and
# the user_io.cpp/Makefile edits in main/integration/.
#
# It never modifies this repo's tree: stock Main is fetched into a scratch build dir
# (git-ignored), the overlay is copied in, and the ARM binary is emitted there.
#
# Env:
#   USE_DOCKER=1      build inside the pinned toolchain image (no local toolchain
#                     needed); see main/docker_reexec.sh. No-op without it.
#   MAIN_DOCKER_IMAGE image tag for USE_DOCKER (default mister-dvd-main:gcc-arm-10.2)
#   MAIN_MISTER_SRC   path to an existing Main_MiSTer checkout to copy from
#                     (skips the network clone; the copy is still patched in scratch)
#   MAIN_MISTER_REF   stock ref to build against (default below)
#   CROSS_COMPILE     ARM cross toolchain prefix, e.g. arm-linux-gnueabihf-
#                     (or have `make` pick up your MiSTer toolchain from PATH)
#   BUILD_DIR         scratch dir (default: main/.build)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# Provenance, captured BEFORE the Docker re-exec and stashed in a file.
#
# ⚠⚠ IT HAS TO HAPPEN HERE, ON THE HOST. docker_reexec mounts only the repo root
# at its own path, and in a WORKTREE `.git` is a FILE pointing at
# <main-checkout>/.git/worktrees/<name> -- which is outside that mount. So the VCS
# cannot resolve the tree from inside the container at all, and a naive "record
# the commit at the end of the build" would silently record nothing on exactly
# the builds this project makes most often.
#
# ⚠ RECORDING THE COMMIT ALONE WOULD BE WORSE THAN USELESS. A Main is routinely
# built from a DIRTY tree and deployed minutes before the commit that captures it
# -- that is how the IR round went, and answering "what was this built from?"
# afterwards took mtime archaeology. A bare HEAD would have NAMED A COMMIT WHOSE
# CONTENT IS NOT WHAT SHIPPED. The dirty flag and the file list are the part that
# makes this answerable.
mkdir -p "${BUILD_DIR:-$HERE/.build}"
if [ -z "${IN_MAIN_DOCKER:-}" ]; then
    _bi="${BUILD_DIR:-$HERE/.build}/.buildinfo.env"
    if _sha="$(git -C "$HERE" rev-parse HEAD 2>/dev/null)"; then
        _dirty="$(git -C "$HERE" status --porcelain 2>/dev/null | wc -l | tr -d " ")"
        # Only the paths that can change the BINARY; a dirty doc file is not a
        # caveat worth attaching to a build.
        _dsrc="$(git -C "$HERE" status --porcelain -- support integration build_main.sh 2>/dev/null | awk "{print \$2}" | tr "\n" " ")"
        {
            echo "BI_COMMIT=$_sha"
            echo "BI_SHORT=$(git -C "$HERE" rev-parse --short HEAD)"
            echo "BI_BRANCH=$(git -C "$HERE" rev-parse --abbrev-ref HEAD)"
            echo "BI_DIRTY=$_dirty"
            echo "BI_DIRTY_SRC=$_dsrc"
        } > "$_bi"
    else
        rm -f "$_bi"      # no VCS answer: say nothing rather than something stale
    fi
fi

# Optionally re-exec inside the pinned ARM-toolchain Docker image (USE_DOCKER=1).
# No-op otherwise; never returns when it re-execs. Must run before any build work.
source "$HERE/docker_reexec.sh"
maybe_reexec_in_docker "$0" "$@"

# Stock Main_MiSTer base. Pinned to the last stock commit before the Physical Disc
# fork diverged (the CSS overlay was developed against it). Bump deliberately; if a
# newer stock moves an anchor, apply_integration.py fails loudly naming the step.
MAIN_MISTER_URL="${MAIN_MISTER_URL:-https://github.com/MiSTer-devel/Main_MiSTer.git}"
MAIN_MISTER_REF="${MAIN_MISTER_REF:-7317947}"
BUILD_DIR="${BUILD_DIR:-$HERE/.build}"
STOCK="$BUILD_DIR/Main_MiSTer"
OUT_NAME="MiSTer_DVDcss"

echo "== MiSTer_DVDcss build =="
mkdir -p "$BUILD_DIR"

# 1. Obtain a clean stock Main_MiSTer tree in scratch.
rm -rf "$STOCK"
if [ -n "${MAIN_MISTER_SRC:-}" ]; then
    echo "-- copying stock Main from $MAIN_MISTER_SRC"
    cp -a "$MAIN_MISTER_SRC" "$STOCK"
    ( cd "$STOCK" && git checkout -q "$MAIN_MISTER_REF" 2>/dev/null || \
        echo "   (note: could not checkout $MAIN_MISTER_REF in the copy; using its current tree)" )
    # Remove any build artifacts / VCS state so the tree is pristine.
    rm -rf "$STOCK/.git" "$STOCK/obj" "$STOCK/build"
else
    echo "-- cloning stock Main from $MAIN_MISTER_URL"
    git clone --quiet "$MAIN_MISTER_URL" "$STOCK"
    ( cd "$STOCK" && git checkout -q "$MAIN_MISTER_REF" )
    rm -rf "$STOCK/.git"
fi

# 2. Copy the self-contained overlay (Makefile auto-globs support/*/*.cpp).
echo "-- applying overlay"
mkdir -p "$STOCK/support/dvd" "$STOCK/Scripts"
# Copy the WHOLE overlay dir, not a hand-maintained file list. The list form
# silently omitted dvd_report.* when it was added, and the failure surfaces far
# away as "user_io.cpp: support/dvd/dvd_report.h: No such file or directory" --
# everything under main/support/dvd/ is ours and belongs in the build.
cp "$HERE"/support/dvd/*.cpp "$HERE"/support/dvd/*.h "$STOCK/support/dvd/"
cp "$HERE"/Scripts/install_dvdcss.sh "$STOCK/Scripts/"

# 3. Patch user_io.cpp / user_io.h / Makefile.
python3 "$HERE/integration/apply_integration.py" "$STOCK"

# 3b. The IR remap table asserts things about three files it does not contain --
# stock's ev2ps2[], dvd/kbd_map.sv and dvd/emu.sv -- and a restatement goes stale
# SILENTLY: the remote simply stops doing what the manual says. Check it here,
# where the stock tree is guaranteed to exist, hence --require-stock (elsewhere
# the checker legitimately skips that arm, and a silent half-run reads exactly
# like a full one). Run BEFORE the compile so a stale row costs a second.
python3 "$HERE/../tools/check_ir_remap.py" --require-stock --stock "$STOCK"

# 4. Build.
echo "-- building (this is an ARM cross-compile; ensure your toolchain is on PATH)"
make -C "$STOCK" ${CROSS_COMPILE:+CROSS_COMPILE="$CROSS_COMPILE"} -j"$(nproc)"

# 5. Collect the binary. Stock Main_MiSTer emits it under BUILDDIR (bin/MiSTer).
if [ -f "$STOCK/bin/MiSTer" ]; then
    cp "$STOCK/bin/MiSTer" "$BUILD_DIR/$OUT_NAME"

    # 5b. Provenance sidecar, so "what was this built from?" is answerable from the
    # artifact instead of by comparing mtimes against commit timestamps.
    #
    # ★ binary_sha256[:8] is deliberately included: tools/mister.py deploys the Main
    # as MiSTer_DVDcss_hil_<that>, so this ties a file on the SD card back to a
    # commit. The two hashes are easy to confuse -- the deploy name is NOT a VCS
    # hash -- and carrying both here says so in one place.
    # ⚠ READ this file, never `source` it. It carries a LIST OF PATHS, and
    # sourcing `BI_DIRTY_SRC=a b` makes the shell execute `b` -- which is exactly
    # how the first cut of this failed, with "Permission denied" on a .cpp file
    # after an otherwise successful build. A generated file is data, not script.
    _bi="$BUILD_DIR/.buildinfo.env"
    _bival() { [ -f "$_bi" ] && sed -n "s/^$1=//p" "$_bi" | head -1; }
    BI_COMMIT="$(_bival BI_COMMIT)"
    BI_SHORT="$(_bival BI_SHORT)"
    BI_BRANCH="$(_bival BI_BRANCH)"
    BI_DIRTY="$(_bival BI_DIRTY)"
    BI_DIRTY_SRC="$(_bival BI_DIRTY_SRC)"
    _bsha="$(sha256sum "$BUILD_DIR/$OUT_NAME" | cut -c1-64)"
    cat > "$BUILD_DIR/$OUT_NAME.json" <<JSONEOF
{
  "artifact":      "$OUT_NAME",
  "built_utc":     "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "commit":        "${BI_COMMIT:-unknown}",
  "commit_short":  "${BI_SHORT:-unknown}",
  "branch":        "${BI_BRANCH:-unknown}",
  "tree_dirty":    ${BI_DIRTY:-null},
  "dirty_sources": "${BI_DIRTY_SRC:-}",
  "stock_ref":     "$MAIN_MISTER_REF",
  "binary_sha256": "$_bsha",
  "deploy_name":   "${OUT_NAME}_hil_$(echo "$_bsha" | cut -c1-8)"
}
JSONEOF
    echo "== done: $BUILD_DIR/$OUT_NAME"
    if [ -n "${BI_DIRTY_SRC:-}" ]; then
        echo "   !! built from a DIRTY tree: $BI_DIRTY_SRC"
        echo "      ${BI_SHORT:-?} does NOT describe this binary's sources."
    else
        echo "   from ${BI_SHORT:-unknown} (${BI_BRANCH:-?}), build sources clean"
    fi
    echo "   provenance: $BUILD_DIR/$OUT_NAME.json"
    echo "   copy to /media/fat/$OUT_NAME and add [DVD] main=$OUT_NAME to MiSTer.ini"
else
    echo "!! build did not produce $STOCK/bin/MiSTer — check the make output above" >&2
    exit 1
fi
