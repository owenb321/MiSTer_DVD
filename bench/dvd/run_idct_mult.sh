#!/usr/bin/env bash
# run_idct_mult.sh -- gate for logic reclaim F: idct1d_col's six mult22x16 as one 27x27 DSP
# product each (docs/logic_reclaim.md §11).
#
# WHAT IS PROVEN
#   [data]  the new mult22x16 equals upstream's split multiplier (bench/dvd/ref/
#           mult22x16_ref.v) on every cycle: full-range operands, corners, random clk_en.
#   [reset] the same with reset pulses of 1..5 cycles; the 1-cycle case is the one the
#           p_clr flag exists for (the DSP register carries no reset).
#   [idct]  the whole idct is bit-identical to a copy wired to the upstream multiplier.
#   Mutations: each must fail exactly the arms it names.
#     M1 p_clr removed (product <= p): a 1-cycle reset leaks a pre-reset product -> reset
#     M2 the multiplier read unsigned -> data reset idct
#     M3 one stage more latency -> data reset idct
#     M4 a column product fed the wrong cosine (idct.v, not the multiplier): proves [idct] can fail
#        on its own -> idct
#
# Usage: bench/dvd/run_idct_mult.sh [--red]     (exit 0 = ALL GREEN)
set -uo pipefail
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
RED=0; [ "${1:-}" = "--red" ] && RED=1
rc=0
ARMS=(data reset idct)

# idct_old: rtl/mpeg2/idct.v with every module renamed *_old and the column multipliers
# pointed at the upstream oracle. Built from the UNMUTATED file, so it is the fixed side.
python3 - rtl/mpeg2/idct.v "$TMP/idct_old.v" <<'EOF'
import re, sys
s = open(sys.argv[1]).read()
names = ['idct_fifo', 'idct1d_row', 'idct1d_col', 'transpose', 'clip_col', 'mult22x16', 'idct']
for n in names:
    s = re.sub(r'(^\s*module\s+)%s\b' % n, r'\g<1>%s_old' % n, s, flags=re.M)
for n in ['idct1d_row', 'idct1d_col', 'transpose', 'clip_col']:
    s = re.sub(r'(^\s*)%s(\s)' % n, r'\g<1>%s_old\2' % n, s, flags=re.M)
n = len(re.findall(r'^\s*mult22x16\s+mult_prod', s, flags=re.M))
assert n == 6, n
s = re.sub(r'^(\s*)mult22x16(\s+mult_prod)', r'\1mult22x16_ref\2', s, flags=re.M)
open(sys.argv[2], 'w').write(s)
EOF

build() {   # <out> <idct.v to use>
    iverilog -g2012 -I rtl/mpeg2 -o "$1" "$2" "$TMP/idct_old.v" bench/dvd/ref/mult22x16_ref.v rtl/mpeg2/wrappers.v rtl/mpeg2/xfifo_sc.v rtl/mpeg2/fwft.v rtl/mpeg2/xilinx_fifo_dc.v \
        bench/dvd/idct_mult_tb.sv 2>"$1.log" || { cat "$1.log"; return 1; }
}

run_arms() {   # <sim> -> space-separated list of FAILED arms
    local sim=$1 failed=() a
    for a in "${ARMS[@]}"; do
        if ! timeout 600 vvp -n "$sim" +arm="$a" 2>&1 | grep -q "^IDCT_MULT PASS $a\$"; then
            failed+=("$a")
        fi
    done
    echo "${failed[*]}"
}

build "$TMP/base" rtl/mpeg2/idct.v || exit 1
for a in "${ARMS[@]}"; do
    out=$(timeout 600 vvp -n "$TMP/base" +arm="$a" 2>&1)
    if echo "$out" | grep -q "^IDCT_MULT PASS $a\$"; then
        echo "[$a] PASS  $(echo "$out" | grep -E '^(idct|reset) arm:' || true)"
    else
        echo "[$a] FAIL"; echo "$out" | tail -8; rc=1
    fi
done

if [ $RED = 1 ]; then
    mut() {   # <name> <expected failed arms> <old> <new> [<old> <new> ...]
        local name=$1 want=$2 got; shift 2
        python3 - rtl/mpeg2/idct.v "$TMP/$name.v" "$@" <<'EOF' || { echo "  $name: anchor not found"; rc=1; return; }
import sys
src, dst, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
s = open(src).read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    if s.count(old) != 1: sys.exit(1)
    s = s.replace(old, new)
open(dst, 'w').write(s)
EOF
        build "$TMP/$name" "$TMP/$name.v" || { rc=1; return; }
        got=$(run_arms "$TMP/$name")
        if [ "$got" = "$want" ]; then echo "  $name: fails [$got] as expected"
        else echo "  $name: WRONG -- failed [$got], expected [$want]"; rc=1; fi
    }
    echo "mutations:"
    mut M1 "reset" "product <= p_clr ? 38'sb0 : p;" "product <= p;"
    mut M2 "data reset idct" "if (clk_en) p <= multiplier * multiplicand;" \
        "if (clk_en) p <= \$unsigned(multiplier) * multiplicand;"
    mut M3 "data reset idct" "else if (clk_en) product <= p_clr ? 38'sb0 : p;" \
        "else if (clk_en) product <= p_clr ? 38'sb0 : p_q;" \
        "reg               p_clr;" "reg p_clr; reg signed [37:0] p_q; always @(posedge clk) if (clk_en) p_q <= p;"
    mut M4 "idct" "mult22x16 mult_prod7(clk, clk_en, rst, prod7, cos7, x7);" \
        "mult22x16 mult_prod7(clk, clk_en, rst, prod7, cos5, x7);"
fi

[ $rc = 0 ] && echo "run_idct_mult: ALL GREEN" || echo "run_idct_mult: FAILURES"
exit $rc
