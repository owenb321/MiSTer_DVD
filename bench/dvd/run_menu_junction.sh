#!/usr/bin/env bash
#
# run_menu_junction.sh -- the MENU->MENU (keep_vbuf) junction gate.
#                         docs/dvd_menu_refinements.md, docs/quant_matrix.md
#
# THE DEFECT.  A natural menu verdict (a cell command / POST block that links to
# another menu PGC) used to execute the moment the VM answered, while up to
# 16 KB of the source cell still sat UNDELIVERED in the reader's stream cache --
# the reader leaves S_STREAM for S_VM_WAIT at the last block READ, and the output
# pipeline only runs while `streaming`.  dvd/flush_ctl.sv then pulses load_flush
# alone (keep_vbuf), so the decoder's buffer is NOT flushed: it simply ends on a
# picture cut mid-slice, immediately followed by the landing still's 00 00 01 B3.
#
# The vld is mid-macroblock when that header arrives.  It eats it, and because
# the source cell carried no sequence_end_code `sequence_header_seen` is still 1,
# so the landing's picture start code is accepted anyway -- decoded with the
# SOURCE's quantiser matrix instead of the landing's.  On ULTIMATE_T2's Mission
# Profiles the transition clip downloads a near-flat matrix and the slides
# download none, so the first slide of every slideshow decodes wrong and stays
# wrong.  (v0.4.0 hid it: the menu-still cold re-decode re-streamed the cell, so
# the still was fried for a split second and then repaired.  That re-decode was
# removed in v0.5.0 -- b900478, issue #65 -- and the defect became permanent.)
#
# WHAT THIS MEASURES.  --trunc N is how many bytes of the source cell never
# reach the decoder.  It is a property of the DISC and the SPLICE, not of any
# signal the fix names: the arms feed cut A then cut B contiguously with NO
# flush (+NOFLUSH=1 -- a keep_vbuf hop) and score the matrix the hardware ends
# up holding against what the disc authored.
#
#   [J0]  --trunc 0     the fix: the whole cell delivered  -> must PASS
#   [J1]  --trunc N>0   the defect: the cache dropped       -> must FRY
#   [J2]  the landing alone (+COLDSTART=1)                  -> must PASS
#
# [J0] is the gate.  [J1] is the reproduction and is EXPECTED to fry -- it is
# what the hardware did before the reader change, and it stays red by nature.
# [J2] proves the measurement can report success at all.
#
# ⚠ [J0] is only meaningful while it is NON-VACUOUS: the source's download must
# actually have happened (downloads=1) or the RAM would hold the defaults for
# the trivial reason that nothing ever wrote it.  The runner asserts that.
#
#   ./bench/dvd/run_menu_junction.sh          # J0 gate + J1 reproduction + J2
#   ./bench/dvd/run_menu_junction.sh --red    # same, with every J1 offset listed
set -euo pipefail
cd "$(dirname "$0")/../.."

ISO_DIR="${DVD_ISO_DIR:-/mnt/dvd}"
FIX=bench/dvd/test_vobs/menu_junction
IV="iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2"
RTL="rtl/mpeg2/vld.v rtl/mpeg2/getbits.v rtl/mpeg2/rld.v rtl/mpeg2/iquant.v \
     rtl/mpeg2/wrappers.v rtl/mpeg2/xfifo_sc.v rtl/mpeg2/xilinx_fifo_dc.v"
rc=0

# ---- fixture -----------------------------------------------------------------
# The shape this gate needs is specific (a motion transition cell that downloads
# a matrix and carries no sequence_end_code, linking to a still that downloads
# none), so the fixture names its disc.  Without the library every arm SKIPs
# loudly rather than passing on an empty array.
ISO="${MJ_ISO:-}"
if [ -z "$ISO" ]; then
  ISO=$(find "$ISO_DIR" -iname 'ULTIMATE_T2.iso' -print -quit 2>/dev/null || true)
fi
if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
  echo "== menu_junction: SKIPPED -- ULTIMATE_T2.iso not found under $ISO_DIR"
  echo "   (set DVD_ISO_DIR, or MJ_ISO=/path/to/ULTIMATE_T2.iso)"
  exit 0
fi

mkdir -p "$(dirname $FIX)"
$IV -o bench/dvd/menu_junction_sim $RTL bench/dvd/quant_matrix_tb.sv

# run <label> <fixture-stem> <expect PASS|FRIED> [extra vvp args...]
run () {
  local label="$1" stem="$2" expect="$3"; shift 3
  local out res dl
  out=$(vvp bench/dvd/menu_junction_sim +fixture="$stem" "$@" 2>&1 \
        | grep -vE '^WARNING') || true
  res=$(echo "$out" | grep -oE 'RESULT: [A-Z]+' | head -1 || true)
  dl=$(echo "$out" | grep -oE 'downloads=[0-9]+' | head -1 || true)
  echo "   $label  ${res:-RESULT: (none)}  $dl  $(echo "$out" | grep -oE 'mismatches=[0-9]+/64' | head -1)"
  case "$expect" in
    PASS)  echo "$res" | grep -q 'PASS'  || { echo "  FAIL: $label expected PASS"; rc=1; } ;;
    FRIED) echo "$res" | grep -q 'FRIED' || { echo "  FAIL: $label expected FRIED"; rc=1; } ;;
  esac
  # anti-vacuity: the source's matrix must really have been downloaded, else a
  # PASS means only that nothing ever wrote the RAM.
  if [ "$expect" = "PASS" ] && [ "$label" != "[J2]" ]; then
    echo "$dl" | grep -qE 'downloads=[1-9]' || {
      echo "  FAIL: $label is VACUOUS -- cut A never downloaded its matrix"; rc=1; }
  fi
}

echo "== menu_junction: $(basename "$ISO") VTSM01 PGC14 cell1 -> PGC20 cell0 =="
python3 tools/quant_fixture.py "$ISO" --junction --trunc 0 --out "${FIX}_t0" \
  | sed 's/^/   /'

echo "== [J0] the whole cell delivered (the fix) -- must PASS =="
run "[J0]" "${FIX}_t0" PASS +NOFLUSH=1
echo "== [J2] the landing alone -- must PASS (the measurement can succeed) =="
run "[J2]" "${FIX}_t0" PASS +COLDSTART=1

echo "== [J1] the cache dropped (the defect) -- must FRY at some offset =="
fried=0; n=0
for t in 8 64 300 1000 1800 2600 3400; do
  python3 tools/quant_fixture.py "$ISO" --junction --trunc $t --out "${FIX}_t$t" \
    >/dev/null 2>&1 || { echo "   --trunc $t: fixture refused"; continue; }
  out=$(vvp bench/dvd/menu_junction_sim +fixture="${FIX}_t$t" +NOFLUSH=1 2>&1 \
        | grep -vE '^WARNING') || true
  res=$(echo "$out" | grep -oE 'RESULT: [A-Z]+' | head -1 || true)
  mm=$(echo "$out" | grep -oE 'mismatches=[0-9]+/64' | head -1 || true)
  echo "   --trunc $t  ${res:-RESULT: (none)}  $mm"
  n=$((n+1))
  echo "$res" | grep -q FRIED && fried=$((fried+1))
done
echo "   [J1]: $fried/$n truncation offsets lose the landing's matrix"
if [ "$fried" -eq 0 ]; then
  echo "  FAIL: [J1] reproduced nothing -- the mechanism is refuted, or the"
  echo "        truncation never caught the vld mid-picture"
  rc=1
fi

[ "$rc" -eq 0 ] && echo "== menu_junction: OK ==" || echo "== menu_junction: FAIL =="
exit $rc
