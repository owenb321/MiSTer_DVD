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
#   MAIN_MISTER_SRC   path to an existing Main_MiSTer checkout to copy from
#                     (skips the network clone; the copy is still patched in scratch)
#   MAIN_MISTER_REF   stock ref to build against (default below)
#   CROSS_COMPILE     ARM cross toolchain prefix, e.g. arm-linux-gnueabihf-
#                     (or have `make` pick up your MiSTer toolchain from PATH)
#   BUILD_DIR         scratch dir (default: main/.build)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

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
cp "$HERE"/support/dvd/dvd_css.cpp  "$HERE"/support/dvd/dvd_css.h  "$STOCK/support/dvd/"
cp "$HERE"/support/dvd/dvd_detect.cpp "$HERE"/support/dvd/dvd_detect.h "$STOCK/support/dvd/"
cp "$HERE"/support/dvd/dvd_phys.cpp "$HERE"/support/dvd/dvd_phys.h "$STOCK/support/dvd/"
cp "$HERE"/Scripts/install_dvdcss.sh "$STOCK/Scripts/"

# 3. Patch user_io.cpp / user_io.h / Makefile.
python3 "$HERE/integration/apply_integration.py" "$STOCK"

# 4. Build.
echo "-- building (this is an ARM cross-compile; ensure your toolchain is on PATH)"
make -C "$STOCK" ${CROSS_COMPILE:+CROSS_COMPILE="$CROSS_COMPILE"} -j"$(nproc)"

# 5. Collect the binary. Stock Main_MiSTer emits `MiSTer`.
if [ -f "$STOCK/MiSTer" ]; then
    cp "$STOCK/MiSTer" "$BUILD_DIR/$OUT_NAME"
    echo "== done: $BUILD_DIR/$OUT_NAME"
    echo "   copy to /media/fat/$OUT_NAME and add [DVD] main=$OUT_NAME to MiSTer.ini"
else
    echo "!! build did not produce $STOCK/MiSTer — check the make output above" >&2
    exit 1
fi
