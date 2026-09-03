#!/usr/bin/env bash
#
# run_seek_realign.sh -- post-seek reference re-align (GitHub issue #45).
#
# The defect: a VBUF flush discards the buffered bitstream and nothing else, so
# motcomp_picbuf's reference slots survive a seek still holding the PRE-SEEK
# scene. The landing GOP's leading B-pictures motion-compensate against them,
# which on hardware reads as ~6 frames of the new chapter decoding IN MOTION
# with the old image overlaid as residual. Fix: rtl/mpeg2/vld.v drops pictures
# until two post-flush anchors have re-established the references.
# Design: docs/seek_realign.md
#
# The fixture is cut from a real disc (nothing here is synthetic): set
# DVD_ISO_DIR to a library of decrypted DVD-Video rips. Without it every arm
# SKIPs loudly rather than passing on an empty array.
#
#   ./bench/dvd/run_seek_realign.sh          # GREEN arms + the vld regressions
#   ./bench/dvd/run_seek_realign.sh --red    # also the RED arm first (must FAIL
#                                            # to find the defect -- it PASSES by
#                                            # asserting the pre-fix violation count)
set -euo pipefail
cd "$(dirname "$0")/../.."

ISO_DIR="${DVD_ISO_DIR:-$HOME/dvd-isos}"
FIX=bench/dvd/test_vobs/seek_realign
IV="iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2"
RTL="rtl/mpeg2/vld.v rtl/mpeg2/getbits.v rtl/mpeg2/motcomp_picbuf.v"
rc=0

# ---- fixture -----------------------------------------------------------------
if [ ! -f "$FIX.hex" ]; then
  SRC=$(ls "$ISO_DIR"/*.iso "$ISO_DIR"/*.ISO 2>/dev/null | head -1 || true)
  if [ -n "$SRC" ]; then
    echo "== cutting fixture from $(basename "$SRC") (two cuts + a seek between them) =="
    # seek_fixture.py REFUSES a landing whose first GOP is closed or has no
    # leading B's: such a cut would make the RED arm measure zero and the whole
    # gate vacuous. Walk the title until one qualifies.
    for f in 0.60 0.40 0.75 0.25 0.85; do
      if python3 tools/seek_fixture.py "$SRC" --cut-b-frac "$f" --out "$FIX"; then break; fi
    done
  fi
fi
if [ ! -f "$FIX.hex" ]; then
  echo "== seek_realign: SKIPPED -- set DVD_ISO_DIR to a library of decrypted rips =="
  exit 0
fi

# ---- RED: the same TB with the fix's input tied low --------------------------
if [ "${1:-}" = "--red" ]; then
  echo "== RED (SEEK_REALIGN=0): must MEASURE the defect, exactly meta[3] violations =="
  $IV -Pseek_realign_tb.SEEK_REALIGN=0 -o bench/dvd/seek_realign_red_sim $RTL bench/dvd/seek_realign_tb.sv
  vvp bench/dvd/seek_realign_red_sim | grep -vE '^WARNING' || rc=1
fi

$IV -o bench/dvd/seek_realign_sim $RTL bench/dvd/seek_realign_tb.sv

echo "== [1] control -- no flush: the re-align must be completely inert =="
vvp bench/dvd/seek_realign_sim +NOFLUSH=1 | grep -vE '^WARNING' || rc=1

echo "== [2] seek, flush mid-slice (the reported case) =="
vvp bench/dvd/seek_realign_sim | grep -vE '^WARNING' || rc=1

echo "== [3] seek, flush at a picture header =="
vvp bench/dvd/seek_realign_sim +FLUSHDLY=0 | grep -vE '^WARNING' || rc=1

echo "== [4] two flushes on one seek -- the second must RESTART, not be swallowed =="
vvp bench/dvd/seek_realign_sim +REFLUSH=400 | grep -vE '^WARNING' || rc=1

echo "== [5] display-blocked (+DRAIN): the flush window sits inside a vld freeze,"
echo "==     so this is what proves the arm is not gated by clk_en =="
vvp bench/dvd/seek_realign_sim +DRAIN=4000 +FLUSHDLY=20 | grep -vE '^WARNING' || rc=1

echo "== [6] RA_CAP give-up: decoding must resume on a stream that never re-anchors =="
$IV -Pseek_realign_tb.RA_CAP=2 -o bench/dvd/seek_realign_cap_sim $RTL bench/dvd/seek_realign_tb.sv
vvp bench/dvd/seek_realign_cap_sim +CAPARM=1 | grep -vE '^WARNING' || rc=1

# ---- regressions on the shared vld edits -------------------------------------
# vld_drop_rff_tb is the ledger-split gate: drop_pic_ack must still fire for the
# governor's drops and ONLY for those.
echo "== regression: vld_drop_rff_tb (governor drop ack ledger) =="
$IV -o bench/dvd/vld_drop_rff_sim $RTL bench/dvd/vld_drop_rff_tb.sv
vvp bench/dvd/vld_drop_rff_sim +ES=$FIX.hex +MAXPIC=18 | tail -3 || rc=1

[ $rc -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES (rc=$rc) =="
exit $rc
