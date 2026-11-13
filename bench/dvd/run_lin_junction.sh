#!/usr/bin/env bash
# run_lin_junction.sh -- the linear-stream junction (issue #188): ps_demux parks on a
# program end code (0xB9) on a linear stream, dvd/lin_junction.sv waits for the old
# stream to play out, fires flush_ctl's lin_junction row (aud + seek flush, no load
# flush) and releases the demux. docs/vcd_svcd.md "CD-i Digital Video".
#
#   GREEN  bench/dvd/lin_junction_tb.sv  the real ps_demux + lin_junction, 9 arms
#          bench/dvd/flush_ctl_tb.sv     the trigger matrix, row [12]/[12b] included
#   RED    (--red) one mutation per claim; each must fail EXACTLY its own arms
#          (the set of failing arms is compared, not just "something failed").
set -u
cd "$(dirname "$0")/../.."
fail=0

run() {  # name tb srcs... -- want(pass | "fail:[a] [b]")
    local name=$1 tb=$2 want=$3; shift 3
    local d; d=$(mktemp -d)
    iverilog -g2012 -o "$d/sim" "$@" "$tb" > "$d/build" 2>&1
    if [ ! -f "$d/sim" ]; then
        echo "  FAIL $name: did not build"; tail -10 "$d/build" | sed 's/^/      /'; fail=1; rm -rf "$d"; return
    fi
    timeout 300 vvp "$d/sim" > "$d/log" 2>&1
    if [ ! -s "$d/log" ]; then
        echo "  FAIL $name: no output -- not a verdict"; fail=1
    elif [ "$want" = pass ]; then
        if grep -qE "^PASS|ALL TESTS PASSED" "$d/log" && ! grep -q "^FAIL" "$d/log"; then
            echo "  PASS $name"
        else
            echo "  FAIL $name"; tail -12 "$d/log" | sed 's/^/      /'; fail=1
        fi
    else
        local got exp
        got=$(grep -oE '^FAIL:? *\[[0-9a-z]+\]' "$d/log" | grep -oE '\[[0-9a-z]+\]' | sort -u | tr '\n' ' ')
        exp=$(echo "${want#fail:}" | tr ' ' '\n' | grep . | sort -u | tr '\n' ' ')
        if grep -qE "^PASS|ALL TESTS PASSED" "$d/log"; then
            echo "  FAIL $name: passed -- the gate cannot see this mutation"; fail=1
        elif [ "$got" = "$exp" ]; then
            echo "  PASS $name (failed exactly $got)"
        else
            echo "  FAIL $name: failed arms {$got}, want {$exp}"; grep -E '^FAIL' "$d/log" | head -6 | sed 's/^/      /'; fail=1
        fi
    fi
    rm -rf "$d"
}

mutate() {  # src out old new
    python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import sys
src, out, old, new = sys.argv[1:]
s = open(src).read()
if s.count(old) != 1:
    sys.exit("RED anchor moved (%d hits): %s" % (s.count(old), old))
open(out, 'w').write(s.replace(old, new))
PYEOF
}

echo "== GREEN"
run "lin_junction_tb" bench/dvd/lin_junction_tb.sv pass dvd/ps_demux.sv dvd/lin_junction.sv
run "flush_ctl_tb"    bench/dvd/flush_ctl_tb.sv    pass dvd/flush_ctl.sv

if [ "${1:-}" = "--red" ]; then
    echo "== RED"
    d=$(mktemp -d)
    red() {  # name file old new want
        local name=$1 file=$2 old=$3 new=$4 want=$5 m
        m="$d/$(basename "$file")"
        if ! mutate "$file" "$m" "$old" "$new"; then echo "  FAIL $name: mutation did not apply"; fail=1; return; fi
        case "$file" in
            dvd/lin_junction.sv) run "$name" bench/dvd/lin_junction_tb.sv "$want" dvd/ps_demux.sv "$m" ;;
            dvd/ps_demux.sv)     run "$name" bench/dvd/lin_junction_tb.sv "$want" "$m" dvd/lin_junction.sv ;;
            dvd/flush_ctl.sv)    run "$name" bench/dvd/flush_ctl_tb.sv    "$want" "$m" ;;
        esac
        rm -f "$m"
    }
    red "M1 re-arms on the release cycle" dvd/lin_junction.sv \
        "IDLE: if (jn_wait && !go) begin" "IDLE: if (jn_wait) begin" "fail:[4] [9]"
    red "M2 a drain blip does not restart the settle" dvd/lin_junction.sv \
        "? settle + 1'b1 : '0;" "? settle + 1'b1 : settle;" "fail:[2]"
    red "M3 no watchdog" dvd/lin_junction.sv \
        "if ((&settle) || (&wd)) begin" "if (&settle) begin" "fail:[5]"
    red "M4 parks with jn_en low (DVD cell mode)" dvd/ps_demux.sv \
        "in_byte == 8'hB9 && jn_en)" "in_byte == 8'hB9)" "fail:[7]"
    red "M5 parks without the still-frame filler" dvd/ps_demux.sv \
        "            flush_cnt <= VID_FLUSH_LEN;
            state     <= S_VID_FLUSH;
        end else if (consume) begin" \
        "            state     <= S_JN_WAIT;
        end else if (consume) begin" "fail:[1] [9]"
    red "M6 a parked demux takes input" dvd/ps_demux.sv \
        "S_JN_WAIT:    in_ready = 1'b0;" "S_JN_WAIT:    in_ready = 1'b1;" "fail:[1] [3] [9]"
    red "M8 a bare 0xB9 parks (the CD-i channel end)" dvd/ps_demux.sv \
        "jn_hit <= jn_scr_ok && (\$signed(scr_step) < JN_BACK);" "jn_hit <= 1'b1;" "fail:[8]"
    red "M9 a forward SCR step counts as a junction" dvd/ps_demux.sv \
        "(\$signed(scr_step) < JN_BACK)" "(scr_step != 33'd0)" "fail:[8]"
    red "M10 MPEG-2 packs decoded as MPEG-1" dvd/ps_demux.sv \
        "wire [32:0] scr_now = (scr_b[31:28] == 4'b0010)" "wire [32:0] scr_now = (1'b1)" "fail:[9]"
    red "M7 flush_ctl drops the junction row" dvd/flush_ctl.sv \
        "             lin_junction)                                 seek_flush_cnt <= 7'd64;" \
        "             1'b0)                                         seek_flush_cnt <= 7'd64;" "fail:[12] [12b]"
    rm -rf "$d"
fi

[ $fail = 0 ] && echo "run_lin_junction: ALL PASS" || { echo "run_lin_junction: FAILURES"; exit 1; }
