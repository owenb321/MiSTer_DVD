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
#   [1] f1    forward, 10 s jumps
#   [2] f3    forward, 120 s jumps, long enough to cross into the next cell
#   [3] r1    backward, 10 s jumps
#   [4] r3    backward, 120 s jumps, crossing into earlier cells (their LAST VOBU)
#   [5] edge  backward from the PGC's first cell: stops at its edge (trick_edge)
#   [6] gate  forward with the cadence gate pulsing: one VOBU per pulse
#   On Castle in the Sky (angle blocks; cells 33-34 are its last 2-angle block):
#   [7] ab1   backward at 10 s from cell 35 into the block with angle 1: enters on angle
#             1's LAST VOBU (not the block's last sibling), walks it, skips angle 2
#   [8] ab2   the same with angle 2: never crosses into angle 1
#   [9] af2   forward at 10 s from cell 3 through the first long block (cells 4-5, 99 s)
#             on angle 2 and out into cell 6 (the control: a forward entry has always
#             resolved). Not the last block: an arm ending near the PGC's end leaves the
#             bench's second session nothing to read
#   --red adds one mutation per rule; each must FAIL its own arm:
#   [R1] the 10 s rung read from the 7.5 s entry          -> f1
#   [R2] no cell crossing (every target taken in-cell)    -> f3
#   [R3] a backward crossing enters at the cell's start   -> r3
#   [R4] the cadence gate ignored                         -> gate
#   [R5] the whole VOBU read (vobu_ea, not 1stref_ea)     -> f1
#   [R6] the whole-sector guard removed                   -> f1 (session 2)
#   [R7] the edge not held                                -> edge
#   [R8] END_OF_CELL on the top rung steps down (the crawl) -> f3
#   [R9] the PGC's edge holds short of its boundary VOBU   -> edge
#   [R10] no walk back to the block's first cell            -> ab1
#
# Needs a disc: TRICK_ISO, else the first MEN_IN_BLACK_3*.iso under DVD_ISO_DIR (the
# disc docs/trick_play.md measures). Without one: SKIP, loudly. The angle arms need
# TRICK_ANGLE_ISO, else CASTLE_IN_THE_SKY*.iso there; without it they SKIP, loudly, and
# the verdict line says so. ~2-4 min per arm in Icarus; arms run JOBS (default 6) at a time.
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
ISO_C="${TRICK_ANGLE_ISO:-}"
if [ -z "$ISO_C" ] && [ -n "${DVD_ISO_DIR:-}" ] && [ -d "$DVD_ISO_DIR" ]; then
  ISO_C=$(find "$DVD_ISO_DIR" -maxdepth 3 -name 'CASTLE_IN_THE_SKY*.iso' 2>/dev/null | sort | head -1)
fi
SZ=$(stat -c %s "$ISO")
MID=$(python3 -c "
import sys; sys.path.insert(0, 'tools')
from trick_scan import title_extents, SEC
f = open(sys.argv[1], 'rb'); e = title_extents(f)
v = max(e, key=lambda k: sum(d for _, d in e[k]))
print(int(sum((d + SEC - 1) // SEC for _, d in e[v]) * 0.3))" "$ISO")
echo "== $(basename "$ISO"): seek to RBN $MID =="

# name disc tier rev vobus seek extra   (disc: M = MIB3, C = Castle; +ANGLE=n picks the angle)
ARMS="f1 M 1 0 8 $MID -
f3 M 3 0 30 $MID -
r1 M 1 1 12 $MID -
r3 M 3 1 30 $MID -
edge M 3 1 40 3000 -
gate M 1 0 6 $MID +GOPER=400000"
if [ -n "$ISO_C" ] && [ -f "$ISO_C" ]; then
  ARMS="$ARMS
ab1 C 1 1 30 3115964 +ANGLE=1
ab2 C 1 1 30 3115964 +ANGLE=2
af2 C 1 0 16 90000 +ANGLE=2"
else
  echo "SKIP the angle arms ab1/ab2/af2: no Castle in the Sky (set TRICK_ANGLE_ISO) -- NOT CHECKED"
  ANGLE_SKIP=1
fi

build() {   # build <reader.sv> <tag>
  iverilog -g2012 -I rtl/mpeg2 -y dvd -Y .sv -o "$OUT/$2.vvp" "$1" bench/dvd/iso_reader_trick_tb.sv 2>&1 |
    grep -iv 'warning\|padding' || true
}
arm() {     # arm <tag> <name> <disc> <tier> <rev> <vobus> <seek> <extra>; prints "<name> PASS|FAIL <why>"
  local tag=$1 n=$2 x=$8 log=$OUT/$1_$2 iso=$ISO ang=0
  [ "$3" = "C" ] && iso=$ISO_C
  [ "$x" = "-" ] && x=""
  case "$x" in *+ANGLE=*) ang=${x##*+ANGLE=}; ang=${ang%% *};; esac
  if ! timeout 3000 vvp -n "$OUT/$tag.vvp" +ISO="$iso" +OUT="$log.log" +SIZE="$(stat -c %s "$iso")" +SEEK="$7" \
       +TIER="$4" +REV="$5" +VOBUS="$6" $x > "$log.out" 2>&1 || ! grep -q '^PASS' "$log.out"; then
    echo "$n FAIL bench: $(grep -m1 -i 'fatal\|error' "$log.out" || echo 'no PASS')"; return
  fi
  if python3 bench/dvd/trick_reader_check.py "$log.log" "$iso" --tier "$4" --rev "$5" --angle "$ang" > "$log.chk" 2>&1; then
    echo "$n PASS $(head -1 "$log.out")"
  else
    echo "$n FAIL model: $(grep -m1 '^  ' "$log.chk" || tail -1 "$log.chk")"
  fi
}
export -f arm; export OUT ISO ISO_C SZ

build dvd/dvd_iso_reader.sv base
rc=0
res=$(echo "$ARMS" | xargs -P "${JOBS:-6}" -L 1 bash -c 'arm base "$0" "$1" "$2" "$3" "$4" "$5" "$6"')
echo "$res" | sort
grep -q ' FAIL ' <<<"$res" && rc=1

if [ "$RED" = 1 ]; then
  echo "== RED =="
  # red <id> <target arm> <perl substitution>
  REDS=(
    "R1|f1|s/\(trick_rev \? 11'h585 : 11'h501\)/(trick_rev ? 11'h585 : 11'h505)/"
    "R2|f3|s/wire        tk_ok  = \(/wire        tk_ok  = 1'b1 || (/"
    "R3|r3|s/: trick_lv     \? lv_rd /: trick_lv     ? cf_rd /"
    "R4|gate|s/\(trick_credit \|\| trick_go\)/(1'b1)/g"
    "R5|f1|s/trick_end   <= snoop_rbn \+ snoop_ref;/trick_end   <= snoop_rbn + snoop_ea;/"
    "R6|f1|s/        tk_sec_ok <= trick_en;/        tk_sec_ok <= 1'b1;/"
    "R7|edge|s/trick_hold  <= !tk_in && tk_edge;/trick_hold  <= 1'b0;/"
    "R8|f3|s/wire        tk_c3  = \(trick_tier != 2'd3\) \|\| tk_z3;/wire        tk_c3  = (trick_tier != 2'd3) || tk_z3 || tk_e3;/"
    "R9|edge|s/wire        tk_land = !tk_ok && tk_edge && \(snoop_rbn != tk_bnd\);/wire        tk_land = 1'b0;/"
  )
  [ -z "${ANGLE_SKIP:-}" ] && REDS+=(
    "R10|ab1|s/end else if \(trick_lv && cc_is_angle && !cc_blk_first && !angle_resolved/end else if (1'b0 \&\& trick_lv \&\& cc_is_angle \&\& !cc_blk_first \&\& !angle_resolved/"
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
  done | xargs -P "${JOBS:-6}" -L 1 bash -c 'arm "$0" "$1" "$2" "$3" "$4" "$5" "$6" "$7"' >/dev/null
  # one verdict per mutation, read back from its own arm's files
  for r in "${REDS[@]}"; do
    IFS='|' read -r id tgt sub <<<"$r"
    read -r _ disc tier rev _ _ x <<<"$(echo "$ARMS" | awk -v t="$tgt" '$1==t')"
    iso=$ISO; [ "$disc" = "C" ] && iso=$ISO_C
    ang=0; case "$x" in *+ANGLE=*) ang=${x##*+ANGLE=}; ang=${ang%% *};; esac
    if grep -q '^PASS' "$OUT/${id}_$tgt.out" 2>/dev/null &&
       python3 bench/dvd/trick_reader_check.py "$OUT/${id}_$tgt.log" "$iso" \
         --tier "$tier" --rev "$rev" --angle "$ang" >/dev/null 2>&1; then
      echo "[$id] FAIL: $tgt survived the mutation"; rc=1
    else
      echo "[$id] PASS ($tgt fails)"
    fi
  done
fi

if [ $rc != 0 ]; then echo "run_trick_reader: FAIL"
elif [ -n "${ANGLE_SKIP:-}" ]; then echo "run_trick_reader: PASS -- WITHOUT the angle arms (no Castle in the Sky)"
else echo "run_trick_reader: PASS"; fi
exit $rc
