#!/bin/bash
# package_release.sh — assemble a ready-to-extract MiSTer DVD Player release zip.
#
# Bundles the three things a user installs into ONE zip that extracts to the SD-card
# root (/media/fat): the core .rbf, the custom Main (MiSTer_DVDcss — physical discs +
# encrypted ISOs), and Scripts/install_dvdcss.sh (so the libdvdcss installer lands in
# the MiSTer Scripts menu automatically, alongside the drive-region tool). It
# BUILDS nothing — point it at an already-
# built .rbf and MiSTer_DVDcss:
#
#   ./build_release.sh --release                 # -> releases/DVD_YYYYMMDD.rbf
#   USE_DOCKER=1 ./main/build_main.sh            # -> main/.build/MiSTer_DVDcss
#   ./tools/package_release.sh                   # -> releases/MiSTer_DVD_<ver>.zip
#
# Options:
#   --rbf PATH    core .rbf to bundle (default: newest releases/DVD_*.rbf, non-MARGINAL)
#   --main PATH   MiSTer_DVDcss binary (default: main/.build/MiSTer_DVDcss)
#   --out PATH    output zip (default: releases/MiSTer_DVD_v<CORE_VERSION>.zip)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

RBF=""
MAIN_BIN="$REPO/main/.build/MiSTer_DVDcss"
OUT=""
RBF_DIR="_Other"   # SD subfolder the .rbf extracts into (a DVD player fits _Other, not a
                   # console/computer category). Pass --rbf-dir . (or "") for the SD root.
while [ $# -gt 0 ]; do
    case "$1" in
        --rbf)     RBF="$2";      shift 2 ;;
        --main)    MAIN_BIN="$2"; shift 2 ;;
        --out)     OUT="$2";      shift 2 ;;
        --rbf-dir) RBF_DIR="$2";  shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done
# Normalise "." / "" to "SD root".
case "$RBF_DIR" in .|"") RBF_DIR="" ;; esac

# Core version from the RTL, for the zip name (falls back to the date).
VER="$(sed -n 's/.*`define CORE_VERSION "\([^"]*\)".*/\1/p' "$REPO/dvd/emu.sv" 2>/dev/null | head -1)"
[ -n "$VER" ] || VER="$(date +%Y%m%d)"

# Pick the core .rbf: newest clean (non-MARGINAL) DVD_*.rbf unless one was named.
if [ -z "$RBF" ]; then
    RBF="$(ls -t "$REPO"/releases/DVD_*.rbf 2>/dev/null | grep -v MARGINAL | head -1 || true)"
fi
if [ -z "$RBF" ] || [ ! -f "$RBF" ]; then
    echo "!! no core .rbf found. Build one first:  ./build_release.sh --release" >&2
    echo "   (or pass --rbf PATH)" >&2
    exit 1
fi
if [ ! -f "$MAIN_BIN" ]; then
    echo "!! MiSTer_DVDcss not found at $MAIN_BIN. Build it first:" >&2
    echo "   USE_DOCKER=1 ./main/build_main.sh   (or pass --main PATH)" >&2
    exit 1
fi

INSTALLER="$REPO/main/Scripts/install_dvdcss.sh"
[ -f "$INSTALLER" ] || { echo "!! missing $INSTALLER" >&2; exit 1; }

REGIONTOOL="$REPO/main/Scripts/set_dvd_region.sh"
[ -f "$REGIONTOOL" ] || { echo "!! missing $REGIONTOOL" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "!! 'python3' not found on PATH" >&2; exit 1; }

[ -n "$OUT" ] || OUT="$REPO/releases/MiSTer_DVD_v${VER}.zip"

echo "== packaging MiSTer DVD Player v${VER}"
echo "   core : $(basename "$RBF")"
echo "   main : $(basename "$MAIN_BIN")"

# Stage a tree that mirrors the SD-card root, then zip its CONTENTS (so extraction
# drops files straight into /media/fat). The .rbf goes in RBF_DIR (default _Other);
# MiSTer_DVDcss MUST be at the root — that is where `[DVD] main=` looks for it.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Scripts" "$STAGE/${RBF_DIR}"
cp "$RBF"       "$STAGE/${RBF_DIR:+$RBF_DIR/}$(basename "$RBF")"
cp "$MAIN_BIN"  "$STAGE/MiSTer_DVDcss"
cp "$INSTALLER" "$STAGE/Scripts/install_dvdcss.sh"
chmod +x "$STAGE/Scripts/install_dvdcss.sh"
cp "$REGIONTOOL" "$STAGE/Scripts/set_dvd_region.sh"
chmod +x "$STAGE/Scripts/set_dvd_region.sh"
# dvd_report.py rides along so the support-bundle chord works out of the box:
# MiSTer_DVDcss shells out to it (main/support/dvd/dvd_report.cpp searches
# Scripts/ first). It is also the tool a reporter runs on a PC.
cp "$REPO/tools/dvd_report.py" "$STAGE/Scripts/dvd_report.py"
chmod +x "$STAGE/Scripts/dvd_report.py"

RBF_SHOWN="${RBF_DIR:+$RBF_DIR/}$(basename "$RBF")"
cat > "$STAGE/DVD_INSTALL.txt" <<EOF
MiSTer DVD Player v${VER}

1. Extract this zip to the ROOT of your MiSTer SD card. If you copy files over the
   network (SSH/SFTP) instead of pulling the card, that root is /media/fat. You get:
     ${RBF_SHOWN}   - the core (in ${RBF_DIR:-the SD root}; move it elsewhere if you prefer)
     MiSTer_DVDcss         - custom Main (physical discs + encrypted ISOs); keep at the root
     Scripts/install_dvdcss.sh
     Scripts/set_dvd_region.sh
     Scripts/dvd_report.py

2. To play PHYSICAL discs or ENCRYPTED ISOs, add to /media/fat/MiSTer.ini
   (add the section; do NOT replace the file):

     [DVD]
     main=MiSTer_DVDcss

   Decrypted ISOs play without this. Do NOT overwrite the stock /media/fat/MiSTer.

3. Encrypted discs/ISOs need libdvdcss (not included; not shipped by this project).
   Run "install_dvdcss" once from the MiSTer Scripts menu to fetch it. Unencrypted
   discs and already-decrypted ISOs need nothing.

4. PHYSICAL DISCS ONLY: a drive with no region set makes every disc slow to start,
   because the CSS keys have to be cracked instead of read from the drive. Run
   "set_dvd_region" from the Scripts menu to see the drive's region and, if you
   want, set it. Read its warnings first - a drive allows only about five region
   changes, ever, and the region cannot be un-set.

5. Launch DVD from the MiSTer menu.
EOF

rm -f "$OUT"
# Zip the staging tree's CONTENTS with python3 (portable; no `zip` needed) while
# preserving the executable bit on the installer script.
python3 - "$STAGE" "$OUT" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(stage):
        for f in sorted(files):
            full = os.path.join(root, f)
            arc  = os.path.relpath(full, stage)
            zi = zipfile.ZipInfo(arc)
            zi.external_attr = (os.stat(full).st_mode & 0xFFFF) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            with open(full, "rb") as fh:
                z.writestr(zi, fh.read())
PY
echo "== done: $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "Attach these to the GitHub release (zip for a full install; bare files for"
echo "users who just want one piece — most want only the .rbf):"
echo "  $OUT"
echo "      ^ complete install: core + MiSTer_DVDcss + Scripts/ (dvdcss installer,"
echo "        drive-region tool)"
echo "  $RBF"
echo "      ^ core only (ISO-only users; physical disc is opt-in)"
echo "  $MAIN_BIN"
echo "      ^ custom Main only (physical discs + encrypted ISOs); needs [DVD] main="
echo "  $INSTALLER"
echo "      ^ libdvdcss installer (also inside the zip's Scripts/)"
echo "  $REGIONTOOL"
echo "      ^ DVD drive-region tool (also inside the zip's Scripts/)"
