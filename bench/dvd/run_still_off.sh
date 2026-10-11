#!/usr/bin/env bash
# run_still_off.sh -- the user STILL OFF (UOP18, audit item 5).
#
# Play/Pause or Select on a still with no buttons ends it: the reader runs what
# the still's timer would have run at expiry (next cell, cell command, PGC end).
# A hold with no continuation of its own ignores the key. See docs/dvd_nav.md
# "Still off".
#
# GREEN: iso_reader_stilloff_tb (the reader, arms A-J)
#        + the still/menu benches that share S_STILL: iso_reader_timedstill_tb,
#          iso_reader_titlestill_tb, iso_reader_celldur_tb, iso_reader_menu_tb
#        + nav_pci_tb (btns_pend: an HLI with buttons parsed but not promoted)
#        + tools/check_still_off_wiring.py --red (the emu.sv seam: keys, gate,
#          reader port, pause precedence)
#        + tools/check_select_noop.py (Select's only other meaning is Activate)
# RED  : sed-mutated copies of the reader. Each must fail exactly its own arms.
#     R1 no-key       : still_off is never acted on            -> A B C
#     R2 ff-no-pgend  : a last-cell 0xFF still continues to     -> B
#                       "the next cell" instead of the PGC end
#     R3 ff-menus-off : a 0xFF still takes the key with Disc    -> G
#                       Menus off
#     R4 deadend      : the POST fall-through hold takes the key -> F
#     R5 stale-timer  : a jump leaves still_timed set (the       -> E
#                       pre-2026-10-05 behaviour)
#     R6 no-timer     : the timer no longer fires the action    -> D
#     R7 timed-no-key : a timed still never takes the key       -> C
#   nav_pci (nav_pci_tb):
#     N1 no-pend      : btns_pend never asserts                 -> T1a T7a
#   Arm H (a press before the still parks is not remembered) has no mutation:
#   the RTL keeps no latch to break. It is there for the day someone adds one.
#
# Usage: bench/dvd/run_still_off.sh [--red]
set -u
cd "$(dirname "$0")/../.."
RED=0; [ "${1:-}" = "--red" ] && RED=1
RD="dvd/dvd_iso_reader.sv"
OUT=".sim/still_off"; mkdir -p "$OUT"
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
run stilloff   "ISO_READER_STILLOFF_TB: ALL TESTS PASSED"  bench/dvd/iso_reader_stilloff_tb.sv $RD
grep -E 'PASS$' "$OUT/stilloff.log" | sed 's/^/    /'
run timedstill "ISO_READER_TIMEDSTILL_TB: ALL TESTS PASSED" bench/dvd/iso_reader_timedstill_tb.sv $RD
run titlestill "ALL TESTS PASSED"                           bench/dvd/iso_reader_titlestill_tb.sv $RD
run celldur    "ALL TESTS PASSED"                           bench/dvd/iso_reader_celldur_tb.sv $RD
run menu       "ALL TESTS PASSED"                           bench/dvd/iso_reader_menu_tb.sv $RD
# nav_pci's btns_pend (T1a/T1/T7a/T7): "no buttons" must include "none on the way"
run navpci     "NAV_PCI_TB: ALL TESTS PASSED"               bench/dvd/nav_pci_tb.sv dvd/nav_pci.sv
grep -q "SKIPPED" "$OUT/navpci.log" && echo "    (nav_pci_tb fixture absent: its HLI scenarios were SKIPPED)"
# emu.sv has no bench: the key decode and the reader seam are read out of the file
if python3 tools/check_still_off_wiring.py --red > "$OUT/wiring.log" 2>&1; then
    echo "  PASS check_still_off_wiring (+ its red self-test)"
else
    echo "  FAIL check_still_off_wiring"; sed 's/^/      /' "$OUT/wiring.log"; fail=1
fi
if python3 tools/check_select_noop.py > "$OUT/select.log" 2>&1; then
    echo "  PASS check_select_noop: $(cat "$OUT/select.log")"
else
    echo "  FAIL check_select_noop"; sed 's/^/      /' "$OUT/select.log"; fail=1
fi

if [ $RED -eq 1 ]; then
    echo "== RED (each mutation must fail exactly its arms) =="
    # mutate <name> <expected arms> <sed-expr>
    mutate() {
        local name=$1 want=$2 expr=$3
        local src="$OUT/$name.sv"
        sed "$expr" "$RD" > "$src"
        if cmp -s "$RD" "$src"; then
            echo "  FAIL $name: the sed matched nothing (mutation is stale)"; fail=1; return
        fi
        if ! iverilog -g2012 -y dvd -Y .sv -o "$OUT/$name" "$src" \
                bench/dvd/iso_reader_stilloff_tb.sv 2>"$OUT/$name.build"; then
            echo "  FAIL $name (build)"; sed 's/^/      /' "$OUT/$name.build" | head; fail=1; return
        fi
        timeout 900 vvp "$OUT/$name" > "$OUT/$name.log" 2>&1
        # Arm letter = the first letter after "FAIL " (setup steps A0/E0/... count
        # as their arm). Anything else failing reads as X.
        local got
        got=$(grep -E '^FAIL' "$OUT/$name.log" \
              | sed -E 's/^FAIL ([A-J])[0-9]?[ :].*/\1/; t; s/.*/X/' \
              | sort -u | tr '\n' ' ' | sed 's/ $//')
        if [ "$got" = "$want" ]; then
            echo "  ok   $name -> fails [$got]"
        else
            echo "  FAIL $name: failed [$got], expected [$want]"; fail=1
        fi
    }
    mutate R1_no_key       "A B C I J" "s/(still_off \&\& still_act)) begin/1'b0) begin/"
    mutate R2_ff_no_pgend  "B"     "s/^\( *\)STILL_PGEND : STILL_NEXT;/\1STILL_NEXT : STILL_NEXT;/"
    mutate R3_ff_menus_off "G"     "s/^\( *\)still_act   <= vm_mode;\$/\1still_act   <= 1'b1;/"
    mutate R4_deadend      "F"     "s/^\( *\)still_act <= 1'b0;\$/\1still_act <= 1'b1;/"
    mutate R5_stale_timer  "E"     "/^            still_timed  <= 1'b0;\$/d"
    mutate R6_no_timer     "D"     "s/(still_timed \&\& sec_tick \&\& still_secs <= 16'd1) ||/1'b0 ||/"
    mutate R7_timed_no_key "C"     "s/still_act   <= vm_mode;   \/\/ menus-off: no Still off/still_act   <= 1'b0;/"
    # the old command-first order for a 0xFF still with a cell command
    mutate R8_cmd_first    "I J"   "s/^\( *\)end else if (vm_mode \&\& cm_rd\[7:0\] != 8'd0 \&\&\$/\1end else if (1'b0 \&\&/"
    # a malformed cmd_nr is handed to the VM after the hold instead of the next cell
    mutate R9_bad_cmd_runs "J"     "s/still_next  <= (cm_rd\[7:0\] <= cmd_nr_cell) ? STILL_CMD :/still_next  <= (1'b1) ? STILL_CMD :/"
    # the hold forgets its command: Still off plays on instead of running it
    mutate R10_drops_cmd   "I"     "s/still_next  <= (cm_rd\[7:0\] <= cmd_nr_cell) ? STILL_CMD :/still_next  <= (1'b0) ? STILL_CMD :/"

    # N1: nav_pci never reports a pending HLI -> nav_pci_tb's btns_pend checks.
    sed "s/^assign btns_pend  = .*/assign btns_pend  = 1'b0;/" dvd/nav_pci.sv > "$OUT/N1.sv"
    if cmp -s dvd/nav_pci.sv "$OUT/N1.sv"; then
        echo "  FAIL N1_no_pend: the sed matched nothing (mutation is stale)"; fail=1
    elif ! iverilog -g2012 -o "$OUT/N1" "$OUT/N1.sv" bench/dvd/nav_pci_tb.sv 2>"$OUT/N1.build"; then
        echo "  FAIL N1_no_pend (build)"; fail=1
    else
        vvp "$OUT/N1" > "$OUT/N1.log" 2>&1
        got=$(grep -oE "ERR T[0-9]+a? btns_pend" "$OUT/N1.log" | awk '{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')
        if grep -q "SKIPPED" "$OUT/N1.log"; then
            echo "  skip N1_no_pend (nav_pci_tb fixture absent -- proves nothing here)"
        elif [ "$got" = "T1a T7a" ] && ! grep -q "ALL TESTS PASSED" "$OUT/N1.log"; then
            echo "  ok   N1_no_pend -> fails [$got]"
        else
            echo "  FAIL N1_no_pend: failed [$got], expected [T1a T7a]"; fail=1
        fi
    fi
fi

if [ $fail -eq 0 ]; then echo "run_still_off: PASS"; else echo "run_still_off: FAIL"; exit 1; fi
