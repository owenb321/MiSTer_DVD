#!/usr/bin/env bash
# run_auto_ptt.sh — the Auto (Disc Menus Off) chapter-table gate, issue #132.
#
# The defect: the Auto mount loaded title 1's VTS_PTT_SRPT BEFORE the duration
# scan picked the longest PGC, so a feature that is another title's PGC showed
# title 1's chapter count (X-Men: Apocalypse: "CH n/1", no seek-bar notches).
# The reader now reloads the table of the title the winner's entry_id[6:0]
# names, checks the winner is in it, and publishes nr_ptt = 0 when it is not.
# It also stops an Auto cross-PGC chapter jump into PGCN 1 re-running the scan.
#
# GREEN: iso_reader_autoptt_tb (the gate) + iso_reader_pgc_tb (TEST 5 is the
#        issue's disc shape) + iso_reader_ptt_tb (Disc Menus On must not move).
# RED  : sed-mutated copies of dvd_iso_reader.sv. Each must fail exactly the
#        arms listed, and no others:
#          M1 no-reload   : never reload after the scan            -> A B D F
#          M2 no-member   : a miss keeps the table's count         -> B
#          M3 bit7-ttn    : title only from ENTRY PGCs (bit 7)     -> D
#          M4 ptt0-member : membership tested on chapter 1 only    -> C E
#          M5 no-gate     : the scan re-arms on a chapter jump     -> E
#          M6 no-fallthru : the unusable-winner fallthrough takes the
#                           next PGC without reloading its table   -> F
#        M4 also fails E because E mounts C's disc shape: with nr_ptt = 0 at
#        mount there is no chapter 3 to step back from.
#
# Usage: bench/dvd/run_auto_ptt.sh [--red]
set -u
cd "$(dirname "$0")/../.."
RED=0; [ "${1:-}" = "--red" ] && RED=1
RTL="dvd/dvd_iso_reader.sv"
OUT=".sim/auto_ptt"; mkdir -p "$OUT"
fail=0

# run <name> <pass-string> <rtl> <tb>
run() {
    local name=$1 pass=$2 rtl=$3 tb=$4
    if iverilog -g2012 -y dvd -Y .sv -o "$OUT/$name" "$rtl" "$tb" 2>"$OUT/$name.build"; then
        if timeout 900 vvp "$OUT/$name" > "$OUT/$name.log" 2>&1 && grep -q "$pass" "$OUT/$name.log"; then
            echo "  PASS $name"
        else
            echo "  FAIL $name"; tail -20 "$OUT/$name.log"; fail=1
        fi
    else
        echo "  FAIL $name (build)"; sed 's/^/      /' "$OUT/$name.build"; fail=1
    fi
}

echo "== GREEN =="
run autoptt "ISO_READER_AUTOPTT_TB: ALL TESTS PASSED" $RTL bench/dvd/iso_reader_autoptt_tb.sv
grep -E 'PASS$' "$OUT/autoptt.log" | sed 's/^/    /'
run pgc     "ISO_READER_PGC_TB: ALL TESTS PASSED"     $RTL bench/dvd/iso_reader_pgc_tb.sv
run ptt     "ISO_READER_PTT_TB: ALL TESTS PASSED"     $RTL bench/dvd/iso_reader_ptt_tb.sv

if [ $RED -eq 1 ]; then
    echo "== RED (each mutation must fail exactly its arms) =="
    # mutate <name> <expected arms> <sed-expr>
    mutate() {
        local name=$1 want=$2 expr=$3
        local src="$OUT/$name.sv"
        sed "$expr" "$RTL" > "$src"
        if cmp -s "$RTL" "$src"; then
            echo "  FAIL $name: the sed matched nothing (mutation is stale)"; fail=1; return
        fi
        if ! iverilog -g2012 -y dvd -Y .sv -o "$OUT/$name" "$src" \
                bench/dvd/iso_reader_autoptt_tb.sv 2>"$OUT/$name.build"; then
            echo "  FAIL $name (build)"; sed 's/^/      /' "$OUT/$name.build"; fail=1; return
        fi
        timeout 900 vvp "$OUT/$name" > "$OUT/$name.log" 2>&1
        local got
        got=$(grep -oE '^FAIL [A-F]' "$OUT/$name.log" | awk '{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')
        if [ "$got" = "$want" ]; then
            echo "  ok   $name -> fails [$got]"
        else
            echo "  FAIL $name: failed [$got], expected [$want]"; fail=1
        fi
    }
    mutate M1_no_reload   "A B D F" \
        "s/end else if (dur_pick \&\& (want_pgcn != 16'd1 ||/end else if (1'b0 \&\& dur_pick \&\& (want_pgcn != 16'd1 ||/"
    mutate M2_no_member   "B" \
        "s/if (!ptt_hit) nr_ptt <= 11'd0;/if (1'b0) nr_ptt <= 11'd0;/"
    mutate M3_bit7_ttn    "D" \
        "s/reld_ttn   <= (srp_entry_id\[6:0\] != 7'd0) ? srp_entry_id\[6:0\] : 7'd1;/reld_ttn   <= srp_entry_id[7] ? srp_entry_id[6:0] : 7'd1;/"
    mutate M4_ptt0_member "C E" \
        "s/if (ptt_pgcn_c == want_pgcn) ptt_hit <= 1'b1;/if (ptt_pgcn_c == want_pgcn \&\& walk_idx[11:2] == 10'd0) ptt_hit <= 1'b1;/"
    mutate M5_no_gate     "E" \
        "s/!menu_dom \&\& !ptt_res_tt \&\&/!menu_dom \&\&/"
    mutate M6_no_fallthru "F" \
        "s/dur_pick   <= !ptt_res_tt;/dur_pick   <= 1'b0;/"
fi

if [ $fail -eq 0 ]; then echo "RUN_AUTO_PTT: PASS"; else echo "RUN_AUTO_PTT: FAIL"; exit 1; fi
