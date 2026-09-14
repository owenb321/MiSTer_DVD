#!/usr/bin/env bash
#
# run_quant_matrix.sh -- the quantiser-matrix gate (docs/quant_matrix.md).
#
# A menu still's sequence header DOWNLOADS a custom quantiser matrix. After a
# VBUF flush rtl/mpeg2/vld.v is left mid-picture -- its state machine resets
# only on `rst` -- so when the landing stream arrives it resumes in that stale
# state and can eat 00 00 01 B3 and the 128-byte download before resyncing.
# rtl/mpeg2/iquant.v then keeps default_values=1 (it clears only on a write to
# address 0x3F), so the WHOLE custom matrix is discarded and every AC
# coefficient comes out 4x to 20.75x too large: a "deep fried" menu still.
#
# Measured over the library by tools/qmatrix_scan.py: 820/957 discs download a
# matrix in a menu VOB, 533 of them more than 2x from the default.
#
# The fixture is cut from a real disc (nothing here is synthetic): set
# DVD_ISO_DIR to a library of decrypted rips. Without one every arm SKIPs
# loudly rather than passing on an empty array.
#
#   ./bench/dvd/run_quant_matrix.sh          # GREEN arms
#   ./bench/dvd/run_quant_matrix.sh --red    # also the RED arms first
set -euo pipefail
cd "$(dirname "$0")/../.."

ISO_DIR="${DVD_ISO_DIR:-/mnt/dvd}"
FIX=bench/dvd/test_vobs/quant_matrix
PROBE=bench/dvd/test_vobs/quant_matrix_probe
IV="iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2"
RTL="rtl/mpeg2/vld.v rtl/mpeg2/getbits.v rtl/mpeg2/rld.v rtl/mpeg2/iquant.v \
     rtl/mpeg2/wrappers.v rtl/mpeg2/xfifo_sc.v rtl/mpeg2/xilinx_fifo_dc.v"
rc=0

# ---- fixture -----------------------------------------------------------------
# ⚠ The library is SUBDIVIDED, so a flat glob of $ISO_DIR finds nothing. Ask the
# census which disc qualifies instead of hardcoding a filename: the gate has to
# be able to find its own input on someone else's library.
if [ ! -f "$FIX.hex" ]; then
  SRC="${QM_ISO:-}"
  if [ -z "$SRC" ]; then
    SRC=$(python3 tools/qmatrix_scan.py --first-hit 2>/dev/null || true)
  fi
  if [ -n "$SRC" ] && [ -f "$SRC" ]; then
    echo "== cutting fixture from $(basename "$SRC") =="
    python3 tools/quant_fixture.py "$SRC" --out "$FIX" || true
    python3 tools/quant_fixture.py "$SRC" --matrix-probe --out "$PROBE" || true
  fi
fi
if [ ! -f "$FIX.hex" ]; then
  echo "== quant_matrix: SKIPPED -- set DVD_ISO_DIR to a library of decrypted rips =="
  exit 0
fi

run () {  # run <label> <args...>
  local label="$1"; shift
  local out
  out=$(vvp bench/dvd/quant_matrix_sim +fixture=$FIX "$@" 2>&1 | grep -vE '^WARNING') || true
  echo "$out" | grep -E '^(SUMMARY|RESULT|VACUOUS|   MISMATCH|   \[)' || true
  echo "$out" | grep -q '^RESULT: PASS' || { echo "  FAIL: $label"; rc=1; }
}

# ---- RED: the defect must be REPRODUCED before anything is changed -----------
# QM_FIX=0 ties vld.vbuf_flush low, i.e. the pre-fix vld, so one binary shows
# both that the defect is real and that the new logic is inert when unarmed.
if [ "${1:-}" = "--red" ]; then
  echo "== RED (QM_FIX=0): the flush must LOSE the download =="
  $IV -Pquant_matrix_tb.QM_FIX=0 -o bench/dvd/quant_matrix_red_sim $RTL \
      bench/dvd/quant_matrix_tb.sv
  red_fried=0; red_n=0
  for d in 0 60 140 260 400 620 900 1300 1800 2500 3400 4600; do
    out=$(vvp bench/dvd/quant_matrix_red_sim +fixture=$FIX +FLUSHDLY=$d 2>&1 \
          | grep -vE '^WARNING') || true
    s=$(echo "$out" | grep '^SUMMARY:' || true)
    r=$(echo "$out" | grep -oE 'RESULT: [A-Z]+' || true)
    st=$(echo "$s" | grep -oE 'state_at_flush=[0-9a-f]+' || true)
    echo "   FLUSHDLY=$d  $r  $st"
    red_n=$((red_n+1))
    echo "$r" | grep -q FRIED && red_fried=$((red_fried+1))
  done
  echo "   RED: $red_fried/$red_n swept flush positions lose the matrix"
  if [ "$red_fried" -eq 0 ]; then
    echo "  FAIL: RED found no defect -- the hypothesis is refuted, or the sweep"
    echo "        never caught the vld mid-picture (check state_at_flush above)"
    rc=1
  fi
  # RED for the iquant un-zigzag: a VARIED download after an alternate_scan=1
  # cut A must come back PERMUTED, not merely wrong.
  #
  # ⚠ QM_FIX=0 does NOT cover this one. It reverts the vld/getbits halves, but
  # the iquant scan fix is unconditional RTL, so the QM_FIX=0 binary still
  # un-zigzags correctly and this arm PASSED -- i.e. it was vacuous and proved
  # nothing. A bench cannot mutate a module it instantiates, so mutate a COPY
  # and compile against that (the run_csync_field.sh pattern).
  if [ -f "$PROBE.hex" ]; then
    echo "== RED (scan): a varied download must come back PERMUTED =="
    MUT=$(mktemp -d)
    sed "s/scan_reverse(1'b0, wr_addr)/scan_reverse(alternate_scan, wr_addr)/" \
        rtl/mpeg2/iquant.v > "$MUT/iquant.v"
    if ! grep -q "scan_reverse(alternate_scan, wr_addr)" "$MUT/iquant.v"; then
      echo "  FAIL: the scan mutation did not apply -- iquant.v moved"; rc=1
    fi
    MUTRTL="rtl/mpeg2/vld.v rtl/mpeg2/getbits.v rtl/mpeg2/rld.v $MUT/iquant.v \
            rtl/mpeg2/wrappers.v rtl/mpeg2/xfifo_sc.v rtl/mpeg2/xilinx_fifo_dc.v"
    if $IV -o bench/dvd/quant_matrix_scanred_sim $MUTRTL bench/dvd/quant_matrix_tb.sv \
         2>/dev/null; then
      out=$(vvp bench/dvd/quant_matrix_scanred_sim +fixture=$PROBE +NOFLUSH=1 2>&1 \
            | grep -vE '^WARNING') || true
      echo "$out" | grep -E '^(SUMMARY|RESULT)' || true
      # It must fail, and fail as a PERMUTATION: the multiset is intact and only
      # the positions moved. "Merely wrong" would be a different defect.
      if echo "$out" | grep -q 'permutation=1'; then
        echo "  RED(scan): reproduced as a permutation, as it must be"
      else
        echo "  FAIL: the scan RED did not reproduce a permutation -- this arm"
        echo "        is vacuous and the iquant fix is untested"; rc=1
      fi
    else
      echo "  FAIL: the mutated iquant.v did not compile"; rc=1
    fi
    rm -rf "$MUT"
  fi
fi

$IV -o bench/dvd/quant_matrix_sim $RTL bench/dvd/quant_matrix_tb.sv

echo "== [1] control -- no flush: the download must land, fix or no fix =="
run "[1] no flush" +NOFLUSH=1

echo "== [2] flush, swept across the parse (ALL positions must keep the matrix) =="
for d in 0 60 140 260 400 620 900 1300 1800 2500 3400 4600; do
  run "[2] FLUSHDLY=$d" +FLUSHDLY=$d
done

echo "== [3] freeze: motcomp_busy held across the window, so this proves the"
echo "==     capture is NOT gated by clk_en =="
run "[3] freeze" +FREEZE=1 +FLUSHDLY=140

echo "== [4] scan probe: a VARIED matrix after an alternate_scan=1 cut A =="
if [ -f "$PROBE.hex" ]; then
  out=$(vvp bench/dvd/quant_matrix_sim +fixture=$PROBE +NOFLUSH=1 2>&1 \
        | grep -vE '^WARNING') || true
  echo "$out" | grep -E '^(SUMMARY|RESULT|   MISMATCH)' || true
  echo "$out" | grep -q '^RESULT: PASS' || { echo "  FAIL: [4] scan probe"; rc=1; }
else
  echo "  SKIPPED -- no probe fixture"
fi

echo "== [5] v0.4.0 replay: a SECOND decode of the same cell must be clean."
echo "==     That is what the removed cold re-decode did, and it is why the"
echo "==     symptom only became permanent at v0.5.0 -- if this arm fails the"
echo "==     bench does not reproduce the field's own A/B =="
run "[5] redecode" +REDECODE=1 +FLUSHDLY=140

echo "== [6] +FEEDTHRU: feed through the flush window (fidelity probe)."
echo "==     ⚠ This arm is NOT a demonstrated hazard any more. It was written when"
echo "==     the bit window survived a flush, where feeding early would have let a"
echo "==     FIXED parser eat real landing start codes. Now that getbits_fifo is"
echo "==     reset with the VBUF the early bytes are discarded and it passes. Kept"
echo "==     as a robustness check, and as the record of why the feed model is"
echo "==     written the way it is. Recorded, not gated. =="
out=$(vvp bench/dvd/quant_matrix_sim +fixture=$FIX +FEEDTHRU=1 +FLUSHDLY=140 2>&1 \
      | grep -vE '^WARNING') || true
echo "$out" | grep -E '^(SUMMARY|RESULT)' || true

# ---- regressions on the shared vld edits -------------------------------------
echo "== regression: seek_realign (issue #45) must be untouched =="
if [ -x bench/dvd/run_seek_realign.sh ]; then
  ./bench/dvd/run_seek_realign.sh >/tmp/qm_seek.log 2>&1 && \
    echo "  seek_realign ALL GREEN" || { echo "  FAIL: seek_realign moved"; \
    tail -20 /tmp/qm_seek.log; rc=1; }
fi

[ $rc -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES (rc=$rc) =="
exit $rc
