#!/usr/bin/env bash
#
# run_field_parity.sh — build & run the field-parity re-engage suite
# (bench/dvd/field_parity_tb.sv; design + RED evidence: docs/field_parity.md).
#
# Default: build against the CURRENT RTL and run both raster-phase arms —
# every window must pass in both.
#
# --red <dir>: reproduce the historical RED capture — build with
# -DNO_PARITY_FIX against PRE-FIX copies of resample.v, resample_addrgen.v and
# mixer.v placed in <dir> (e.g. extracted with `git show <pre-fix-rev>:<path>`).
# Expected result: each +phase arm FAILS at least one window — the misalignment,
# once entered, persists (the proven coin flip the fix removes).
#
set -e
cd "$(dirname "$0")/../.."

RS=rtl/mpeg2/resample.v
AG=dvd/resample_addrgen.v
MX=rtl/mpeg2/mixer.v
DEFS=""
OUT=bench/dvd/field_parity_sim

if [ "$1" = "--red" ]; then
  BD="$2"
  [ -n "$BD" ] || { echo "usage: $0 [--red <baseline-dir>]"; exit 1; }
  RS="$BD/resample.v"; AG="$BD/resample_addrgen.v"; MX="$BD/mixer.v"
  DEFS="-DNO_PARITY_FIX"
  OUT=bench/dvd/field_parity_sim_red
  echo "### RED build (pre-fix RTL from $BD, -DNO_PARITY_FIX) — failures EXPECTED"
fi

iverilog -g2012 -D__IVERILOG__ $DEFS -I rtl/mpeg2 -o "$OUT" \
  "$RS" "$AG" rtl/mpeg2/resample_dta.v rtl/mpeg2/resample_bilinear.v \
  rtl/mpeg2/mem_addr.v "$MX" rtl/mpeg2/pixel_queue.v rtl/mpeg2/syncgen.v \
  rtl/mpeg2/read_write.v rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v \
  rtl/mpeg2/xilinx_fifo_dc.v rtl/mpeg2/xfifo_sc.v \
  bench/dvd/field_parity_tb.sv

fail=0
for p in 0 1; do
  echo
  echo "============ +phase=$p ============"
  vvp "$OUT" +phase=$p | grep -vE '^\s*$' || fail=1
done
exit $fail
