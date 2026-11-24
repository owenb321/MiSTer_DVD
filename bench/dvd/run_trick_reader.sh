#!/usr/bin/env bash
#
# run_trick_reader.sh -- trick play in dvd/dvd_iso_reader.sv, on a real disc image,
# against tools/trick_splice.py walk_cells (docs/trick_play.md "The reader").
#
# bench/dvd/iso_reader_trick_tb.sv serves the reader sectors straight from the .iso,
# seeks into the title, turns trick play on and logs every armed VOBU and every sector
# streamed; bench/dvd/trick_reader_check.py walks the model over the reader's own cell
# table and requires the same VOBUs, the same end sectors and exactly those sectors.
# Every arm also checks: each armed sector is a NAV pack; the reader keeps reading
# when trick play ends without a seek; trick play re-entered partway through a sector
# arms only on a whole NAV pack (session 2).
#
#   [1] f1    forward, 2 s jumps
#   [2] f3    forward, 30 s jumps, long enough to cross into the next cell
#   [3] r1    backward, 2 s jumps
#   [4] r3    backward, 30 s jumps, crossing into earlier cells (their LAST VOBU)
#   [5] edge  backward from the PGC's first cell: stops at its edge (trick_edge)
#   [6] gate  forward with the cadence gate pulsing: one VOBU per pulse
#   --red adds one mutation per rule; each must FAIL its own arm:
#   [R1] the 2 s rung read from the 1.5 s entry           -> f1
#   [R2] no cell crossing (every target taken in-cell)    -> f3
#   [R3] a backward crossing enters at the cell's start   -> r3
#   [R4] the cadence gate ignored                         -> gate
#   [R5] the whole VOBU read (vobu_ea, not 1stref_ea)     -> f1
#   [R6] the whole-sector guard removed                   -> f1 (session 2)
#   [R7] the edge not held                                -> edge
#
# Needs a disc: TRICK_ISO, else the first MEN_IN_BLACK_3*.iso under DVD_ISO_DIR (the
# disc docs/trick_play.md measures). Without one: SKIP, loudly. ~2-4 min per arm in
# Icarus; arms run JOBS (default 6) at a time.
#
#   ./bench/dvd/run_trick_reader.sh [--red]
set -euo pipefail
cd "$(dirname "$0")/../.."

RED=0; [ "${1:-}" = "--red" ] && RED=1
OUT=bench/dvd/test_vobs/trick_reader       # gitignored
mkdir -p "$OUT"

ISO="${TRICK_ISO:-}"
if [ -z "$ISO" ] && [ -n "${DVD_ISO_DIR:-}" ] && [ -d "$DVD_ISO_DIR" ]; then
  ISO=$(find "$DVD_ISO_DIR" -maxdepth 3 -name 'MEN_IN_BLACK_3*.iso' 2>/dev/null | sort | head -1)
fi
if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
  echo "SKIP run_trick_reader: no disc (set DVD_ISO_DIR or TRICK_ISO) -- NOTHING WAS CHECKED"
  exit 0
fi
SZ=$(stat -c %s "$ISO")
MID=$(python3 -c "
import sys; sys.path.insert(0, 'tools')
from trick_scan import title_extents, SEC
f = open(sys.argv[1], 'rb'); e = title_extents(f)
v = max(e, key=lambda k: sum(d for _, d in e[k]))
print(int(sum((d + SEC - 1) // SEC for _, d in e[v]) * 0.3))" "$ISO")
echo "== $(basename "$ISO"): seek to RBN $MID =="

# name tier rev vobus seek extra
ARMS="f1 1 0 8 $MID -
f3 3 0 30 $MID -
r1 1 1 12 $MID -
r3 3 1 30 $MID -
edge 3 1 40 3000 -
gate 1 0 6 $MID +GOPER=400000"

build() {   # build <reader.sv> <tag>
  iverilog -g2012 -I rtl/mpeg2 -y dvd -Y .sv -o "$OUT/$2.vvp" "$1" bench/dvd/iso_reader_trick_tb.sv 2>&1 |
    grep -iv 'warning\|padding' || true
}
arm() {     # arm <tag> <name> <tier> <rev> <vobus> <seek> <extra>; prints "<name> PASS|FAIL <why>"
  local tag=$1 n=$2 x=$7 log=$OUT/$1_$2
  [ "$x" = "-" ] && x=""
  if ! timeout 3000 vvp -n "$OUT/$tag.vvp" +ISO="$ISO" +OUT="$log.log" +SIZE="$SZ" +SEEK="$6" \
       +TIER="$3" +REV="$4" +VOBUS="$5" $x > "$log.out" 2>&1 || ! grep -q '^PASS' "$log.out"; then
    echo "$n FAIL bench: $(grep -m1 -i 'fatal\|error' "$log.out" || echo 'no PASS')"; return
  fi
  if python3 bench/dvd/trick_reader_check.py "$log.log" "$ISO" --tier "$3" --rev "$4" > "$log.chk" 2>&1; then
    echo "$n PASS $(head -1 "$log.out")"
  else
    echo "$n FAIL model: $(grep -m1 '^  ' "$log.chk" || tail -1 "$log.chk")"
  fi
}
export -f arm; export OUT ISO SZ

build dvd/dvd_iso_reader.sv base
rc=0
res=$(echo "$ARMS" | xargs -P "${JOBS:-6}" -L 1 bash -c 'arm base "$0" "$1" "$2" "$3" "$4" "$5"')
echo "$res" | sort
grep -q ' FAIL ' <<<"$res" && rc=1

if [ "$RED" = 1 ]; then
  echo "== RED =="
  # red <id> <target arm> <perl substitution>
  REDS=(
    "R1|f1|s/\(trick_rev \? 11'h555 : 11'h531\)/(trick_rev ? 11'h555 : 11'h535)/"
    "R2|f3|s/wire        tk_in  = \(/wire        tk_in  = 1'b1 || (/"
    "R3|r3|s/: trick_lv     \? lv_rd /: trick_lv     ? cf_rd /"
    "R4|gate|s/\(trick_credit \|\| trick_go\)/(1'b1)/g"
    "R5|f1|s/trick_end   <= snoop_rbn \+ snoop_ref;/trick_end   <= snoop_rbn + snoop_ea;/"
    "R6|f1|s/        tk_sec_ok <= trick_en;/        tk_sec_ok <= 1'b1;/"
    "R7|edge|s/trick_hold  <= !tk_in && tk_edge;/trick_hold  <= 1'b0;/"
  )
  for r in "${REDS[@]}"; do
    IFS='|' read -r id tgt sub <<<"$r"
    perl -0pe "$sub" dvd/dvd_iso_reader.sv > "$OUT/mut_$id.sv"
    if cmp -s "$OUT/mut_$id.sv" dvd/dvd_iso_reader.sv; then
      echo "[$id] FAIL: the mutation did not apply"; rc=1; continue
    fi
    build "$OUT/mut_$id.sv" "$id"
  done
  # run each mutation's target arm (its files are <id>_<arm>.*), then score them
  for r in "${REDS[@]}"; do
          IFS='|' read -r id tgt sub <<<"$r"
          echo "$ARMS" | awk -v t="$tgt" -v id="$id" '$1 == t { print id, $0 }'
  done | xargs -P "${JOBS:-6}" -L 1 bash -c 'arm "$0" "$1" "$2" "$3" "$4" "$5" "$6"' >/dev/null
  # one verdict per mutation, read back from its own arm's files
  for r in "${REDS[@]}"; do
    IFS='|' read -r id tgt sub <<<"$r"
    if grep -q '^PASS' "$OUT/${id}_$tgt.out" 2>/dev/null &&
       python3 bench/dvd/trick_reader_check.py "$OUT/${id}_$tgt.log" "$ISO" \
         --tier "$(echo "$ARMS" | awk -v t="$tgt" '$1==t{print $2}')" \
         --rev  "$(echo "$ARMS" | awk -v t="$tgt" '$1==t{print $3}')" >/dev/null 2>&1; then
      echo "[$id] FAIL: $tgt survived the mutation"; rc=1
    else
      echo "[$id] PASS ($tgt fails)"
    fi
  done
fi

[ $rc = 0 ] && echo "run_trick_reader: PASS" || echo "run_trick_reader: FAIL"
exit $rc
