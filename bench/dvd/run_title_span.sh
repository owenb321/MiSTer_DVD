#!/usr/bin/env bash
# run_title_span.sh — the title RBN span gate.
#
# The defect: dvd_iso_reader took `title_last_rbn` from the LAST-WRITTEN cell of
# the PGC walk, assuming program order == ascending physical order. 45 of 958
# library ISOs break that (the last program cell sits physically at the FRONT of
# the VOBS), publishing last < first — which collapses scrub_ctrl's span to 1,
# clamps EVERY seek to the last program cell ("any seek jumps to the end of the
# movie"), saturates seek_bar's fill to a solid block and pushes every chapter
# notch off the raster.
#
# GREEN: title_span_tb (the gate) + the suites that must be UNCHANGED.
# RED  : sed-mutated copies of dvd_iso_reader.sv, because a bench cannot mutate
#        the module it instantiates. Each mutation must be caught by the arm it
#        exists for AND BY NO OTHER — a mutation caught by everything tells you
#        nothing about which arm is load-bearing.
#          M1 pre-fix    : the bare last-written assignment   -> B C D E
#          M2 no-seed    : drop the per-PGC cell-0 re-seed    -> D and F
#          M3 inverted   : take the MIN instead of the MAX    -> B C D E F
#          M5 gap-last   : S_RBN_SCAN miss -> last cell again -> G only
#          M6 first-cell0: title_first back to cell[0] (pre-split) -> H I J
#          M7 no-cross-lo: drop the backward program-start stop   -> E only
#          M8 no-cross-hi: drop the forward program-end stop      -> I only
#
# ⛔ There WAS an M4 ("title_first becomes min(first_sector)") and it is gone
# because that mutation is now the SHIPPING rule: title_first IS the minimum, and
# what protects a backward underflow is no longer the choice of that value but the
# cross_lo program-start stop. Its job is covered twice over -- M6 reverts the
# minimum and fails H/I/J, M7 removes the stop and fails E. A mutation that no
# longer describes a wrong version of the code is not a gate, it is noise.
#
# ⚠ M2 breaks arm D as well as arm F, and that is a MEASURED property of the
# design, not a loose mutation. The reader's LINEAR branch publishes
# title_last_rbn = total_blocks-1 before iso_mode is known, so at the first PGC
# walk the register already holds the whole IMAGE's last block. A bare max()
# keeps that, the span covers sectors no cell owns, and the forward clamp stops
# clamping (arm D asks 64 on a title that ends at 39). So the cell-0 seed is
# load-bearing on the FIRST mount too, not only across PGCs.
set -u
cd "$(dirname "$0")/../.."
fail=0
RTL="dvd/dvd_iso_reader.sv"
DEPS="dvd/bcd_time_add.sv dvd/scrub_ctrl.sv"

iv() { iverilog -g2012 -o "$@"; }

# run <name> <pass-string> <sources...>
run() {
    local name=$1 pass=$2; shift 2
    if iv "/tmp/ts_$name" "$@" 2>"/tmp/ts_$name.build"; then
        if vvp "/tmp/ts_$name" > "/tmp/ts_$name.log" 2>&1 && grep -q "$pass" "/tmp/ts_$name.log"; then
            echo "  PASS $name"
        else
            echo "  FAIL $name"; tail -20 "/tmp/ts_$name.log"; fail=1
        fi
    else
        echo "  FAIL $name (build)"; sed 's/^/      /' "/tmp/ts_$name.build"; fail=1
    fi
}

echo "== GREEN: the gate =="
run title_span "TITLE_SPAN_TB: ALL TESTS PASSED" \
    $RTL $DEPS bench/dvd/title_span_tb.sv
grep -E '^  ok:|^[A-Z]: ' /tmp/ts_title_span.log | sed 's/^/  /'

echo "== GREEN: the MIRROR shape (cell[0] physically last) =="
run title_span_late0 "TITLE_SPAN_TB: ALL TESTS PASSED" \
    -DTITLE_SPAN_LATE0 $RTL $DEPS bench/dvd/title_span_tb.sv
grep -E '^  ok:|program ends' /tmp/ts_title_span_late0.log | sed 's/^/  /'

echo "== GREEN: the gap arm (change 2) =="
run title_span_gap "TITLE_SPAN_TB: ALL TESTS PASSED" \
    -DTITLE_SPAN_GAP $RTL $DEPS bench/dvd/title_span_tb.sv
grep -E '^  ok:' /tmp/ts_title_span_gap.log | sed 's/^/  /'

echo "== GREEN: suites that must be UNCHANGED =="
run iso_reader_scrub_tb   "ISO_READER_SCRUB_TB: ALL TESTS PASSED"   $RTL dvd/bcd_time_add.sv bench/dvd/iso_reader_scrub_tb.sv
run iso_reader_seek_tb    "ISO_READER_SEEK_TB: ALL TESTS PASSED"    $RTL dvd/bcd_time_add.sv bench/dvd/iso_reader_seek_tb.sv
run iso_reader_chapter_tb "ISO_READER_CHAPTER_TB: ALL TESTS PASSED" $RTL dvd/bcd_time_add.sv bench/dvd/iso_reader_chapter_tb.sv
run iso_reader_pgc_tb     "ISO_READER_PGC_TB: ALL TESTS PASSED"     $RTL dvd/bcd_time_add.sv bench/dvd/iso_reader_pgc_tb.sv
run scrub_ctrl_tb         "scrub_ctrl_tb: ALL TESTS PASSED"         dvd/scrub_ctrl.sv bench/dvd/scrub_ctrl_tb.sv
run seek_bar_tb           "SEEK_BAR_TB: ALL TESTS PASSED"           dvd/seek_bar.sv bench/dvd/seek_bar_tb.sv
run seek_time_tb          "seek_time_tb: ALL TESTS PASSED"          dvd/seek_time.sv dvd/secs_bcd.sv bench/dvd/seek_time_tb.sv

# red <name> <sed-script> <expected-failing-arms> [extra-defines] [file-to-mutate]
# Verifies three things, all of which have silently passed a weak gate before:
#   (a) the mutation actually APPLIED (the anchor may have moved),
#   (b) the mutated module still BUILDS (a build error proves nothing),
#   (c) EXACTLY the expected arms failed -- no more, no fewer.
red() {
    local name=$1 script=$2 want=$3 defs=${4:-} tgt=${5:-$RTL}
    local d; d=$(mktemp -d)
    local base; base=$(basename "$tgt")
    local rest=""
    sed "$script" "$tgt" > "$d/$base"
    # everything the DUT needs except the file being mutated
    for f in $RTL $DEPS; do [ "$f" = "$tgt" ] || rest="$rest $f"; done
    if cmp -s "$d/$base" "$tgt"; then
        echo "  FAIL $name: the mutation did not apply (anchor moved)"; fail=1
    elif ! iv "$d/sim" $defs "$d/$base" $rest bench/dvd/title_span_tb.sv 2>"$d/build"; then
        echo "  FAIL $name: the mutated module did not build"; sed 's/^/      /' "$d/build"; fail=1
    else
        vvp "$d/sim" > "$d/log" 2>&1
        local got
        got=$(sed -n 's/^  FAIL: \(.\).*/\1/p' "$d/log" | sort -u | tr -d '\n')
        if [ "$got" = "$want" ]; then
            echo "  PASS $name (arms $got failed, as designed)"
        else
            echo "  FAIL $name: expected arms [$want] to fail, got [$got]"
            grep 'FAIL:' "$d/log" | sed 's/^/      /'; fail=1
        fi
    fi
    rm -rf "$d"
}

if [ "${1:-}" = "--red" ]; then
    echo "== RED arms =="
    # M1: the pre-fix rule -- the last-written cell's last_sector.
    red M1-prefix \
        "s@if (cell_wi == 8'd0 || cell_last_w > title_last_rbn)\$@if (1'b1)@" \
        "BCDE"
    # M2: keep the max, drop the cell-0 re-seed. Arm F sees the previous PGC's
    # span leak; arm D sees the LINEAR pre-mount value (total_blocks-1) survive.
    red M2-noseed \
        "s@if (cell_wi == 8'd0 || cell_last_w > title_last_rbn)\$@if (cell_last_w > title_last_rbn)@" \
        "DF"
    # M3: take the MIN instead of the MAX.
    red M3-inverted \
        "s@if (cell_wi == 8'd0 || cell_last_w > title_last_rbn)\$@if (cell_wi == 8'd0 || cell_last_w < title_last_rbn)@" \
        "BCDEF"
    # M5: change 2 reverted -- a gap landing plays the last cell again.
    red M5-gaplast \
        "s@cell_i       <= rbn_bt_v ? rbn_bt_i : 8'd0;@cell_i       <= cell_count - 8'd1;@" \
        "G" "-DTITLE_SPAN_GAP"
    # M6: title_first back to cell[0].first -- the state BETWEEN the two halves of
    # the fix. The mirror shape is exactly what that state cannot serve.
    red M6-firstcell0 \
        "s@if (cell_wi == 8'd0 || {wacc, pb_rdata} < title_first_rbn)@if (cell_wi == 8'd0 || 1'b0)@" \
        "HIJ" "-DTITLE_SPAN_LATE0"
    # M7/M8 mutate scrub_ctrl, not the reader: the crossing rules live there.
    red M7-nocrosslo \
        "s@wire cross_lo = ~pending_dir@wire cross_lo = 1'b0 \&\& ~pending_dir@" \
        "E" "" dvd/scrub_ctrl.sv
    red M8-nocrosshi \
        "s@wire cross_hi =  pending_dir@wire cross_hi =  1'b0 \&\& pending_dir@" \
        "I" "-DTITLE_SPAN_LATE0" dvd/scrub_ctrl.sv
fi

[ $fail -eq 0 ] && echo "RUN_TITLE_SPAN: ALL GREEN" || echo "RUN_TITLE_SPAN: FAILURES"
exit $fail
