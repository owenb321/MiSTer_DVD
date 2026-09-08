#!/usr/bin/env bash
# run_seamless_audio.sh — a seamless-branch junction must NOT flush audio.
#
# PR #63 made the display's re-anchor flush the audio chain (disc_rephase ->
# aud_resync). That was accepted on "titles re-anchor about once per playback
# (reanchors=1 over 80 s on APOLLO_13)". APOLLO_13 is one continuous title; a
# seamless-branch title is not, and the field reported an audio dropout at every
# "white rabbit" point of The Matrix -- in the PLAIN movie too, because PGCN 1
# carries the same 9 interleaved cell-pairs.
#
# Two halves, each gated and each proven RED:
#   reader   - cell_seamless exports the AUTHORED seamless_play bit (cell_playback_t
#              byte 0 bit 3), per cell. RED reads bit 2 (interleaved) instead, which
#              coincides on the white-rabbit cells and differs on the other 86.
#   flush_ctl- disc_rephase on such a cell must fire NOTHING, while an audio track
#              switch on the same cell still resets the chain.
set -u
cd "$(dirname "$0")/../.."
fail=0
iv() { iverilog -g2012 -I rtl/mpeg2 -o "$@"; }

green() {  # name  pass-regex  sources...
    local name=$1 pat=$2; shift 2
    local d; d=$(mktemp -d)
    if iv "$d/sim" "$@" 2>"$d/build" && vvp "$d/sim" > "$d/log" 2>&1 \
       && grep -q "$pat" "$d/log"; then
        echo "  PASS $name"; grep -E '^\s+ok:|^ILVU seamless_play' "$d/log" | sed 's/^/      /'
    else
        echo "  FAIL $name"; tail -12 "$d/build" "$d/log" 2>/dev/null | sed 's/^/      /'; fail=1
    fi
    rm -rf "$d"
}

red() {    # name  file-to-mutate  sed  extra-sources...  (bench is last)
    local name=$1 src=$2 script=$3; shift 3
    local d; d=$(mktemp -d); local base; base=$(basename "$src")
    sed "$script" "$src" > "$d/$base"
    if cmp -s "$d/$base" "$src"; then
        echo "  FAIL $name: mutation did not apply (anchor moved)"; fail=1
    elif ! iv "$d/sim" "$d/$base" "$@" 2>"$d/build"; then
        # a mutation that does not COMPILE proves nothing about the bench
        echo "  FAIL $name: mutated module did not build"; sed 's/^/      /' "$d/build"; fail=1
    elif vvp "$d/sim" 2>&1 | tee "$d/log" | grep -qE "ALL TESTS PASSED|ALL TESTS PASSED \(" ; then
        echo "  FAIL $name: the bench PASSED without the fix"; fail=1
    else
        echo "  PASS $name"; grep -E 'FAIL' "$d/log" | head -3 | sed 's/^/      /'
    fi
    rm -rf "$d"
}

echo "== GREEN =="
green iso_reader_ilvu "ALL TESTS PASSED" dvd/dvd_iso_reader.sv dvd/bcd_time_add.sv bench/dvd/iso_reader_ilvu_tb.sv
green flush_ctl       "ALL TESTS PASSED" dvd/flush_ctl.sv bench/dvd/flush_ctl_tb.sv
# the other flush_ctl instantiation must still elaborate with the new port
green mode_realign_chain "ALL TESTS PASSED" dvd/mode_realign.sv dvd/flush_ctl.sv \
      dvd/dvd_iso_reader.sv dvd/bcd_time_add.sv bench/dvd/mode_realign_chain_tb.sv

if [ "${1:-}" = "--red" ]; then
    echo "== RED =="
    red reader-wrong-bit dvd/dvd_iso_reader.sv \
        's|wire       cc_seamless_play = cc_rd\[3\];|wire       cc_seamless_play = cc_rd[2];|' \
        dvd/bcd_time_add.sv bench/dvd/iso_reader_ilvu_tb.sv
    red flush-no-gate dvd/flush_ctl.sv \
        's|(disc_rephase \&\& !cell_seamless)|(disc_rephase)|' \
        bench/dvd/flush_ctl_tb.sv
fi

[ $fail -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit $fail
