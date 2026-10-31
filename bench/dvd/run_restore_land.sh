#!/usr/bin/env bash
# run_restore_land.sh -- a save-state restore's title jump lands where the state was
# (2026-10-31, Mad Dog's hideout shootout restarted from its first frame on every load).
#
# bench/dvd/iso_reader_restore_tb.sv drives the reader with the restore's jump shape (TTN
# hint + exact PGCN + saved cell) on a title with a real VTS_PTT_SRPT and a two-cell PGC 2:
#   A  PGC 2 cell 1 -> 0xB3, PGC 2      B  PGC 2 cell 0 -> 0xB2, PGC 2
#   C  PGC 1 cell 0 -> 0xB0, PGC 1 (the control)
#   D  an unhinted chapter jump (ttn 1 ptt 3) -> PGC 2: the real PTT resolve still works
# The bug: the hint's PTT resolve (S_PTT_PGC) read title 1's FIRST part and overwrote the
# jump's PGCN and start program, so A and B landed in PGC 1.
#
# --red mutates dvd/dvd_iso_reader.sv; each must fail exactly its own arms:
#   M1  the resolve ignores the hint again                         -> A B
#   M2  the hint skips the chapter resolve for EVERY jump          -> D
#   M3  the hint keeps the PGCN but still sets the start program   -> A (cell overridden)
#
# Usage: bench/dvd/run_restore_land.sh [--red]     (exit 0 = ALL GREEN)
set -uo pipefail
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
RED=0; [ "${1:-}" = "--red" ] && RED=1
rc=0
TB=bench/dvd/iso_reader_restore_tb.sv
RD=dvd/dvd_iso_reader.sv

run() {   # <reader.sv> -> the arms that FAILed, or PASS
    iverilog -g2012 -I rtl/mpeg2 -y dvd -Y .sv -o "$TMP/sim" "$1" $TB 2>"$TMP/log" \
        || { grep -v 'sorry\|warning\|Padding' "$TMP/log" | head -3; echo "BUILD-FAILED"; return; }
    out=$(timeout 900 vvp -n "$TMP/sim" 2>&1)
    if echo "$out" | grep -q "ISO_READER_RESTORE_TB: ALL TESTS PASSED"; then echo PASS; return; fi
    echo "$out" | grep -oE '^FAIL [A-D]' | awk '{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

got=$(run $RD)
if [ "$got" = PASS ]; then echo "  PASS iso_reader_restore_tb (A B C D)"
else echo "  FAIL iso_reader_restore_tb: [$got]"; rc=1; fi

if [ $RED = 1 ]; then
    echo "== RED (each mutation must fail exactly its own arms)"
    mut() {   # <name> <expected arms> <python re.sub args: old, new>
        local name=$1 want=$2
        python3 - "$3" "$4" "$RD" "$TMP/$name.sv" <<'PYEOF' || { echo "  FAIL $name: anchor not found"; rc=1; return; }
import sys
old, new, src, dst = sys.argv[1:]
s = open(src).read()
if s.count(old) != 1: sys.exit(1)
open(dst, 'w').write(s.replace(old, new))
PYEOF
        local g; g=$(run "$TMP/$name.sv")
        if [ "$g" = "$want" ]; then echo "  ok   $name -> fails [$g]"
        else echo "  FAIL $name: failed [$g], expected [$want]"; rc=1; fi
    }
    mut M1 "A B" "                if (jhint_l) begin
                    // keep want_pgcn (the jump's PGCN) and jpgn_l (0: start at jcell_l)
                end else if (nr_pgci_srp == 16'd0) begin" \
                 "                if (1'b0) begin
                    // keep want_pgcn (the jump's PGCN) and jpgn_l (0: start at jcell_l)
                end else if (nr_pgci_srp == 16'd0) begin"
    mut M2 "D" "                if (jhint_l) begin
                    // keep want_pgcn" "                if (1'b1) begin
                    // keep want_pgcn"
    mut M3 "A" "                if (jhint_l) begin
                    // keep want_pgcn (the jump's PGCN) and jpgn_l (0: start at jcell_l)
                end else if (nr_pgci_srp == 16'd0) begin" \
                 "                if (jhint_l) begin
                    jpgn_l <= ptt_pgn[7:0];
                end else if (nr_pgci_srp == 16'd0) begin"
fi
[ $rc = 0 ] && echo "run_restore_land: ALL GREEN" || echo "run_restore_land: FAILURES"
exit $rc
