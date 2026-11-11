#!/usr/bin/env bash
# Forced subtitles (docs/subpicture.md "Forced subtitles"; PR #151).
#
#   bench/dvd/run_forced_subs.sh          GREEN: the forced bench + every spu_decode bench
#   bench/dvd/run_forced_subs.sh --red    + mutation arms: each must fail EXACTLY its arms
#
# The emu.sv seam (which stream is routed, and when forced_only is asserted) has no
# bench -- tools/check_forced_subs_wiring.py reads it out of the file and runs first.
set -u
cd "$(dirname "$0")/../.."
fail=0
SIM=$(mktemp -d)
trap 'rm -rf "$SIM"' EXIT
iv() { iverilog -g2012 -I rtl/mpeg2 -o "$1" "${@:2}"; }

echo "== emu.sv wiring: forced route + forced_only =="
if python3 tools/check_forced_subs_wiring.py; then :; else fail=1; fi

echo "== GREEN: forced-subtitle arms =="
if iv "$SIM/forced" dvd/spu_decode.sv bench/dvd/spu_forced_tb.sv \
   && vvp "$SIM/forced" > "$SIM/forced.log" 2>&1 && grep -q "RESULT: PASS" "$SIM/forced.log"; then
    grep '^  \[F' "$SIM/forced.log"; echo "  PASS spu_forced"
else
    echo "  FAIL spu_forced"; tail -20 "$SIM/forced.log"; fail=1
fi

echo "== GREEN: every other spu_decode bench must be unchanged =="
# (spu_col_tb is not listed: it needs a +hex= plusarg from its co-sim driver and
#  fails without one on main too.)
for tb in spu_decode_tb spu_decode_480i_tb spu_window_tb spu_newcell_tb; do
    if iv "$SIM/$tb" dvd/spu_decode.sv "bench/dvd/$tb.sv" 2>"$SIM/$tb.build" \
       && vvp "$SIM/$tb" 2>&1 | grep -q "RESULT: PASS"; then echo "  PASS $tb"
    else echo "  FAIL $tb"; cat "$SIM/$tb.build"; fail=1; fi
done

red() {   # name  sed-script  expected-arms (space separated, e.g. "F1 F5")
    local name=$1 script=$2 want=$3
    local d; d=$(mktemp -d)
    sed "$script" dvd/spu_decode.sv > "$d/spu_decode.sv"
    if cmp -s "$d/spu_decode.sv" dvd/spu_decode.sv; then
        echo "  FAIL $name: the mutation did not apply (anchor moved)"; fail=1
    elif ! iv "$d/sim" "$d/spu_decode.sv" bench/dvd/spu_forced_tb.sv 2>"$d/build"; then
        echo "  FAIL $name: the mutated module did not build"; sed 's/^/      /' "$d/build"; fail=1
    else
        vvp "$d/sim" > "$d/log" 2>&1
        local got
        got=$(grep -o 'FAIL \[F[0-9]\]' "$d/log" | sed 's/FAIL \[\(F[0-9]\)\]/\1/' | sort -u | tr '\n' ' ' | sed 's/ $//')
        if grep -q "RESULT: PASS" "$d/log"; then
            echo "  FAIL $name: the bench PASSED with the mutation (want $want)"; fail=1
        elif [ "$got" != "$want" ]; then
            echo "  FAIL $name: tripped [$got], want exactly [$want]"; fail=1
        else
            echo "  PASS $name (tripped exactly [$got])"
        fi
    fi
    rm -rf "$d"
}

if [ "${1:-}" = "--red" ]; then
    echo "== RED arms =="
    # FSTA_DSP no longer marks the unit forced -> the forced unit is hidden
    red red-noflag   's|w_forced   <= 1'"'"'b1;|w_forced   <= 1'"'"'b0;|' "F3"
    # the per-unit reset is gone -> a forced unit's flag sticks to the next unit
    red red-sticky   's|^\( *\)w_forced   <= 1'"'"'b0;$|\1// (mutated out)|' "F5"
    # STA_DSP also marks the unit forced -> every unit shows under forced_only
    red red-01forced 's|// STA_DSP -> show$|// STA_DSP -> show\n                        w_forced <= 1'"'"'b1;|' "F1 F5"
    # the visibility gate ignores forced_only -> nothing is ever hidden by it
    red red-nogate   's|(!forced_only \|\| c_forced) \&\&||' "F1 F5"

    # emu.sv seam (issue #178): each mutation must fail the wiring check on exactly its item
    red_emu() {   # name  sed-script  expected-item (e.g. "3b.")
        local name=$1 script=$2 want=$3
        local d; d=$(mktemp -d)
        sed "$script" dvd/emu.sv > "$d/emu.sv"
        if cmp -s "$d/emu.sv" dvd/emu.sv; then
            echo "  FAIL $name: the mutation did not apply (anchor moved)"; fail=1
        else
            local got
            got=$(python3 tools/check_forced_subs_wiring.py "$d/emu.sv" | grep -o '^  [0-9]*b*\.' | tr -d ' ' | sort -u | tr '\n' ' ' | sed 's/ $//')
            if [ "$got" != "$want" ]; then
                echo "  FAIL $name: check tripped [$got], want exactly [$want]"; fail=1
            else
                echo "  PASS $name (tripped exactly [$got])"
            fi
        fi
        rm -rf "$d"
    }
    # the armed in-title button is a display-on term again -> SDH shows with SUB OFF
    red_emu red-hli-disp 's/^\( *\)| sp_menu_early;$/\1| in_title_hli | sp_menu_early;/' "3b."
    # ...or by its definition rather than its name
    red_emu red-hli-armed 's/^\( *\)| sp_menu_early;$/\1| hl_btns_armed | sp_menu_early;/' "3b."
    # Scene It's pre-arm falls out of the display-on terms -> its menus go forced-only
    red_emu red-no-early 's/^\( *\)| sp_menu_early;$/\1;/' "3."
fi

[ $fail -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit $fail
