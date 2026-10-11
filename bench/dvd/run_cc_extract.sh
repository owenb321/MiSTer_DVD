#!/usr/bin/env bash
# run_cc_extract.sh — the VLD's line-21 caption snoop over real disc bytes,
# on BOTH caption framings (issue #166). See docs/closed_captions.md §4.1.
#
# GREEN: cc_extract_tb on each fixture (byte-exact vs the golden + field balance)
#   A  cc    MEN_IN_BLACK       markers alternate fe/ff
#   B  cc_b  CASTLE_IN_THE_SKY  every marker ff; extra_field entries on both
#                               fields, the last carrying caption bytes
# RED  : sed-mutated copies of rtl/mpeg2/vld.v. Each must fail exactly its arms.
#   M1 marker-field : field from the marker bit (the pre-#166 rule)  -> B
#                     (A passing under M1 is the point: framing A cannot see it)
#   M2 no-extra     : read 2*cc_count entries, drop extra_field      -> B
#   M3 no-toggle    : every entry gets odd_field_first's field       -> A B
#   M4 no-odd-first : entry 0 always field 1                          -> A B
#
# Usage: bench/dvd/run_cc_extract.sh [--red]
set -u
cd "$(dirname "$0")/../.."
RED=0; [ "${1:-}" = "--red" ] && RED=1
VLD="rtl/mpeg2/vld.v"
OUT=".sim/cc_extract"; mkdir -p "$OUT"
TB="bench/dvd/cc_extract_tb.sv"
fail=0

for f in cc cc_b; do
    if [ ! -s "bench/dvd/test_vobs/${f}_es.hex" ] || [ ! -s "bench/dvd/test_vobs/${f}_golden.hex" ]; then
        echo "FAIL: fixture bench/dvd/test_vobs/${f}_*.hex missing"; exit 1
    fi
done

# arms <name> <vld source>: prints the arms (A/B) that fail, space-separated
arms() {
    local name=$1 src=$2 got="" arm fx
    if ! iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o "$OUT/$name" \
            "$src" rtl/mpeg2/getbits.v "$TB" 2>"$OUT/$name.build"; then
        echo "BUILD"; return
    fi
    for arm in A B; do
        fx=cc; [ $arm = B ] && fx=cc_b
        if ! timeout 300 vvp "$OUT/$name" +fixture=$fx > "$OUT/$name.$arm.log" 2>&1 \
           || ! grep -q "^PASS: cc_extract_tb \[$fx\]" "$OUT/$name.$arm.log"; then
            got="$got $arm"
        fi
    done
    echo "${got# }"
}

echo "== GREEN =="
got=$(arms green "$VLD")
if [ -z "$got" ]; then
    grep -h "^PASS" "$OUT/green.A.log" "$OUT/green.B.log" | sed 's/^/  /'
else
    echo "  FAIL green: arms [$got]"
    grep -h "FAIL" "$OUT"/green.*.log "$OUT/green.build" 2>/dev/null | head -20 | sed 's/^/    /'
    fail=1
fi

if [ $RED -eq 1 ]; then
    echo "== RED (each mutation must fail exactly its arms) =="
    # mutate <name> <expected arms> <sed-expr>
    mutate() {
        local name=$1 want=$2 expr=$3 src="$OUT/$1.v" got
        sed "$expr" "$VLD" > "$src"
        if cmp -s "$VLD" "$src"; then
            echo "  FAIL $name: the sed matched nothing (mutation is stale)"; fail=1; return
        fi
        got=$(arms "$name" "$src")
        if [ "$got" = "$want" ]; then
            echo "  ok   $name -> fails [$got]"
        else
            echo "  FAIL $name: failed [$got], expected [$want]"; fail=1
        fi
    }
    mutate M1_marker_field "B" \
        "s/^                if (ud_byte\[7:1\] == 7'h7f) begin$/                if (ud_byte[7:1] == 7'h7f) begin ud_fld <= ud_byte[0];/"
    mutate M2_no_extra     "B" \
        "s/^            ud_left <= ud_byte\[5:0\];/            ud_left <= {ud_byte[5:1], 1'b0};/"
    mutate M3_no_toggle    "A B" \
        "s/^                ud_fld        <= ~ud_fld; /                ud_fld        <= ud_fld; /"
    mutate M4_no_odd_first "A B" \
        "s/^            ud_fld  <= ud_byte\[7\]; /            ud_fld  <= 1'b1; /"
fi

if [ $fail -eq 0 ]; then echo "RUN_CC_EXTRACT: ALL PASS"; else echo "RUN_CC_EXTRACT: FAILED"; exit 1; fi
