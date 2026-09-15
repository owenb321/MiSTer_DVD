#!/usr/bin/env bash
# run_sync_integrity.sh -- a decoder SOFT RESET must be invisible at the video sync pins.
#
#   bench/dvd/run_sync_integrity.sh          GREEN only
#   bench/dvd/run_sync_integrity.sh --red    run the RED arm first and require it to FAIL
#
# See bench/dvd/sync_integrity_tb.sv for what is measured and why.
set -u
cd "$(dirname "$0")/../.."

SIM=bench/dvd/sync_integrity_sim
SRC=(rtl/mpeg2/syncgen.v rtl/mpeg2/syncgen_intf.v rtl/mpeg2/mixer.v
     rtl/mpeg2/osd.v rtl/mpeg2/yuv2rgb.v rtl/mpeg2/synchronizer.v
     bench/dvd/sync_integrity_tb.sv)

# -s: osd.v also defines osd_clt, which iverilog would otherwise elaborate as a second
# root and fail on its dpram_dc/Xilinx FIFO wrappers.
iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -s sync_integrity_tb -o "$SIM" "${SRC[@]}" || {
    echo "run_sync_integrity: COMPILE FAILED"; exit 1; }

if [ "${1:-}" = "--red" ]; then
    echo "== RED: hard_rst tied to rst (the pre-2026-09-15 reset domain) =="
    if vvp "$SIM" +tie_hard=1 > /tmp/sync_red.log 2>&1; then
        echo "run_sync_integrity: RED ARM PASSED -- the gate cannot see the defect"
        cat /tmp/sync_red.log; exit 1
    fi
    grep -E "DE dots|differs|FAIL" /tmp/sync_red.log
    echo "   ^ RED failed as required"
    echo
fi

echo "== GREEN: the shipped reset domain =="
vvp "$SIM" || { echo "run_sync_integrity: GREEN FAILED"; exit 1; }
echo "run_sync_integrity: all green"
