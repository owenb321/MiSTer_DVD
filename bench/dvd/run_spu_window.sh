#!/usr/bin/env bash
# run_spu_window.sh — the SPU display-order gate (PR #63 regression).
#
# GREEN: bench/dvd/spu_window_tb.sv against the shipping module.
# RED  : three sed-mutated copies, because a bench cannot mutate a module it
#        instantiates. Each mutation removes ONE half of the fix and must be
#        caught by the arm that half exists for -- a fix whose removal no arm
#        notices is not gated, it is just present.
#          red-clamp : the contiguity clamp  -> [A] the icon must blink again
#          red-hold  : the display-order hold -> [B] the subtitle must truncate
#          red-both  : the pre-#63 behaviour   -> both
# Also re-runs spu_decode_tb, which must pass UNCHANGED: it is the evidence that
# the golden-model bitmap, the menu path and the spec-max/over-spec handling are
# untouched.
set -u
cd "$(dirname "$0")/../.."
fail=0
iv() { iverilog -g2012 -I rtl/mpeg2 -o "$1" "${@:2}"; }

echo "== GREEN: shipping module =="
if iv /tmp/spu_win_green dvd/spu_decode.sv bench/dvd/spu_window_tb.sv \
   && vvp /tmp/spu_win_green | tee /tmp/spu_win_green.log | grep -q "RESULT: PASS"; then
    sed -n 's/^  \[/  [/p' /tmp/spu_win_green.log
    echo "  PASS spu_window"
else
    echo "  FAIL spu_window (green)"; tail -20 /tmp/spu_win_green.log; fail=1
fi

echo "== GREEN: spu_decode_tb must be unchanged =="
if iv /tmp/spu_dec_green dvd/spu_decode.sv bench/dvd/spu_decode_tb.sv \
   && vvp /tmp/spu_dec_green | grep -q "RESULT: PASS"; then echo "  PASS spu_decode"
else echo "  FAIL spu_decode"; fail=1; fi

red() {   # name  sed-script  expected-failing-arm
    local name=$1 script=$2 arm=$3
    local d; d=$(mktemp -d)
    sed "$script" dvd/spu_decode.sv > "$d/spu_decode.sv"
    if cmp -s "$d/spu_decode.sv" dvd/spu_decode.sv; then
        echo "  FAIL $name: the mutation did not apply (anchor moved)"; fail=1
    elif ! iv "$d/sim" "$d/spu_decode.sv" bench/dvd/spu_window_tb.sv 2>"$d/build"; then
        # A mutation that does not COMPILE proves nothing about the bench.
        echo "  FAIL $name: the mutated module did not build"; sed 's/^/      /' "$d/build"
        fail=1
    elif vvp "$d/sim" > "$d/log" 2>&1 && grep -q "RESULT: PASS" "$d/log"; then
        echo "  FAIL $name: the bench PASSED without the fix (arm $arm proves nothing)"
        fail=1
    else
        echo "  PASS $name (expected arm $arm; caught $(grep -c 'FAIL \[' "$d/log"))"
        grep 'FAIL \[' "$d/log" | sed 's/^/      /'
    fi
    rm -rf "$d"
}

if [ "${1:-}" = "--red" ]; then
    echo "== RED arms =="
    red red-clamp 's|c_show  <= (spu_contig \&\& !spu_due) ? stc : w_show_eff;|c_show  <= w_show_eff;|' A
    red red-hold  's|if (c_valid \&\& !spu_due \&\& !menu_mode) state <= S_HOLD;|if (menu_mode \&\& !menu_mode) state <= S_HOLD;|' B
    red red-both  's|c_show  <= (spu_contig \&\& !spu_due) ? stc : w_show_eff;|c_show  <= w_show_eff;|; s|if (c_valid \&\& !spu_due \&\& !menu_mode) state <= S_HOLD;|if (menu_mode \&\& !menu_mode) state <= S_HOLD;|' A+B
fi

[ $fail -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit $fail
