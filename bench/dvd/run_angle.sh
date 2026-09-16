#!/usr/bin/env bash
# run_angle.sh — multi-angle ILVU follow, including discs that author NO sml_agli.
#
# Phase 9 arms the angle ILVU jump from the DSI sml_agli per-angle table. A
# multi-angle disc need not author one. MEASURED: CASTLE_IN_THE_SKY VTS_02 PGC1
# (3 angle blocks) and DIEANOTHERDAY_D1_PS VTS_05 PGC1 (19 blocks) carry
# sml_agli ALL ZERO on every VOBU, with the chain only in vobu_sri.next_vobu.
# Library sweep: 23 discs have block_type==1 angle blocks, 4 author no sml_agli.
# libdvdnav never hits this because next_vobu is its BASE next-VOBU and sml_agli
# is only an OVERRIDE (dvdnav.c:434-468); the reader made the override mandatory
# and streamed the interleaved range linearly = the reported "rapidly switches
# between the two angles", plus a ~2 s BACKWARD audio PTS jump per junction
# (the reported "pop noise").
#
# GREEN arms:
#   angle_noagli     - the new case. Scores the DELIVERED BYTE STREAM (which
#                      angle's markers came out) and the PTS carried in it.
#   iso_reader_angle - CONTROL: the sml_agli-populated MiB shape, which must be
#                      byte-identical to before this change. This is what
#                      confines the delta to the 4 affected discs.
#   iso_reader_ilvu  - CONTROL: seamless-branch (Matrix/T2), shares the snoop.
#   nav_angle        - CONTROL: the DSI decode against a REAL MiB NAV sector.
set -u
cd "$(dirname "$0")/../.."
fail=0
iv() { iverilog -g2012 -I rtl/mpeg2 -o "$@"; }

green() {  # name  pass-regex  sources...
    local name=$1 pat=$2; shift 2
    local d; d=$(mktemp -d)
    if iv "$d/sim" "$@" 2>"$d/build" && vvp "$d/sim" > "$d/log" 2>&1 \
       && grep -q "$pat" "$d/log"; then
        echo "  PASS $name"; grep -E '^\[|^\s+ok:' "$d/log" | sed 's/^/      /'
    else
        echo "  FAIL $name"; tail -14 "$d/build" "$d/log" 2>/dev/null | sed 's/^/      /'; fail=1
    fi
    rm -rf "$d"
}

# red NAME  SED  EXPECT_FAIL_ARMS  BENCH  [extra sources...]
# Mutates dvd/dvd_iso_reader.sv and requires the named bench to FAIL. The
# expectation string is printed so a mutation caught by the wrong arm is
# visible rather than merely "red".
red() {
    local name=$1 script=$2 expect=$3 bench=$4; shift 4
    local src=dvd/dvd_iso_reader.sv
    local d; d=$(mktemp -d)
    sed "$script" "$src" > "$d/dvd_iso_reader.sv"
    if cmp -s "$d/dvd_iso_reader.sv" "$src"; then
        echo "  FAIL $name: mutation did not apply (anchor moved)"; fail=1
    elif ! iv "$d/sim" "$d/dvd_iso_reader.sv" dvd/bcd_time_add.sv "$bench" "$@" 2>"$d/build"; then
        # a mutation that does not COMPILE proves nothing about the bench
        echo "  FAIL $name: mutated module did not build"; sed 's/^/      /' "$d/build"; fail=1
    elif vvp "$d/sim" 2>&1 | tee "$d/log" | grep -q "ALL TESTS PASSED"; then
        echo "  FAIL $name: $(basename "$bench") PASSED without the fix (want $expect)"; fail=1
    else
        echo "  PASS $name  (want $expect)"
        grep -E '^\s+FAIL' "$d/log" | head -3 | sed 's/^/      /'
    fi
    rm -rf "$d"
}

# A mutation must NOT break the control benches; assert that too, or a
# "mutation caught by everything" tells you nothing about which arm is
# load-bearing (the run_title_span.sh lesson).
red_clean() {   # name  sed  bench  [extra sources...]
    local name=$1 script=$2 bench=$3; shift 3
    local src=dvd/dvd_iso_reader.sv
    local d; d=$(mktemp -d)
    sed "$script" "$src" > "$d/dvd_iso_reader.sv"
    if iv "$d/sim" "$d/dvd_iso_reader.sv" dvd/bcd_time_add.sv "$bench" "$@" 2>"$d/build" \
       && vvp "$d/sim" 2>&1 | grep -q "ALL TESTS PASSED"; then
        echo "    ok  $name leaves $(basename "$bench") green"
    else
        echo "    FAIL $name also broke $(basename "$bench") -- not confined"; fail=1
    fi
    rm -rf "$d"
}

RD=dvd/dvd_iso_reader.sv
BT=dvd/bcd_time_add.sv

echo "== GREEN =="
green angle_noagli     "ALL TESTS PASSED" $RD $BT bench/dvd/angle_noagli_tb.sv
green iso_reader_angle "ALL TESTS PASSED" $RD $BT bench/dvd/iso_reader_angle_tb.sv
green iso_reader_ilvu  "ALL TESTS PASSED" $RD $BT bench/dvd/iso_reader_ilvu_tb.sv
# nav_angle_tb needs bench/dvd/test_vobs/mib_angle_dsi.hex, which is gitignored
# (it is disc data). It SKIPs cleanly when absent, so accept either -- but the
# skip is printed, so a machine that has the fixture cannot silently lose it.
green nav_angle        "nav_angle_tb: \(PASS\|SKIP\)" dvd/nav_dsi.sv bench/dvd/nav_angle_tb.sv

if [ "${1:-}" = "--red" ]; then
    echo "== RED =="

    # M1 - the defect itself: make sml_agli mandatory again for the angle arm.
    red M1-no-fallback \
        's|&& (snoop_ag_ok \|\| snoop_nv_ok)) begin|\&\& (snoop_ag_ok)) begin|' \
        "angle_noagli [A][B][C]" bench/dvd/angle_noagli_tb.sv
    red_clean M1-no-fallback \
        's|&& (snoop_ag_ok \|\| snoop_nv_ok)) begin|\&\& (snoop_ag_ok)) begin|' \
        bench/dvd/iso_reader_angle_tb.sv

    # M2 - wrong PREFERENCE: take next_vobu even when sml_agli is authored.
    # next_vobu follows the angle whose VOBU was read, so a mid-block switch
    # can no longer retarget -> the sml_agli control bench must fail.
    red M2-prefer-nextvobu \
        's|ilvu_target    <= snoop_ag_ok ? snoop_tgt : snoop_nvtgt;|ilvu_target    <= snoop_nv_ok ? snoop_nvtgt : snoop_tgt;|' \
        "iso_reader_angle TEST B" bench/dvd/iso_reader_angle_tb.sv
    red_clean M2-prefer-nextvobu \
        's|ilvu_target    <= snoop_ag_ok ? snoop_tgt : snoop_nvtgt;|ilvu_target    <= snoop_nv_ok ? snoop_nvtgt : snoop_tgt;|' \
        bench/dvd/angle_noagli_tb.sv

    # M3 - re-point the cell on a FALLBACK arm too. next_vobu knows nothing
    # about the siblings, so bounding this angle's target by another angle's
    # cell corrupts the stream.
    red M3-repoint-on-fallback \
        's|if (angle_active && ilvu_from_agli) begin|if (angle_active) begin|' \
        "angle_noagli [C]" bench/dvd/angle_noagli_tb.sv

    # M4 - drop the in-cell bound on the fallback target. The fixture's last
    # angle-1 hop deliberately points PAST the cell (RBN 11 vs last_sector 9),
    # so accepting it streams the sibling's body and runs off the end of the
    # cell. Shares arms with M1, but the two mutate different terms and the
    # red_clean control below separates them.
    red M4-unbounded-fallback \
        's|wire        snoop_nv_ok  = snoop_nvvalid && (snoop_nvtgt <= cl_rd);|wire        snoop_nv_ok  = snoop_nvvalid;|' \
        "angle_noagli [A][B][C]" bench/dvd/angle_noagli_tb.sv
    red_clean M4-unbounded-fallback \
        's|wire        snoop_nv_ok  = snoop_nvvalid && (snoop_nvtgt <= cl_rd);|wire        snoop_nv_ok  = snoop_nvvalid;|' \
        bench/dvd/iso_reader_angle_tb.sv
fi

[ $fail -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit $fail
