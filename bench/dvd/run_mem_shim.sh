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

# 2b. LOCKSTEP retime gate (clk_mem timing, 2026-10-05): the live module must be
# CYCLE-exact -- every functional port plus the FSM state, every cycle, identical inputs -- against the module as
# it was before the deferred-victim-invalidate retime. The reference is built from git
# at RETIME_BASE (a commit on main), renamed, so no 1,100-line frozen copy is checked in.
# ⚠ This arm pins one intended-no-op change. A later change to mem_shim_burst that is
# MEANT to alter timing will fail it: move RETIME_BASE to that change's parent, or drop
# the arm, and say which in the commit.
RETIME_BASE="${RETIME_BASE:-1ee4f2b}"
LS_TMP="$(mktemp -d)"
trap 'rm -rf "$LS_TMP"' EXIT
if git cat-file -e "$RETIME_BASE:dvd/mem_shim_burst.sv" 2>/dev/null; then
    git show "$RETIME_BASE:dvd/mem_shim_burst.sv" \
        | sed 's/^module mem_shim_burst\b/module mem_shim_burst_pre/' > "$LS_TMP/mem_shim_burst_pre.sv"
    for d in "-DMSAB_CWF=1 -DMSAB_DUAL=1" "-DMSAB_CWF=1 -DMSAB_DUAL=0" \
             "-DMSAB_CWF=0 -DMSAB_DUAL=1" "-DMSAB_CWF=0 -DMSAB_DUAL=0"; do
        run mem_shim_ab_tb "$d -DMSAB_LOCKSTEP -DMSAB_REF_MOD=mem_shim_burst_pre" \
            dvd/mem_shim_burst.sv "$LS_TMP/mem_shim_burst_pre.sv"
    done

    # --red: each mutation must FAIL the lockstep arm (dual on, so both sites run).
    if [ "${1:-}" = "--red" ]; then
        red() {  # red <label> <sed expression> <must-match grep> [<required failure text>]
            local label=$1 expr=$2 must=$3 want=${4:-}
            sed "$expr" dvd/mem_shim_burst.sv > "$LS_TMP/mut.sv"
            if ! grep -q "$must" "$LS_TMP/mut.sv"; then
                echo "== RED $label: FAIL -- the mutation did not apply"; rc=1; return
            fi
            iverilog -g2012 -DMSAB_CWF=1 -DMSAB_DUAL=1 -DMSAB_LOCKSTEP -DMSAB_REF_MOD=mem_shim_burst_pre \
                -o "$LS_TMP/red_sim" "$LS_TMP/mut.sv" "$LS_TMP/mem_shim_burst_pre.sv" bench/dvd/mem_shim_ab_tb.sv
            local out
            out="$(vvp "$LS_TMP/red_sim" 2>&1 || true)"
            if echo "$out" | grep -q "RESULT: PASS"; then
                echo "== RED $label: FAIL -- the lockstep arm cannot see this mutation"; rc=1
            elif [ -n "$want" ] && ! echo "$out" | grep -q "$want"; then
                echo "== RED $label: FAIL -- it failed, but not with \"$want\""; rc=1
            else
                echo "== RED $label: caught, as it must be"
                echo "$out" | grep -E "LOCKSTEP MISMATCH|FATAL|fatal|RESULT" | head -2
            fi
        }
        red "site-A wrong way" 's/if (inv_a_pend) cache_valid\[cur_set\]\[sel_way\]/if (inv_a_pend) cache_valid[cur_set][sel_way+1'"'"'b1]/' 'sel_way+1'
        red "site-B wrong way" 's/if (inv_b_pend) cache_valid\[ifb_set\]\[ifb_way\]/if (inv_b_pend) cache_valid[ifb_set][ifb_way+1'"'"'b1]/' 'ifb_way+1'
        red "guard alive"      's/^            inv_a_pend <= 1.b0;$/            inv_a_pend <= inv_a_pend; \/\/ MUT/' 'MUT' \
            "deferred invalidate pending"
        # The speculative-pop retime (2026-10-09): data loads moved off the verdicts and
        # the DDR3 compare honours the Avalon contract. Each arm must still be caught.
        red "addr under read"  '/^            S_FILL_CMD: begin$/a\                ddr3_addr <= ddr3_addr ^ 29'"'"'d8; // MUT' 'MUT' \
            "LOCKSTEP MISMATCH"
        red "exit keeps pA"    's/^                        pA_valid     <= 1.b0;$/                        pA_valid     <= pA_valid; \/\/ MUT/' 'MUT' \
            "LOCKSTEP MISMATCH"
        red "A reads cand set" 's/^    wire \[ASSOC-1:0\]  a_valid = cache_valid\[pA_set\];/    wire [ASSOC-1:0]  a_valid = cache_valid[cand_set]; \/\/ MUT/' 'MUT' \
            "LOCKSTEP MISMATCH"
        red "no beat reset"    's/^                    beat           <= 0;                    \/\/ fresh fill/                    \/\/ MUT beat reset dropped/' 'MUT' \
            "LOCKSTEP MISMATCH"
    fi
else
    echo "== LOCKSTEP: SKIPPED -- RETIME_BASE $RETIME_BASE not in this clone's history"
fi

# 3. telemetry
run cache_missrate_tb "" dvd/mem_shim_burst.sv

# 4./5. ordering canaries (unchanged modules)
run mem_shim_serialize_tb "" dvd/mem_shim.sv
run mem_addr_recon_vs_disp_tb "-D__IVERILOG__ -I rtl/mpeg2" rtl/mpeg2/mem_addr.v

if [ $rc -eq 0 ]; then echo "RUN_MEM_SHIM: ALL SUITES PASSED";
else echo "RUN_MEM_SHIM: FAILURES"; fi
exit $rc
