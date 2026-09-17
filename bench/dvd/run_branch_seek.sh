#!/usr/bin/env bash
# run_branch_seek.sh — a raw-RBN seek into an INTERLEAVED block must land on the
# branch being played.  (issue #49)
#
# Playback of a seamless-branch block has been HW-CONFIRMED since PR fj#112: the
# reader follows vobu_sri.next_vobu and skips the sibling's ILVUs.  SEEKING into
# one was never covered.  The VOBU-align snap moves a raw target FORWARD to the
# next NAV pack — which belongs to whichever branch owns that ILVU — and
# next_vobu then follows the chain you are standing in, so the rest of the block
# plays the other cut and never converges back.
#
# MEASURED sibling share of an interleaved cell's span, i.e. how often a scrub
# lands in the wrong cut: Matrix VTS_02 cell 36 ~50 %, AVP VTS_03 cell 23 73 %,
# T2 VTS_01 cell 16 85 %.
#
# The multi-angle round (#101) built the filtered snap — PLAIN → LEARN → FILT on
# dsi_gi.vobu_vob_idn — but scoped it to block_type==1.  This gate covers the
# widened predicate and the ILVU-granular walk that makes it reachable at all:
# MEASURED longest sibling run is 877 sectors (Matrix), 4543 (T2), 8298 (AVP),
# so a one-sector-at-a-time walk cannot get there inside NAV_CAP=1024 on two of
# the three discs.
#
# Every arm scores the DELIVERED MARKER BYTES — which branch's sectors reached
# the decoder — never a signal the fix names.
set -u
cd "$(dirname "$0")/../.."
fail=0
iv() { iverilog -g2012 -I rtl/mpeg2 -o "$@"; }

SRC="dvd/dvd_iso_reader.sv dvd/bcd_time_add.sv"
TB="bench/dvd/iso_reader_branch_tb.sv"

# arm -> what it proves
declare -A WHAT=(
  [1]="target in a sibling ILVU's BODY: walk, then filter"
  [2]="target ON the sibling's NAV pack, NAV_CAP=4: only an ILVU hop fits"
  [3]="THREE branches (15/16/17, playing 16): two hops, no index rule"
  [4]="ilvu_ea zeroed: the +1-sector degrade still lands"
  [5]="plain playback + read ceiling: no probe on the mid-block ILVU hop"
  [6]="trailing sibling ILVU: the walk stops at the cell end"
)

green_arm() {   # arm
    local a=$1 d
    d=$(mktemp -d)
    if iv "$d/sim" -P"iso_reader_branch_tb.ARM=$a" $SRC "$TB" 2>"$d/build" \
       && vvp "$d/sim" > "$d/log" 2>&1 \
       && grep -q "ALL TESTS PASSED" "$d/log"; then
        echo "  PASS arm $a  — ${WHAT[$a]}"
        grep -E '^ARM ' "$d/log" | sed 's/^/      /'
    else
        echo "  FAIL arm $a  — ${WHAT[$a]}"
        tail -12 "$d/build" "$d/log" 2>/dev/null | sed 's/^/      /'
        fail=1
    fi
    rm -rf "$d"
}

green_tb() {    # name  pass-regex  sources...
    local name=$1 pat=$2; shift 2
    local d; d=$(mktemp -d)
    if iv "$d/sim" "$@" 2>"$d/build" && vvp "$d/sim" > "$d/log" 2>&1 \
       && grep -q "$pat" "$d/log"; then
        echo "  PASS $name"
    else
        echo "  FAIL $name"; tail -14 "$d/build" "$d/log" 2>/dev/null | sed 's/^/      /'; fail=1
    fi
    rm -rf "$d"
}

# Which arms a mutation must break — and ONLY those.  A mutation caught by every
# arm says nothing about which arm is load-bearing (the run_title_span.sh rule).
declare -A MUT_SED MUT_ARMS MUT_WHY
MUT_SED[M1]='s|wire       snap_want   = cc_angle_ok \|\| cc_seam_ok;|wire       snap_want   = cc_angle_ok;|'
MUT_ARMS[M1]="1 2 3 4"
MUT_WHY[M1]="scope the filtered snap back to angle blocks (the shipped predicate)"

# vobu_c_idn is DSI 0x1B -> rbuf[19] in the same window.  It is IDENTICAL on both
# branches of AVP and Matrix, so a filter keyed on it accepts the first candidate.
MUT_SED[M2]='s|wire \[15:0\] nav_vob    = {rbuf\[16\], rbuf\[17\]};|wire [15:0] nav_vob    = {8'"'"'d0, rbuf[19]};|'
MUT_ARMS[M2]="1 2 3 4"
MUT_WHY[M2]="filter on vobu_c_idn instead of vobu_vob_idn"

# "the sibling is always a higher VOB_ID" — true of AVP and Matrix, false of T2.
MUT_SED[M3]='s|end else if (nav_vob == snap_want_vob) begin|end else if (nav_vob >= snap_want_vob) begin|'
MUT_ARMS[M3]="3"
MUT_WHY[M3]="assume siblings sort above the played branch (an ordering rule)"

MUT_SED[M4]='s|wire \[31:0\] nav_step   = (nav_in_blk \&\& nav_ilvuea != 32.d0)|wire [31:0] nav_step   = (1'"'"'b0)|'
MUT_ARMS[M4]="2"
MUT_WHY[M4]="step one sector at a time instead of one ILVU"

# Make the mid-block ILVU HOP request a branch verification, which is exactly what
# keying the divert on `rbn_override` did in the angle round: the hop sets
# rbn_override too.  The outcome stays CORRECT -- the probe re-confirms a landing
# that was already right -- so every byte-scoring arm still passes and the read
# ceiling is the only thing that can see it.  On hardware it would arrive as a
# stutter at an ILVU boundary and be blamed on something else.
# (Deleting the snap_pend term outright is NOT this mutation: it re-arms the probe
# on its own landing and loops, which every arm catches and which therefore says
# nothing about which arm is load-bearing.)
MUT_SED[M5]='s|                                seek_rbn_l   <= ilvu_target;|                                seek_rbn_l   <= ilvu_target;\n                                snap_pend    <= 1'"'"'b1;|'
MUT_ARMS[M5]="5"
MUT_WHY[M5]="let the mid-block ILVU hop request a branch verification"

MUT_SED[M6]='s|(nav_mode != NAVM_PLAIN \&\& nav_cand > cl_rd) \|\|||'
MUT_ARMS[M6]="6"
MUT_WHY[M6]="let the filter walk past the end of the cell it is filtering"

red_mut() {     # name
    local name=$1 d got want
    d=$(mktemp -d)
    sed "${MUT_SED[$name]}" dvd/dvd_iso_reader.sv > "$d/dvd_iso_reader.sv"
    if cmp -s "$d/dvd_iso_reader.sv" dvd/dvd_iso_reader.sv; then
        echo "  FAIL $name: mutation did not apply (anchor moved)"; fail=1; rm -rf "$d"; return
    fi
    got=""
    for a in 1 2 3 4 5 6; do
        # a mutation that does not COMPILE proves nothing about the bench
        if ! iv "$d/sim$a" -P"iso_reader_branch_tb.ARM=$a" \
                "$d/dvd_iso_reader.sv" dvd/bcd_time_add.sv "$TB" 2>"$d/b$a"; then
            echo "  FAIL $name: mutated module did not build"; sed 's/^/      /' "$d/b$a"; fail=1
            rm -rf "$d"; return
        fi
        vvp "$d/sim$a" > "$d/l$a" 2>&1
        grep -q "ALL TESTS PASSED" "$d/l$a" || got="$got $a"
    done
    want=" ${MUT_ARMS[$name]}"
    got=$(echo $got | tr -s ' '); want=$(echo $want | tr -s ' ')
    if [ "$got" = "$want" ]; then
        echo "  PASS $name  (arms$( [ -n "$got" ] && echo " $got" ) fail) — ${MUT_WHY[$name]}"
    else
        echo "  FAIL $name: expected arms [$want] to fail, got [$got] — ${MUT_WHY[$name]}"
        fail=1
    fi
    rm -rf "$d"
}

echo "== GREEN =="
for a in 1 2 3 4 5 6; do green_arm $a; done

echo "== REGRESSION (must be unchanged by this branch) =="
green_tb iso_reader_ilvu  "ALL TESTS PASSED" $SRC bench/dvd/iso_reader_ilvu_tb.sv
green_tb iso_reader_angle "ALL TESTS PASSED" $SRC bench/dvd/iso_reader_angle_tb.sv
green_tb angle_noagli     "ALL TESTS PASSED" $SRC bench/dvd/angle_noagli_tb.sv
green_tb iso_reader_scrub "ALL TESTS PASSED" $SRC bench/dvd/iso_reader_scrub_tb.sv
green_tb iso_reader_seek  "ALL TESTS PASSED" $SRC bench/dvd/iso_reader_seek_tb.sv

if [ "${1:-}" = "--red" ]; then
    echo "== RED (each mutation must fail EXACTLY its own arms) =="
    for m in M1 M2 M3 M4 M5 M6; do red_mut $m; done
fi

[ $fail -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit $fail
