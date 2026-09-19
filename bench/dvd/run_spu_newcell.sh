#!/usr/bin/env bash
# run_spu_newcell.sh -- spu_decode's menu re-send guard opens across a cell change
# (Harry Potter Interactive's Player Mode highlight, 2026-09-18; docs/subpicture.md
# "The re-send guard is per cell").
#
# GREEN: spu_newcell_tb, plus run_spu_window.sh (the display-order gate this guard
#        sits beside) and run_subpic.sh.
# --red: each mutation must fail EXACTLY its designed arm.
#   M1  the guard ignores new_cell            -> N1 (the new cell's graphic is skipped)
#   M2  the guard never re-closes at COMMIT   -> N3 (an older re-send replaces the overlay)
set -uo pipefail
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0
run_nc () {   # $1 spu_decode.sv -> failing arms
    iverilog -g2012 -I rtl/mpeg2 -o "$TMP/nc" "$1" bench/dvd/spu_newcell_tb.sv 2>/dev/null || { echo COMPILE; return; }
    vvp "$TMP/nc" > "$TMP/nc.out" 2>&1 || true
    grep -oE '^FAIL: \[N[0-9]\]' "$TMP/nc.out" | grep -oE 'N[0-9]' | sort -u | tr '\n' ' ' | sed 's/ $//' || true
}
echo "== spu_newcell_tb =="
got=$(run_nc dvd/spu_decode.sv); grep -E '^\s+\[' "$TMP/nc.out" || true
{ [ -z "$got" ] && grep -q '^RESULT: PASS' "$TMP/nc.out"; } || { echo "  FAIL [$got]"; rc=1; }
for s in run_spu_window run_subpic; do
    echo "== $s =="
    if bash bench/dvd/$s.sh > "$TMP/$s.log" 2>&1; then echo "  ok"; else echo "  FAIL"; tail -5 "$TMP/$s.log"; rc=1; fi
done
if [ "${1:-}" = "--red" ]; then
    echo "== RED =="
    red () { local id=$1 expr=$2 want=$3 got
        sed "$expr" dvd/spu_decode.sv > "$TMP/spu_decode.sv"
        cmp -s "$TMP/spu_decode.sv" dvd/spu_decode.sv && { echo "  FAIL: $id did not apply"; rc=1; return; }
        got=$(run_nc "$TMP/spu_decode.sv")
        echo "   $id: failing [${got:-none}], expected [$want]"
        [ "$got" = "$want" ] || { echo "  FAIL: $id caught by the wrong arms"; rc=1; }; }
    red M1 's/ \&\& !guard_open \&\&/ \&\&/' N1
    red M2 's/^                guard_open <= 1.b0;        \/\/ the new cell.s unit is on screen: guard again$//' N3
fi
[ "$rc" -eq 0 ] && echo "== spu_newcell: OK ==" || echo "== spu_newcell: FAIL =="
exit $rc
