#!/usr/bin/env bash
# run_pts_assoc.sh — PTS -> picture association, measured against tools/pts_map.py.
#
# [A] POSITION: the vld's parse position at every picture header must place the
#     start code at the golden's byte offset EXACTLY (getbits_fifo.bitpos - 32).
# [B] TAG: (once dvd/pts_assoc.sv lands) every picture's {valid, pts} tag must
#     match the MPEG-rule assignment the golden makes from the PES PTS marks.
#
# Fixtures are cut from real media and are NOT committed (bench/dvd/test_vobs/
# is gitignored). Two are used because they mux differently:
#   pts_apollo  a DVD title (once-per-VOBU PTS, ~11 pictures per mark) —
#               needs DVD_ISO_DIR pointing at a library containing APOLLO_13
#   pts_sync    a Program Stream file (DVD_PTS_VOB, default releases/SYNC_FILM_AC3_P72.VOB)
# Without either source the corresponding arm SKIPS rather than silently passing.
#
# Slow: the real vld parses ~1.3 MB of ES per fixture, ~5 min wall each.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

ISO_DIR="${DVD_ISO_DIR:-$HOME/dvd-isos}"
VOB="${DVD_PTS_VOB:-releases/SYNC_FILM_AC3_P72.VOB}"
FIX=bench/dvd/test_vobs
rc=0

APOLLO=$(ls "$ISO_DIR"/APOLLO_13*.iso "$ISO_DIR"/APOLLO_13*.ISO 2>/dev/null | head -1 || true)
if [ -n "$APOLLO" ]; then
  echo "== cutting pts_apollo from $(basename "$APOLLO") =="
  python3 tools/pts_map.py "$APOLLO" --start-frac 0.05 --sectors 900 --cut "$FIX/pts_apollo"
fi
if [ -f "$VOB" ]; then
  echo "== cutting pts_sync from $VOB =="
  python3 tools/pts_map.py --file "$VOB" --skip 4000000 --bytes 2000000 --cut "$FIX/pts_sync"
fi

iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/pts_assoc_sim \
    rtl/mpeg2/vld.v rtl/mpeg2/getbits.v bench/dvd/pts_assoc_tb.sv

for stem in pts_apollo pts_sync; do
  if [ -f "$FIX/$stem.hex" ]; then
    echo "== pts_assoc_tb $stem =="
    vvp bench/dvd/pts_assoc_sim +STEM="$FIX/$stem" | grep -v '^VCD' || rc=1
  else
    echo "== pts_assoc_tb $stem: SKIPPED (no fixture) =="
  fi
done

[ $rc -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES (rc=$rc) =="
exit $rc
