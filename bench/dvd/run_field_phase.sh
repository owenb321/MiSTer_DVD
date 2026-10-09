#!/usr/bin/env bash
#
# run_field_phase.sh — do the two displayed fields carry DIFFERENT source lines,
# on the matching raster parity? (bench/dvd/field_phase_tb.sv; docs/field_parity.md.)
#
# This is the bench that can see the HW defect field_parity_tb could not: it feeds the
# behavioural framestore LINE-STAMPED data and measures what the mixer EMITTED for
# consecutive fields, instead of restating the RTL's own parity convention. It is the
# gate for the field-parity corrector (issue #41).
#
# It checks three invariants per window (see the testbench header):
#   A  consecutive fields must carry DIFFERENT source lines  (the +0.50 field offset a
#      real interlaced still measures; the withdrawn corrector made it +0.00)
#   B  the emitted content repeats with period 2
#   C  an even (top) source line lands in an even (top) raster field — derived from the
#      DATA, so it does not agree with the RTL by construction
#
# Both raster-phase arms must pass. Add +dbg to either vvp line for a per-field table.
#
# Runtime: ~10 minutes per arm. Most of it is scenarios [7] and [8], whose settle windows
# have to be long enough for the FEEDBACK arm to confirm (PAR_CONFIRM refreshes in
# dvd/resample_addrgen.v) — shortening them would make the bench green against a
# corrector that never heals. ([1] used to be one of them; since the strict first-field
# placement a start has no settle window at all.)
#
# --red also runs the START mutations (docs/field_parity.md "Strict first field"): each
# breaks the mixer's strict first-field placement one way, and each must fail its own
# window in +start_only mode ([1], [10], [11] only; ~3 minutes, run concurrently):
#   S1  the strict term removed from display_first_pixel  -> [1]/[10] MISALIGNED
#   S2  start_strict never armed by a reset                -> [1]/[10] MISALIGNED
#   S3  the raster-restart arm removed                     -> [11-raster-restart-bot]
set -e
cd "$(dirname "$0")/../.."

RTL_A="rtl/mpeg2/resample.v dvd/resample_addrgen.v rtl/mpeg2/resample_dta.v \
  rtl/mpeg2/resample_bilinear.v rtl/mpeg2/mem_addr.v"
RTL_B="rtl/mpeg2/pixel_queue.v rtl/mpeg2/syncgen.v rtl/mpeg2/read_write.v \
  rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xilinx_fifo_dc.v \
  rtl/mpeg2/xfifo_sc.v bench/dvd/field_phase_tb.sv"
iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/field_phase_sim \
  $RTL_A rtl/mpeg2/mixer.v $RTL_B

# ⚠ `vvp ... | grep ... || fail=1` reads GREP's exit status, never vvp's: a $fatal arm
# prints FAIL, exits non-zero, and the pipe swallows it while the suite reports success.
# That is the defect PR #63 fixed in the STC field suites (a9b8bb6); it was still here.
# PIPESTATUS[0] is the simulator's own status.
fail=0
for p in 0 1; do
  echo
  echo "============ +phase=$p ============"
  vvp bench/dvd/field_phase_sim +phase=$p | grep -vE '^\s*$'; [ "${PIPESTATUS[0]}" -eq 0 ] || fail=1
done

if [ "${1:-}" = "--red" ]; then
  echo
  echo "============ START MUTATIONS (+start_only; each must FAIL its own window) ============"
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  _mut() {  # name  old  new  expect-regex
    local name=$1 d="$TMP/$1"; mkdir -p "$d"
    python3 - "$d/mixer.v" "$2" "$3" <<'PYEOF' || { echo "  $name: anchor not found" > "$TMP/$name.res"; return; }
import sys
out, old, new = sys.argv[1:4]
s = open('rtl/mpeg2/mixer.v').read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(out, 'w').write(s.replace(old, new))
PYEOF
    iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o "$d/sim" $RTL_A "$d/mixer.v" $RTL_B \
      >/dev/null 2>&1 || { echo "  $name: BUILD FAILED (a mutation that does not compile proves nothing)" > "$TMP/$name.res"; return; }
    local out=""
    # `|| true`: under set -e a failing vvp would end this job, and a FAILING arm is the point
    for p in 0 1; do out+=$(vvp "$d/sim" +phase=$p +start_only 2>&1 || true); out+=$'\n'; done
    if echo "$out" | grep -qE "$4"; then
      echo "  $name: caught ($(echo "$out" | grep -E "$4" | head -1 | cut -c1-90))" > "$TMP/$name.res"
    else
      { echo "  $name: *** NOT CAUGHT -- the bench cannot see this defect ***"; echo "MUTFAIL"; } > "$TMP/$name.res"
    fi
  }
  _mut S1 "is_frame_top && ~strict_refuse_slot && (v_pos" "is_frame_top && (v_pos" \
       '^\[(1-cold-start|10-soft-reset-[ab])\] FAIL: [0-9]+ misaligned' &
  _mut S2 "if (~rst) start_strict <= 1'b1;" "if (~rst) start_strict <= 1'b0;" \
       '^\[(1-cold-start|10-soft-reset-[ab])\] FAIL: [0-9]+ misaligned' &
  _mut S3 "    else if (raster_restart) start_strict <= 1'b1;"$'\n' "" \
       '^\[11-raster-restart-bot\] FAIL: [0-9]+ misaligned' &
  wait
  for m in S1 S2 S3; do
    if [ -f "$TMP/$m.res" ]; then cat "$TMP/$m.res"; grep -q MUTFAIL "$TMP/$m.res" && fail=1
    else echo "  $m: NO RESULT"; fail=1; fi
  done
fi

echo
[ $fail -eq 0 ] && echo "run_field_phase: ALL GREEN" || echo "run_field_phase: FAILURES"
exit $fail
