#!/usr/bin/env bash
# run_sub_anchor.sh -- where a 1:1 dialogue subtitle sits under Standard Convert
# (dvd/sub_anchor.sv, docs/standard_convert.md). GREEN: bench/dvd/sub_anchor_tb.sv.
# RED (--red): each mutation must fail exactly its own arm.
set -u
cd "$(dirname "$0")/../.."
fail=0
run() {  # name dut want arm...
    local name=$1 dut=$2 want=$3; shift 3
    local d; d=$(mktemp -d)
    iverilog -g2012 -o "$d/sim" "$dut" bench/dvd/sub_anchor_tb.sv > "$d/build" 2>&1 \
        || { echo "  FAIL $name: did not build"; tail -5 "$d/build"; fail=1; rm -rf "$d"; return; }
    vvp "$d/sim" > "$d/log" 2>&1
    if [ "$want" = pass ]; then
        if grep -q '^PASS' "$d/log" && ! grep -q '^FAIL' "$d/log"; then echo "  PASS $name"
        else echo "  FAIL $name"; tail -8 "$d/log" | sed 's/^/      /'; fail=1; fi
    else
        local seen ok=1 a
        grep -q '^PASS' "$d/log" && ok=0
        seen=$(grep -oE '^FAIL \[[a-z]+\]' "$d/log" | sed -E 's/^FAIL \[(.*)\]/\1/' | sort -u)
        for a in "$@"; do echo "$seen" | grep -qx "$a" || ok=0; done
        for a in $seen; do case " $* " in *" $a "*) ;; *) ok=0 ;; esac; done
        if [ $ok = 1 ]; then echo "  PASS $name (failed as it must: $(echo $seen))"
        else echo "  FAIL $name: wanted only [$*], saw [$(echo $seen)]"; fail=1; fi
    fi
    rm -rf "$d"
}
mutant() {  # name old new arm...
    local name=$1 old=$2 new=$3; shift 3
    local d; d=$(mktemp -d)
    if python3 - "$d/sub_anchor.sv" "$old" "$new" <<'PYEOF'
import sys
s = open('dvd/sub_anchor.sv').read()
if s.count(sys.argv[2]) != 1:
    sys.exit("RED anchor moved: " + sys.argv[2])
open(sys.argv[1], 'w').write(s.replace(sys.argv[2], sys.argv[3]))
PYEOF
    then run "$name" "$d/sub_anchor.sv" fail "$@"; else echo "  FAIL $name: mutation did not apply"; fail=1; fi
    rm -rf "$d"
}
echo "== GREEN"
run "sub_anchor_tb" dvd/sub_anchor.sv pass
if [ "${1:-}" = "--red" ]; then
    echo "== RED"
    mutant "R1 no bottom clamp"      "wire signed [13:0] raw = (nat > bot) ? nat : bot;" "wire signed [13:0] raw = nat;" screen
    mutant "R2 floor, not ceil, even" "(raw + 14'sd1) & ~14'sd1;" "raw & ~14'sd1;" screen place
    mutant "R3 odd offsets allowed"  "else                                     off <= evn[11:0];" "else                                     off <= raw[11:0];" even
    mutant "R4 5/8 bar forgotten"    "wire [11:0] top8    = 12'd60 + p8[14:3];" "wire [11:0] top8    = p8[14:3];" place
    mutant "R5 offset left on at 0"  "else if (ratio != 2'd1 && ratio != 2'd2) off <= 12'sd0;" "else if (1'b0) off <= 12'sd0;" none
fi
if [ $fail = 0 ]; then echo "PASS run_sub_anchor"; else echo "FAIL run_sub_anchor"; exit 1; fi
