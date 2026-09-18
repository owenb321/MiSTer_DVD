#!/usr/bin/env bash
#
# run_auddrain.sh -- a NATURAL transition must not discard audio the cell still
#                    has to present (Scooby-Doo 2 "commentary cut off",
#                    2026-09-18). dvd/aud_drain.sv, docs/dvd_nav.md.
#
# GREEN: iso_reader_auddrain_tb (the real reader -> demux -> audio_ring chain,
#        scoring what the consumer finished PLAYING before the flush) and
#        aud_drain_tb (unit arms), plus the natural-drain suites this touches.
# --red: R0 is the pre-fix wiring (the reader's audio term tied high, i.e. the
#        shipped reader); M1-M5 are targeted mutations, each required to fail
#        EXACTLY its designed arms - a mutation caught by everything says
#        nothing about which arm is load-bearing.
#
#   R0  pre-fix wiring (aud_drained tied 1)          -> A
#   M1  reader: nat_done ignores the audio           -> A
#   M2  reader: a USER seek waits for the audio too  -> B
#   M3  aud_drain: no settle window                  -> A U2 U4
#   M4  aud_drain: no dead-consumer escape           -> C U5
#   M5  aud_drain: ignores a decoder holding a frame -> U3
#
#   ./bench/dvd/run_auddrain.sh          # green
#   ./bench/dvd/run_auddrain.sh --red    # + R0 and the mutations
set -euo pipefail
cd "$(dirname "$0")/../.."

IV="iverilog -g2012"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CHAIN="dvd/dvd_vm.sv dvd/bcd_time_add.sv dvd/ps_stream_fifo.sv dvd/ps_demux.sv \
       dvd/flush_ctl.sv dvd/audio_ring.sv"
rc=0

# run_pair <reader.sv> <aud_drain.sv> <extra iverilog args> -> prints failing arms
run_pair () {
    local rd="$1" ad="$2" extra="$3" o u
    if ! $IV $extra -o "$TMP/chain" "$rd" $CHAIN "$ad" \
            bench/dvd/iso_reader_auddrain_tb.sv 2>"$TMP/cc.err"; then
        echo "COMPILE"; return
    fi
    if ! $IV -o "$TMP/unit" "$ad" bench/dvd/aud_drain_tb.sv 2>>"$TMP/cc.err"; then
        echo "COMPILE"; return
    fi
    o=$(timeout 900 vvp "$TMP/chain" 2>&1 || true)
    u=$(timeout 60  vvp "$TMP/unit"  2>&1 || true)
    echo "$o" > "$TMP/chain.out"; echo "$u" > "$TMP/unit.out"
    # ⚠ extract INSIDE the brackets: a bare [A-Z] also matches the letters of
    # "FAIL" itself, which reported every mutation as caught by arm A.
    { echo "$o"; echo "$u"; } | grep -oE '^FAIL: \[[A-Z][0-9]?\]' \
        | grep -oE '\[[A-Z][0-9]?\]' | tr -d '[]' | sort -u | tr '\n' ' ' \
        | sed 's/ $//' || true
}

echo "== auddrain: GREEN =="
got=$(run_pair dvd/dvd_iso_reader.sv dvd/aud_drain.sv "")
grep -E '^\s+\[' "$TMP/chain.out" "$TMP/unit.out" | sed 's/^[^:]*:/  /' || true
if [ -n "$got" ] || ! grep -q '^RESULT: PASS' "$TMP/chain.out" \
                  || ! grep -q '^RESULT: PASS' "$TMP/unit.out"; then
    echo "  FAIL: green arms failing: [${got}]"; rc=1
fi

# The natural-drain contract this change extends must be untouched.
echo "== auddrain: run_menudrain.sh (video half of the same gate) =="
if ./bench/dvd/run_menudrain.sh >"$TMP/md.out" 2>&1; then echo "  ok"
else echo "  FAIL: run_menudrain.sh"; tail -5 "$TMP/md.out"; rc=1; fi

if [ "${1:-}" = "--red" ]; then
    echo "== RED: each arm must be caught by exactly its own arms =="
    # red <id> <label> <file> <sed> <proof> <extra> <want>
    red () {
        local id="$1" label="$2" file="$3" expr="$4" proof="$5" extra="$6" want="$7"
        local rd=dvd/dvd_iso_reader.sv ad=dvd/aud_drain.sv got
        if [ -n "$file" ]; then
            sed "$expr" "$file" > "$TMP/$(basename "$file")"
            if ! grep -qF "$proof" "$TMP/$(basename "$file")"; then
                echo "  FAIL: $id did not apply -- $file moved"; rc=1; return
            fi
            [ "$file" = dvd/dvd_iso_reader.sv ] && rd="$TMP/dvd_iso_reader.sv"
            [ "$file" = dvd/aud_drain.sv ]      && ad="$TMP/aud_drain.sv"
        fi
        got=$(run_pair "$rd" "$ad" "$extra")
        echo "   $id $label: failing [${got:-none}], expected [$want]"
        [ "$got" = "$want" ] || { echo "  FAIL: $id caught by the wrong arms"; rc=1; }
    }
    red R0 "pre-fix wiring" "" "" "" "-Piso_reader_auddrain_tb.NO_AUDIO_TERM=1" "A"
    red M1 "nat_done ignores the audio" dvd/dvd_iso_reader.sv \
        's/wire       nat_done      = nat_drained \&\& aud_drained;/wire       nat_done      = nat_drained;/' \
        'wire       nat_done      = nat_drained;' "" "A"
    red M2 "a user seek waits for the audio" dvd/dvd_iso_reader.sv \
        's/(~snat_l || nat_done || drain_wd_hit);/(nat_done || drain_wd_hit);/' \
        '(nat_done || drain_wd_hit);' "" "B"
    red M3 "no settle window" dvd/aud_drain.sv \
        's/assign drained = ~consumer_alive || (quiet \&\& (settle == SETTLE_W));/assign drained = ~consumer_alive || quiet;/' \
        'assign drained = ~consumer_alive || quiet;' "" "A U2 U4"
    red M4 "no dead-consumer escape" dvd/aud_drain.sv \
        's/assign drained = ~consumer_alive || (quiet/assign drained = (quiet/' \
        'assign drained = (quiet' "" "C U5"
    red M5 "ignores a decoder holding a frame" dvd/aud_drain.sv \
        's/wire quiet = (frames_avail == 16.d0) \&\& ~dec_holding;/wire quiet = (frames_avail == 16'"'"'d0);/' \
        "wire quiet = (frames_avail == 16'd0);" "" "U3"
fi

[ "$rc" -eq 0 ] && echo "== auddrain: OK ==" || echo "== auddrain: FAIL =="
exit $rc
