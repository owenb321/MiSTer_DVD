#!/usr/bin/env bash
# run_mem_shim.sh — mem_shim_burst (DDR burst bridge + set-associative cache)
# regression suite. One command for the whole verification ladder of the
# tag/LRU-to-M10K rework (feature/mem-shim-tag-bram) and any later change to
# the bridge:
#   1. mem_shim_burst_tb   — functional chain test (in-order response checking,
#                            coherence, ADDR_ERR, backpressure) across the four
#                            {cwf,dual} toggle combos + off-default geometries.
#   2. mem_shim_ab_tb      — the BIT-EXACT LRU gate: the live module vs the
#                            frozen flop-tag reference (mem_shim_burst_ref.sv)
#                            on one trace through independently-stalled rigs;
#                            the accepted-burst sequences must be IDENTICAL
#                            (same misses <=> same victims <=> same LRU state).
#   3. cache_missrate_tb   — the {miss%, intensity} telemetry row.
#   4. mem_shim_serialize_tb — the old mem_shim read-serializer guard (kept as
#                            the ordering canary; unchanged by cache work).
#   5. mem_addr_recon_vs_disp_tb — recon-write vs display-read address identity.
#
# Every result line is gated on "RESULT: PASS" (vvp exits 0 even on FAIL — the
# M19 lesson), so a FAIL anywhere fails the script.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

rc=0
run() {
    local name=$1; shift
    local defines=$1; shift
    echo "== $name $defines =="
    # shellcheck disable=SC2086
    iverilog -g2012 $defines -o "bench/dvd/${name}_sim" "$@" "bench/dvd/${name}.sv"
    local out
    out="$(vvp "bench/dvd/${name}_sim")"
    echo "$out" | tail -4
    if ! echo "$out" | grep -q "RESULT: PASS\|RESULT: decode WRITE addr == display READ addr"; then
        rc=1
    fi
}

# 1. functional: default (cwf on, single-outstanding), dual, cwf-off, geometries
run mem_shim_burst_tb ""                              dvd/mem_shim_burst.sv
run mem_shim_burst_tb "-DMSB_DUAL=1"                  dvd/mem_shim_burst.sv
run mem_shim_burst_tb "-DMSB_CWF=0 -DMSB_DUAL=1"      dvd/mem_shim_burst.sv
run mem_shim_burst_tb "-DMSB_ASSOC=2"                 dvd/mem_shim_burst.sv
run mem_shim_burst_tb "-DMSB_NSETS=128 -DMSB_DUAL=1"  dvd/mem_shim_burst.sv

# 2. A/B decision-exactness vs the frozen flop-tag reference (all 4 combos)
for d in "-DMSAB_CWF=1 -DMSAB_DUAL=1" "-DMSAB_CWF=1 -DMSAB_DUAL=0" \
         "-DMSAB_CWF=0 -DMSAB_DUAL=1" "-DMSAB_CWF=0 -DMSAB_DUAL=0"; do
    run mem_shim_ab_tb "$d" dvd/mem_shim_burst.sv bench/dvd/mem_shim_burst_ref.sv
done

# 3. telemetry
run cache_missrate_tb "" dvd/mem_shim_burst.sv

# 4./5. ordering canaries (unchanged modules)
run mem_shim_serialize_tb "" dvd/mem_shim.sv
run mem_addr_recon_vs_disp_tb "-D__IVERILOG__ -I rtl/mpeg2" rtl/mpeg2/mem_addr.v

if [ $rc -eq 0 ]; then echo "RUN_MEM_SHIM: ALL SUITES PASSED";
else echo "RUN_MEM_SHIM: FAILURES"; fi
exit $rc
