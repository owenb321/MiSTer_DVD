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

CHAIN_SRC="rtl/mpeg2/vld.v rtl/mpeg2/getbits.v rtl/mpeg2/vbuf.v rtl/mpeg2/framestore.v \
  rtl/mpeg2/framestore_request.v rtl/mpeg2/framestore_response.v rtl/mpeg2/synchronizer.v \
  rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xfifo_sc.v rtl/mpeg2/xilinx_fifo_dc.v \
  rtl/mpeg2/read_write.v dvd/vbuf_pos.sv dvd/pts_assoc.sv"

# ---- [A] position, real vld over the ES ------------------------------------
iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/pts_assoc_sim \
    rtl/mpeg2/vld.v rtl/mpeg2/getbits.v dvd/pts_assoc.sv bench/dvd/pts_assoc_tb.sv
for stem in pts_apollo pts_sync; do
  if [ -f "$FIX/$stem.hex" ]; then
    echo "== pts_assoc_tb $stem =="
    vvp bench/dvd/pts_assoc_sim +STEM="$FIX/$stem" | grep -v '^VCD' || rc=1
  else
    echo "== pts_assoc_tb $stem: SKIPPED (no fixture) =="
  fi
done

# ---- [C] the VBUF path across a flush (epoch-tagged reads, vbuf_pos) --------
# A shorter cut: the real vld through the real framestore is slow, and the
# flush hazard needs only a few pictures either side of it.
if [ -n "$APOLLO" ]; then
  python3 tools/pts_map.py "$APOLLO" --start-frac 0.05 --sectors 330 --cut "$FIX/pts_apollo_s"
fi
if [ -f "$FIX/pts_apollo_s.hex" ]; then
  echo "== pts_chain_tb (GREEN) =="
  iverilog -g2012 -D__IVERILOG__ -I dvd/mem_override -I rtl/mpeg2 -o bench/dvd/pts_chain_sim \
      $CHAIN_SRC bench/dvd/pts_chain_tb.sv
  vvp bench/dvd/pts_chain_sim +STEM="$FIX/pts_apollo_s" | grep -v '^VCD' || rc=1

  # RED: framestore_response accepting BOTH epochs = the pre-fix routing (every
  # in-flight read lands in the read fifo after the flush). Rebuilt from the
  # shipping source so the arm cannot rot into a copy of an RTL that no longer
  # exists; it must FAIL [C2]/[C3].
  echo "== pts_chain_tb (RED: epoch compare removed; must FAIL) =="
  red=$(mktemp -d)
  python3 - "$red" <<'PYEOF'
import sys
s = open('rtl/mpeg2/framestore_response.v').read()
old = "vbr_wr_en <= (tag_rd_dta == (vbuf_epoch ? TAG_VBUF1 : TAG_VBUF)) && tag_rd_valid;"
assert old in s, "RED patch anchor moved -- update run_pts_assoc.sh"
s = s.replace(old, "vbr_wr_en <= ((tag_rd_dta == TAG_VBUF) || (tag_rd_dta == TAG_VBUF1)) && tag_rd_valid;")
open(sys.argv[1] + '/framestore_response.v', 'w').write(s)
PYEOF
  iverilog -g2012 -D__IVERILOG__ -I dvd/mem_override -I rtl/mpeg2 -o "$red/pts_chain_red" \
      $(echo $CHAIN_SRC | sed "s#rtl/mpeg2/framestore_response.v#$red/framestore_response.v#") \
      bench/dvd/pts_chain_tb.sv
  if vvp "$red/pts_chain_red" +STEM="$FIX/pts_apollo_s" | grep -v '^VCD' | tee "$red/red.log" | grep -q "^FAIL \[C[23]\]"; then
    echo "  RED arm failed as it must ($(grep -c '^FAIL' "$red/red.log") FAIL lines)"
  else
    echo "  RED arm did NOT fail -- the epoch check is not load-bearing"; rc=1
  fi
  rm -rf "$red"
else
  echo "== pts_chain_tb: SKIPPED (no fixture) =="
fi

[ $rc -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES (rc=$rc) =="
exit $rc
