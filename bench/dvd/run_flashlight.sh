#!/usr/bin/env bash
#
# run_flashlight.sh -- subpicture composition: a live HLI coli replaces every
# class (contrast 0 = transparent), an all-zero coli is a hotspot, and class 0
# has no transparent key (Scooby-Doo 2 museum "flashlight", 2026-09-18;
# dvd/hl_compose.sv, dvd/subpic_blend.sv, docs/subpicture.md).
#
# GREEN: flashlight_tb (the real hl_compose -> palette -> subpic_blend chain over
#        the disc's measured values), subpic_blend_tb, the screensaver wiring
#        checker, and the subpicture / screensaver / HUD-geometry suites.
# --red: each mutation must fail EXACTLY its designed arm.
#   M1  hl_compose: a contrast-0 class keeps its SPU pixel (the old rule) -> S3
#   M2  hl_compose: an all-zero coli recolours too (no hotspot exception)  -> T1
#   M3  subpic_blend: the idx-0 transparent key is back                    -> S1
set -uo pipefail
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0

run_fl () {   # $1 hl_compose.sv  $2 subpic_blend.sv -> prints failing arms
    if ! iverilog -g2012 -o "$TMP/fl" "$1" "$2" bench/dvd/flashlight_tb.sv 2>"$TMP/cc"; then
        echo COMPILE; return; fi
    vvp "$TMP/fl" > "$TMP/fl.out" 2>&1 || true
    grep -oE '^FAIL: \[[A-Z][0-9]\]' "$TMP/fl.out" | grep -oE '\[[A-Z][0-9]\]' \
        | tr -d '[]' | sort -u | tr '\n' ' ' | sed 's/ $//' || true
}

echo "== flashlight: GREEN =="
got=$(run_fl dvd/hl_compose.sv dvd/subpic_blend.sv)
grep -E '^\s+\[' "$TMP/fl.out" || true
if [ -n "$got" ] || ! grep -q '^RESULT: PASS' "$TMP/fl.out"; then
    echo "  FAIL: flashlight_tb [$got]"; rc=1; fi

echo "== subpic_blend_tb =="
if iverilog -g2012 -o "$TMP/sb" dvd/subpic_blend.sv bench/dvd/subpic_blend_tb.sv 2>/dev/null \
   && vvp "$TMP/sb" | grep -q '^RESULT: PASS'; then echo "  ok"; else echo "  FAIL"; rc=1; fi

echo "== check_saver_overlay_wiring =="
if python3 tools/check_saver_overlay_wiring.py >/dev/null 2>&1; then echo "  ok"
else python3 tools/check_saver_overlay_wiring.py | tail -3; rc=1; fi

for s in run_subpic run_screensaver run_ov_geom; do
    echo "== $s =="
    if bash bench/dvd/$s.sh > "$TMP/$s.log" 2>&1; then echo "  ok"
    else echo "  FAIL"; tail -5 "$TMP/$s.log"; rc=1; fi
done

if [ "${1:-}" = "--red" ]; then
    echo "== RED: each mutation must fail exactly its own arm =="
    red () {   # id label file sed proof want
        local id=$1 label=$2 file=$3 expr=$4 proof=$5 want=$6 hc=dvd/hl_compose.sv sb=dvd/subpic_blend.sv got
        sed "$expr" "$file" > "$TMP/$(basename "$file")"
        grep -qF "$proof" "$TMP/$(basename "$file")" || { echo "  FAIL: $id did not apply"; rc=1; return; }
        [ "$file" = dvd/hl_compose.sv ]  && hc="$TMP/hl_compose.sv"
        [ "$file" = dvd/subpic_blend.sv ] && sb="$TMP/subpic_blend.sv"
        got=$(run_fl "$hc" "$sb")
        echo "   $id $label: failing [${got:-none}], expected [$want]"
        [ "$got" = "$want" ] || { echo "  FAIL: $id caught by the wrong arms"; rc=1; }
    }
    red M1 "contrast-0 class keeps its SPU pixel" dvd/hl_compose.sv \
        's/assign recolour = hl_hit \&\& coli_live;/assign recolour = hl_hit \&\& (hl_alpha != 4'"'"'d0);/' \
        "assign recolour = hl_hit && (hl_alpha != 4'd0);" "S3"
    red M2 "no hotspot exception" dvd/hl_compose.sv \
        "s/wire coli_live = |coli\[15:0\];/wire coli_live = 1'b1;/" \
        "wire coli_live = 1'b1;" "T1"
    red M3 "idx-0 key restored" dvd/subpic_blend.sv \
        "s/wire blend = ov_on \&\& (ov_alpha != 4'd0);/wire blend = ov_on \&\& (ov_alpha != 4'd0) \&\& (ov_force || (ov_idx != 2'd0));/" \
        "(ov_force || (ov_idx != 2'd0));" "S1"
fi

[ "$rc" -eq 0 ] && echo "== flashlight: OK ==" || echo "== flashlight: FAIL =="
exit $rc
