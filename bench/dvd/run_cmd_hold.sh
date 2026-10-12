#!/usr/bin/env bash
# run_cmd_hold.sh -- a title cell command waits for the displayed cell end while
# buttons are up (issue #176, docs/dvd_nav.md "A cell command with buttons up").
#
# GREEN: iso_reader_cmdhold_tb (the reader + dvd_vm, arms A1 A2 B C D E P1-P4)
#        + the benches that share the drain gate and the cell-end dispatch:
#          iso_reader_celldur_tb, iso_reader_vm_tb, iso_reader_auddrain_tb,
#          iso_reader_stilloff_tb
#        + tools/check_cmd_hold_wiring.py --red (the emu.sv seam: .cc_btns is
#          nav_pci's armed | pend, .vbuf_empty is the low-water mark)
#        Bit-identity of every other reader bench with the hold tied off is
#        run_reader_regress.sh --baseline <main>; it is not repeated here.
# RED  : perl-mutated copies of the reader. Each must fail exactly its own arms.
#     R1 no-hold      : the cell end never holds              -> A1 A2 B C D E P3
#                       (B rides on A2: a missed shot never reaches cell 1)
#     R2 no-buttons   : the hold ignores cc_btns              -> B
#     R3 jump-stale   : jump_go leaves the hold latched       -> D P4
#                       (the stale latch is still up when P4 starts)
#     R4 no-watchdog  : DRAIN_WD's timer never runs for it    -> E
#     R5 cache-only   : the hold waits for the cache only,    -> A1 A2 B E P3
#                       not the VBUF
#     R6 vbuf-only    : the hold dispatches with the reader's -> C
#                       cache still full
#   the FIXED-command classifier (fx_mem / cmd_fixed_w):
#     R7 all-held     : nothing is fixed                      -> P1 P2
#     R8 tail-fixed   : LinkTailPGC classed as fixed          -> P3
#     R9 no-nr-guard  : an invalid cmd_nr reads fx_mem        -> P3 P4
#                       (P4's cell holds, so P3's sequence runs a cell late)
#     R10 set-fixed   : a Set (types 2-6) classed as fixed    -> C
#     R11 cond-fixed  : the compare op ignored                -> A1 A2 B D E
#
# Usage: bench/dvd/run_cmd_hold.sh [--red]
set -u
cd "$(dirname "$0")/../.."
RED=0; [ "${1:-}" = "--red" ] && RED=1
RD="dvd/dvd_iso_reader.sv"
TB="bench/dvd/iso_reader_cmdhold_tb.sv"
OUT=".sim/cmd_hold"; mkdir -p "$OUT"
fail=0

# run <name> <pass-string> <tb> <rtl...>
run() {
    local name=$1 pass=$2 tb=$3; shift 3
    if iverilog -g2012 -y dvd -Y .sv -o "$OUT/$name" "$@" "$tb" 2>"$OUT/$name.build"; then
        if timeout 900 vvp "$OUT/$name" > "$OUT/$name.log" 2>&1 && grep -q "$pass" "$OUT/$name.log"; then
            echo "  PASS $name"
        else
            echo "  FAIL $name"; grep -E "FAIL|ERR|TIMEOUT" "$OUT/$name.log" | head -20; fail=1
        fi
    else
        echo "  FAIL $name (build)"; sed 's/^/      /' "$OUT/$name.build" | head -20; fail=1
    fi
}

echo "== GREEN =="
run cmdhold  "ISO_READER_CMDHOLD_TB: ALL TESTS PASSED" $TB $RD
grep -E '^(A1|A2|B|C|D|E|P[1-4]) PASS' "$OUT/cmdhold.log" | sed 's/^/    /'
run celldur  "ALL TESTS PASSED"     bench/dvd/iso_reader_celldur_tb.sv $RD
run vm       "ALL TESTS PASSED"     bench/dvd/iso_reader_vm_tb.sv $RD
run auddrain "RESULT: PASS"         bench/dvd/iso_reader_auddrain_tb.sv $RD
run stilloff "ISO_READER_STILLOFF_TB: ALL TESTS PASSED" bench/dvd/iso_reader_stilloff_tb.sv $RD
# emu.sv has no bench: the seam is read out of the file
if python3 tools/check_cmd_hold_wiring.py --red > "$OUT/wiring.log" 2>&1; then
    echo "  PASS check_cmd_hold_wiring (+ its red self-test)"
else
    echo "  FAIL check_cmd_hold_wiring"; sed 's/^/      /' "$OUT/wiring.log"; fail=1
fi

if [ $RED -eq 1 ]; then
    echo "== RED (each mutation must fail exactly its arms) =="
    # mutate <name> <expected arms> <perl -0pe expression>
    mutate() {
        local name=$1 want=$2 expr=$3
        local src="$OUT/$name.sv"
        perl -0pe "$expr" "$RD" > "$src"
        if cmp -s "$RD" "$src"; then
            echo "  FAIL $name: the expression matched nothing (mutation is stale)"; fail=1; return
        fi
        if ! iverilog -g2012 -y dvd -Y .sv -o "$OUT/$name" "$src" "$TB" 2>"$OUT/$name.build"; then
            echo "  FAIL $name (build)"; sed 's/^/      /' "$OUT/$name.build" | head; fail=1; return
        fi
        timeout 900 vvp "$OUT/$name" > "$OUT/$name.log" 2>&1
        local got
        got=$(grep -oE '^(A1|A2|B|C|D|E|P[1-4]) FAIL' "$OUT/$name.log" | awk '{print $1}' \
              | sort | tr '\n' ' ' | sed 's/ $//')
        want=$(echo "$want" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
        if grep -q "ALL TESTS PASSED" "$OUT/$name.log"; then got="(none)"; fi
        if [ "$got" = "$want" ]; then
            echo "  ok   $name -> fails [$got]"
        else
            echo "  FAIL $name: failed [$got], expected [$want]"; fail=1
        fi
    }
    mutate R1_no_hold     "A1 A2 B C D E P3" 's/end else if \(cmd_hold_w\) begin/end else if (1'"'"'b0) begin/'
    mutate R2_no_buttons  "B"           's/(cmd_hold_w = vm_mode && !menu_dom && )cc_btns &&/$1/'
    mutate R3_jump_stale  "D P4"         's/vmw_cmd_pend <= 1'"'"'b0;\n(\s*jump_ack     <= 1'"'"'b1;)/$1/'
    mutate R4_no_watchdog "E"           's/\(vmw_pgc_pend \|\| vmw_cmd_pend \|\| \(jump_pending/(vmw_pgc_pend || (jump_pending/'
    mutate R5_cache_only  "A1 A2 B E P3"  's/\(vmw_pgc_pend \|\| vmw_cmd_pend\) && ~menu_dom/vmw_pgc_pend \&\& ~menu_dom/'
    mutate R6_vbuf_only   "C"           's/if \(strm_done && !blk_inflight && !cache_has_data && !tail_wait\)/if (strm_done \&\& !blk_inflight \&\& (!cache_has_data || vmw_cmd_pend) \&\& !tail_wait)/'
    mutate R7_all_held    "P1 P2"       's/!fx_rd && \(cm_rd/(cm_rd/'
    mutate R8_tail_fixed  "P3"          's/pb_rdata\[4:0\] != 5'"'"'d13 && //'
    mutate R9_no_nr_guard "P3 P4"        's/!fx_rd && \(cm_rd\[7:0\] <= cmd_nr_cell\)/!fx_rd/'
    mutate R10_set_fixed  "C"           's/\(\(cmd_b0\[7:5\] == 3'"'"'d0\) \|\|/((cmd_b0[7:5] != 3'"'"'d1) ||/'
    mutate R11_cond_fixed "A1 A2 B D E" 's/wire       cmd_fixed_w = \(cmd_b1\[6:4\] == 3'"'"'d0\) &&/wire       cmd_fixed_w = 1'"'"'b1 \&\&/'
fi

if [ $fail -eq 0 ]; then echo "run_cmd_hold: PASS"; else echo "run_cmd_hold: FAIL"; exit 1; fi
