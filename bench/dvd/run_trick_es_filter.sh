#!/usr/bin/env bash
#
# run_trick_es_filter.sh -- dvd/trick_es_filter.sv, byte-exact against the model
# (tools/trick_splice.py es_filter) on real discs and on synthetic streams
# (docs/trick_play.md "The ES filter in RTL").
#
#   [1] every case: the output equals the expected bytes (random input gaps and output
#       backpressure, a different seed per case), and the synthetic cases' skip_n /
#       pair_n counters match
#   [2] en = 0: the filter is a wire (output == input)
#   --red adds one mutation per rule, each of which must FAIL its own case:
#   [R1] the cut decides the picture code's last byte instead of holding it -> syn_dangling
#   [R2] picture_structure ignored (every picture a frame)                 -> syn_field_pair
#   [R3] picture_coding_type ignored (any first picture passes)           -> syn_first_not_i
#   [R4] the first picture code cuts (no picture passes)                   -> syn_mpeg1
#   [R5] en = 0 still routes through the held bytes                         -> [2]
#
# Real-disc cases need DVD_ISO_DIR (8 discs drawn with a fixed seed, every tier, both
# directions). Without it the synthetic cases still run, and the summary says so.
#
#   ./bench/dvd/run_trick_es_filter.sh [--red]
set -euo pipefail
cd "$(dirname "$0")/../.."

RED=0; [ "${1:-}" = "--red" ] && RED=1
OUT=bench/dvd/test_vobs/trick_es_filter   # gitignored
mkdir -p "$OUT"
python3 bench/dvd/trick_es_fixtures.py "$OUT" --discs "${DISCS:-8}"

# one_case <vvp> <tag> <name> <skip_n> <pair_n> <seed>: prints a line only on failure
one_case() {
  local vvp=$1 tag=$2 name=$3 sk=$4 pr=$5 seed=$6 log gsk gpr
  log=$(vvp -n "$vvp" +IN="$OUT/$name.in" +OUT="$OUT/$name.$tag.out" +SEED="$seed" 2>&1)
  if ! grep -q '^PASS' <<<"$log"; then echo "    $name: bench did not finish"; return; fi
  if ! cmp -s "$OUT/$name.$tag.out" "$OUT/$name.exp"; then
    echo "    $name: output differs ($(cmp "$OUT/$name.$tag.out" "$OUT/$name.exp" 2>&1 | head -1))"
    return
  fi
  if [ "$sk" != "-" ]; then
    read -r _ gsk _ gpr _ <<<"$(grep '^skip_n' <<<"$log")"
    if [ "$gsk" != "$sk" ] || [ "$gpr" != "$pr" ]; then
      echo "    $name: counters skip_n $gsk pair_n $gpr, expected $sk $pr"
    fi
  fi
}
export -f one_case; export OUT

# run_cases <rtl.sv> <tag> [name-prefix]: prints one line per failing case, returns 1 if any.
# Cases run JOBS at a time (default 6): Icarus moves ~18 KB/s through this bench, and the
# real-disc cases are tens of MB in all.
run_cases() {
  local rtl=$1 tag=$2 only=${3:-} res
  iverilog -g2012 -o "$OUT/$tag.vvp" "$rtl" bench/dvd/trick_es_filter_tb.sv
  res=$(awk -v only="$only" '{ if (only == "" || index($1, only) == 1) print $1, $2, $3, NR + 1 }' \
          "$OUT/cases.txt" |
        xargs -P "${JOBS:-6}" -L 1 bash -c 'one_case "$0" "$1" "$2" "$3" "$4" "$5"' "$OUT/$tag.vvp" "$tag" |
        sort)
  [ -z "$res" ] && return 0
  echo "$res"
  return 1
}

# wire_arm <rtl.sv> <tag>: en = 0 must pass the input through unchanged
wire_arm() {
  local rtl=$1 tag=$2 c
  iverilog -g2012 -o "$OUT/$tag.vvp" "$rtl" bench/dvd/trick_es_filter_tb.sv
  c=$(head -1 "$OUT/cases.txt" | cut -d' ' -f1)
  vvp -n "$OUT/$tag.vvp" +IN="$OUT/$c.in" +OUT="$OUT/$c.$tag.wire" +EN=0 +SEED=7 >/dev/null
  cmp -s "$OUT/$c.$tag.wire" "$OUT/$c.in"
}

rc=0
n=$(wc -l < "$OUT/cases.txt")
echo "== [1] $n cases =="
if out=$(run_cases dvd/trick_es_filter.sv base); then
  echo "[1] PASS ($n cases)"
else
  echo "$out"; echo "[1] FAIL"; rc=1
fi
echo "== [2] en = 0 is a wire =="
if wire_arm dvd/trick_es_filter.sv base; then echo "[2] PASS"; else echo "[2] FAIL"; rc=1; fi

if [ "$RED" = 1 ]; then
  # red <arm> <must-fail-case> <perl substitution>
  red() {
    local arm=$1 want=$2 sub=$3 m="$OUT/mut_$1.sv" out
    perl -0pe "$sub" dvd/trick_es_filter.sv > "$m"
    if cmp -s "$m" dvd/trick_es_filter.sv; then echo "[$arm] FAIL: the mutation did not apply"; rc=1; return; fi
    if [ "$want" = wire ]; then
      if wire_arm "$m" "$arm"; then echo "[$arm] FAIL: survived"; rc=1; else echo "[$arm] PASS (wire arm fails)"; fi
      return
    fi
    out=$(run_cases "$m" "$arm" syn_ || true)
    if grep -q "^    $want:" <<<"$out"; then
      echo "[$arm] PASS ($want fails; $(grep -c '^    ' <<<"$out") cases fail in all)"
    else
      echo "[$arm] FAIL: $want survived"; rc=1
    fi
  }
  echo "== RED =="
  red R1 syn_dangling   's/nd = 3.d3; nst = S_HUNT;/nd = 3'"'"'d4; nst = S_HUNT; ak[3] = 1'"'"'b0;/'
  red R2 syn_field_pair 's/fld <= \(in_byte\[1:0\] != 2.b11\);/fld <= 1'"'"'b0;/'
  red R3 syn_first_not_i 's/if \(a\[45:43\] == 3.b001\)/if (1'"'"'b1)/'
  red R4 syn_mpeg1      's/if \(st == S_PASS && npic == 2.d0\)/if (st == S_PASS \&\& npic == 2'"'"'d3)/'
  red R5 wire           's/assign out_byte  = en \? hb\[7:0\] : in_byte;/assign out_byte  = hb[7:0];/'
fi

[ -n "${DVD_ISO_DIR:-}" ] || echo "NOTE: synthetic cases only (no DVD_ISO_DIR): the real-disc check did not run"
[ $rc = 0 ] && echo "run_trick_es_filter: PASS" || echo "run_trick_es_filter: FAIL"
exit $rc
