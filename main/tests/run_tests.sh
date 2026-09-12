#!/usr/bin/env bash
#
# run_tests.sh — host-side tests for the MiSTer_DVDcss overlay modules.
#
# These are ordinary native builds: no ARM toolchain, no MiSTer, no Docker. Each
# test #includes the module under test and stubs the rest of Main at link time,
# so it exercises the real logic rather than a paraphrase of it.
#
#   ./run_tests.sh          GREEN only
#   ./run_tests.sh --red    + mutations, each caught by the test written for it
#
set -e
cd "$(dirname "$0")"

RED=0
[ "${1:-}" = "--red" ] && RED=1

CXX="${CXX:-g++}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Stage the overlay where its own relative includes resolve. dvd_phys.cpp reaches
# for "../../user_io.h"; an EMPTY file there is deliberate -- the test defines the
# handful of Main functions it needs before including the module, so they are
# already in scope and there is no second copy of Main's API to drift out of date.
TREE="$OUT/tree"
mkdir -p "$TREE/support/dvd"
cp ../support/dvd/*.cpp ../support/dvd/*.h "$TREE/support/dvd/"
: > "$TREE/user_io.h"
: > "$TREE/menu.h"
: > "$TREE/video.h"
: > "$TREE/cfg.h"
: > "$TREE/hardware.h"

fail=0
for t in *_test.cpp; do
    n="${t%.cpp}"
    echo "### $n"
    "$CXX" -std=c++11 -Wall -Wno-unused-function -O0 -g \
        -I "$TREE/support/dvd" -o "$OUT/$n" "$t"
    "$OUT/$n" || fail=1
    echo
done

# ---------------------------------------------------------------------------
# RED arm. A decision table is exactly the shape that passes without proving
# anything, so each mutation must be caught BY ITS OWN test -- one caught only by
# some unrelated assertion leaves the intended arm vacuous. A mutation that fails
# to COMPILE is a harness failure, not a pass: it proves nothing about the test.
red_case() {
    local mod="$1" test="$2" expect="$3" sedexpr="$4" name="$5"
    local dir="$OUT/red_$name"
    cp -r "$TREE" "$dir"
    sed "$sedexpr" "$TREE/support/dvd/$mod" > "$dir/support/dvd/$mod"
    if cmp -s "$TREE/support/dvd/$mod" "$dir/support/dvd/$mod"; then
        echo "  !! RED $name: mutation matched nothing (the anchor moved)"; fail=1; return
    fi
    if ! "$CXX" -std=c++11 -Wall -Wno-unused-function -O0 -g \
            -I "$dir/support/dvd" -o "$dir/bin" "$test" 2>"$dir/build.log"; then
        echo "  !! RED $name: mutant did not compile"; sed -n '1,4p' "$dir/build.log"
        fail=1; return
    fi
    local log="$dir/log"
    "$dir/bin" > "$log" 2>&1 && { echo "  !! RED $name: test PASSED against broken code"; fail=1; return; }
    if ! grep -q "$expect" "$log"; then
        echo "  !! RED $name: caught, but not by \"$expect\""
        grep "FAIL" "$log" | head -3; fail=1
    else
        echo "  RED $name -> caught by \"$expect\""
    fi
}

if [ "$RED" -eq 1 ]; then
    echo "### RED arm"

    # The reported bug itself: nothing restores the transmitter, so the next core
    # inherits a non-PCM link and plays silently.
    red_case dvd_hdmi_audio.cpp dvd_hdmi_audio_test.cpp \
        "teardown did not write the PCM registers" \
        "s/\tif (!chip_nonpcm) return;/\treturn;/" teardown-noop

    # Teardown keyed on the ack instead of the chip. Correct everywhere EXCEPT the
    # 50 ms release window, where the ack is already down and the chip is not --
    # which is the whole reason chip_nonpcm exists as a separate flag.
    red_case dvd_hdmi_audio.cpp dvd_hdmi_audio_test.cpp \
        "chip after teardown in the window" \
        "s/\tif (!chip_nonpcm) return;/\tif (!acked) return;/" teardown-keyed-on-ack

    # Ignore the version flag: an idle v2 core reads as "not PCM" and the link is
    # claimed with nothing playing -- the shipped behaviour this fixes.
    red_case dvd_hdmi_audio.cpp dvd_hdmi_audio_test.cpp \
        "chip left in PCM" \
        "s/return core_fmt_v2 ? core_bs_session : !core_pcm_session;/return !core_pcm_session;/" \
        ignores-fmt-version

    # ...and the other way: assume every core reports bs_session, and a core built
    # before it can never engage at all.
    red_case dvd_hdmi_audio.cpp dvd_hdmi_audio_test.cpp \
        "acked (old core still engages)" \
        "s/core_fmt_v2      = (fmt >> 15) \& 1;/core_fmt_v2      = 1;/" assumes-fmt-version
    echo
fi

if [ "$fail" != 0 ]; then echo "main/tests: FAILURES"; exit 1; fi
echo "main/tests: ALL GREEN"
