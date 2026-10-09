#!/usr/bin/env bash
# run_mem_prefetch.sh — gate for dvd/mem_req_prefetch.sv, the read-side retime of
# framestore's memory request FIFO (clk_mem retime, 2026-10-09).
#
#   bench/dvd/run_mem_prefetch.sh [--red]
#
# 1. mem_req_prefetch_tb: the contract bench (real xilinx_fifo_dc in front, 54 -> 90
#    MHz), arms ORDER / EAGER / TPUT / STALE / COUNT.
# 2. The bridge's own suites through the queue: mem_shim_burst_tb (-DMSB_PREFETCH,
#    in-order response checking) and mem_shim_ab_tb (-DMSAB_PREFETCH, decision-exact
#    against the frozen reference: identical burst sequences while the queue changes
#    when each command reaches the bridge).
# --red: each mutation must fail, and fail its OWN arm.
#
# Every result is gated on "RESULT: PASS" (vvp exits 0 on $finish).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

rc=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIFO_SRC="rtl/mpeg2/xilinx_fifo_dc.v"

contract() {   # contract <label> <module file> [defines...]
    local label=$1 mod=$2; shift 2
    # shellcheck disable=SC2068
    iverilog -g2012 -I rtl/mpeg2 $@ -o "$TMP/mrp_sim" "$mod" "$FIFO_SRC" bench/dvd/mem_req_prefetch_tb.sv
    vvp "$TMP/mrp_sim" 2>&1 || true
}

echo "== mem_req_prefetch_tb (D=4) =="
out="$(contract green dvd/mem_req_prefetch.sv)"
echo "$out" | grep -E "TPUT:|ARM|RESULT|wrote"
echo "$out" | grep -q "RESULT: PASS" || rc=1

run() {
    local name=$1; shift
    local defines=$1; shift
    echo "== $name $defines =="
    # shellcheck disable=SC2086
    iverilog -g2012 $defines -o "$TMP/${name}_sim" "$@" "bench/dvd/${name}.sv"
    local o
    o="$(vvp "$TMP/${name}_sim" 2>&1 || true)"
    echo "$o" | grep -E "RESULT|REF:" | tail -3
    echo "$o" | grep -q "RESULT: PASS" || rc=1
}

for d in "" "-DMSB_DUAL=1" "-DMSB_CWF=0 -DMSB_DUAL=1"; do
    run mem_shim_burst_tb "-DMSB_PREFETCH $d" dvd/mem_shim_burst.sv dvd/mem_req_prefetch.sv
done
for d in "-DMSAB_CWF=1 -DMSAB_DUAL=1" "-DMSAB_CWF=1 -DMSAB_DUAL=0" \
         "-DMSAB_CWF=0 -DMSAB_DUAL=1" "-DMSAB_CWF=0 -DMSAB_DUAL=0"; do
    run mem_shim_ab_tb "-DMSAB_PREFETCH $d" dvd/mem_shim_burst.sv bench/dvd/mem_shim_burst_ref.sv \
        dvd/mem_req_prefetch.sv
done

if [ "${1:-}" = "--red" ]; then
    red() {  # red <label> <sed expression> <must-match grep> <arm that must FAIL> [defines]
        local label=$1 expr=$2 must=$3 arm=$4 defs=${5:-}
        sed "$expr" dvd/mem_req_prefetch.sv > "$TMP/mut.sv"
        if ! grep -q "$must" "$TMP/mut.sv"; then
            echo "== RED $label: FAIL -- the mutation did not apply"; rc=1; return
        fi
        local o
        o="$(contract "$label" "$TMP/mut.sv" $defs)"
        if echo "$o" | grep -q "RESULT: PASS"; then
            echo "== RED $label: FAIL -- the bench cannot see this mutation"; rc=1
        elif ! echo "$o" | grep -q "$arm"; then
            echo "== RED $label: FAIL -- it failed, but not with \"$arm\""; rc=1
            echo "$o" | grep -E "ARM|fatal|FAIL" | head -6
        else
            echo "== RED $label: caught ($arm)"
        fi
    }
    red "credit off by one" 's/assign up_rd_en = (committed <= D-1);/assign up_rd_en = (committed <= D); \/\/ MUT/' 'MUT' \
        "credit invariant\|slots full"
    red "eager valid"       's/            dn_valid <= do_read;/            dn_valid <= (count != 0); \/\/ MUT/' 'MUT' \
        "ARM EAGER: FAIL"
    red "wrong slot out"    's/assign dn_dout = slot\[pptr\];/assign dn_dout = slot[rptr]; \/\/ MUT/' 'MUT' \
        "ARM ORDER: FAIL"
    red "pop when empty"    's/wire do_read = dn_rd_en && (count != {(AW+1){1.b0}});/wire do_read = dn_rd_en; \/\/ MUT/' 'MUT' \
        "ARM ORDER: FAIL\|credit invariant"
    # Wiring, not code: the queue on a power-on-only reset instead of the FIFO's.
    red "queue on POR reset" 's/^`default_nettype none$/`default_nettype none \/\/ MUT (unchanged; POR reset via define)/' 'MUT' \
        "ARM STALE: FAIL" "-DMRP_RST_POR"
    # D=2 is a parameter choice, not a code edit: same file, the bench's -DMRP_D=2.
    red "two slots (D=2)"   's/^`default_nettype none$/`default_nettype none \/\/ MUT (unchanged; D=2 via define)/' 'MUT' \
        "ARM TPUT: FAIL" "-DMRP_D=2"
fi

if [ $rc -eq 0 ]; then echo "RUN_MEM_PREFETCH: ALL PASSED"; else echo "RUN_MEM_PREFETCH: FAILURES"; fi
exit $rc
