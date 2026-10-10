#!/usr/bin/env bash
# run_pause_wdog.sh -- a pause must not lose audio (dvd/dvd_audio_decode.sv's
# decode-stall watchdog is held clear while paused; docs/status_log.md
# "Pause loses audio").
#
#   GREEN  bench/dvd/pause_wdog_tb.sv   +PAUSE=0 control (every sample of every frame
#                                       plays) and +PAUSE=1 (the same, across a pause of
#                                       five watchdog periods)
#          bench/dvd/dvd_audio_decode_tb.sv  the drain gate / dispatcher contract
#   RED    (--red) the `|| pause` hold removed: the pause arm must fail [reset] and
#          [count], and the control must still pass (it never pauses).
set -u
cd "$(dirname "$0")/../.."
fail=0
SRC="dvd/ac3/*.sv dvd/dts/dts_seq.sv dvd/dts/dts_vec.sv dvd/dts/dts_top.sv dvd/audio_engine.sv dvd/lpcm_unpack.sv dvd/lpcm_hb.sv dvd/dts/cb_host_ram.sv"
iv() { iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -I dvd/ac3 -o "$@" 2>&1 | grep -v "sorry:" ; }

run() {  # name dut tb plusarg expect(pass|fail) [fail-regex...]
    local name=$1 dut=$2 tb=$3 arg=$4 want=$5; shift 5
    local d; d=$(mktemp -d)
    iv "$d/sim" $SRC "$dut" "$tb" > "$d/build"
    if [ ! -f "$d/sim" ]; then
        echo "  FAIL $name: did not build"; sed 's/^/      /' "$d/build" | tail -15; fail=1; rm -rf "$d"; return
    fi
    vvp "$d/sim" $arg > "$d/log" 2>&1
    if [ ! -s "$d/log" ]; then
        echo "  FAIL $name: no output -- not a verdict"; fail=1
    elif [ "$want" = pass ]; then
        if grep -q "^PASS" "$d/log" && ! grep -q "^FAIL" "$d/log"; then
            echo "  PASS $name"; grep -E '^\s+\[' "$d/log" | sed 's/^/      /'
        else
            echo "  FAIL $name"; tail -15 "$d/log" | sed 's/^/      /'; fail=1
        fi
    else
        local ok=1 p
        grep -q "^PASS" "$d/log" && ok=0
        for p in "$@"; do grep -qE "$p" "$d/log" || ok=0; done
        if [ $ok = 1 ]; then
            echo "  PASS $name (failed as it must)"; grep -E '^FAIL|^\s+\[|self-heal' "$d/log" | head -5 | sed 's/^/      /'
        else
            echo "  FAIL $name: did not fail on its own assertions"; tail -10 "$d/log" | sed 's/^/      /'; fail=1
        fi
    fi
    rm -rf "$d"
}

echo "== GREEN"
run "pause_wdog control (no pause)" dvd/dvd_audio_decode.sv bench/dvd/pause_wdog_tb.sv +PAUSE=0 pass
run "pause_wdog pause"              dvd/dvd_audio_decode.sv bench/dvd/pause_wdog_tb.sv +PAUSE=1 pass
run "dvd_audio_decode_tb"           dvd/dvd_audio_decode.sv bench/dvd/dvd_audio_decode_tb.sv "" pass

if [ "${1:-}" = "--red" ]; then
    echo "== RED"
    d=$(mktemp -d)
    python3 - "$d/dvd_audio_decode.sv" <<'PYEOF'
import sys
s = open('dvd/dvd_audio_decode.sv').read()
old = "|| !drain_en || pause)"
if s.count(old) != 1:
    sys.exit("RED anchor moved: " + old)
open(sys.argv[1], 'w').write(s.replace(old, "|| !drain_en)"))
PYEOF
    if [ -f "$d/dvd_audio_decode.sv" ]; then
        run "R1 no pause hold: pause arm"    "$d/dvd_audio_decode.sv" bench/dvd/pause_wdog_tb.sv +PAUSE=1 fail '^FAIL \[reset\]' '^FAIL \[count\]'
        run "R1 no pause hold: control arm"  "$d/dvd_audio_decode.sv" bench/dvd/pause_wdog_tb.sv +PAUSE=0 pass
    else
        echo "  FAIL R1: mutation did not apply"; fail=1
    fi
    rm -rf "$d"
fi

[ $fail = 0 ] && echo "run_pause_wdog: ALL PASS" || { echo "run_pause_wdog: FAILURES"; exit 1; }
