#!/usr/bin/env bash
# Suite for LPCM/MP2 as PCM in Passthru: the audio_ring read-side arbiter, and
# the wrapper's PCM path.
#
#   ./bench/dvd/run_passthru_pcm.sh         GREEN only
#   ./bench/dvd/run_passthru_pcm.sh --red   + mutations, each caught by its own test
set -euo pipefail

cd "$(dirname "$0")/../.."
OUT=bench/dvd
fail=0
RED=0
[ "${1:-}" = "--red" ] && RED=1

run() {
    local name="$1"; shift
    echo "=== $name"
    iverilog -g2012 -o "$OUT/${name}_sim" "$@"
    if ! vvp "$OUT/${name}_sim" | tee "$OUT/${name}.log" | tail -3; then
        echo "  !! $name: vvp returned non-zero"; fail=1; return
    fi
    # vvp exits 0 even on $fatal in some builds - check the text too.
    if grep -qE 'FAIL|FAILURES|TIMEOUT|ERROR' "$OUT/${name}.log"; then
        echo "  !! $name: failure text in log"; fail=1
    fi
}

run aud_route dvd/aud_route.sv bench/dvd/aud_route_tb.sv

# ---------------------------------------------------------------------------
# RED arm. The bench instantiates the module, so each mutation is a sed'd copy
# compiled in its place. Two properties: the mutation must be caught, and caught
# by the test written for it -- a mutation caught only by some unrelated
# assertion leaves the intended test vacuous.
red_case() {
    local name="$1" expect="$2" sedexpr="$3"
    local dir; dir=$(mktemp -d)
    sed "$sedexpr" dvd/aud_route.sv > "$dir/aud_route.sv"
    if cmp -s dvd/aud_route.sv "$dir/aud_route.sv"; then
        echo "  !! RED $name: mutation matched nothing (the anchor moved)"
        fail=1; rm -rf "$dir"; return
    fi
    if ! iverilog -g2012 -o "$dir/sim" "$dir/aud_route.sv" \
            bench/dvd/aud_route_tb.sv 2>"$dir/build.log"; then
        echo "  !! RED $name: mutant did not compile"; sed -n '1,4p' "$dir/build.log"
        fail=1; rm -rf "$dir"; return
    fi
    timeout 120 vvp "$dir/sim" > "$dir/log" 2>&1 || true
    if grep -q "ALL TESTS PASSED" "$dir/log"; then
        echo "  !! RED $name: bench PASSED against broken RTL"; fail=1
    elif ! grep -q "$expect" "$dir/log"; then
        echo "  !! RED $name: caught, but not by \"$expect\""
        grep -E '^  FAIL|TIMEOUT' "$dir/log" | head -3; fail=1
    else
        echo "  RED $name -> caught by \"$expect\""
    fi
    rm -rf "$dir"
}

if [ "$RED" -eq 1 ]; then
    echo
    echo "=== RED arm"

    # 1. Release the grant after one byte instead of at the end of the payload --
    #    the defect the module exists to prevent. The other consumer interleaves
    #    into the middle of a frame and rd_ptr is left inside it.
    red_case release-mid-payload "payload taken by the other consumer" \
        "s/if (bytes_left == 16'd1) st <= S_IDLE;/st <= S_IDLE;/"

    # 2. Route by nothing: everything to the bitstream path. This is the state
    #    before the feature, so an LPCM disc stays silent.
    red_case route-everything-to-wrap "PCM frames misrouted" \
        "s/wire take_wrap   = take \&\& split_en \&\& is_bitstream;/wire take_wrap   = take \&\& split_en;/"

    # 3. pcm_session follows the head combinationally instead of latching, so the
    #    HDMI link format would flap at every gap between frames.
    red_case pcm-session-not-latched "pcm_session dropped during a gap" \
        "s/if (split_en) pcm_session <= !is_bitstream;//"

    # 4. The take-cycle byte is not counted, so the grant is held one byte too long
    #    and the NEXT frame's first byte goes to the wrong consumer.
    red_case take-byte-uncounted "payload taken by the other consumer" \
        "s/bytes_left <= take_rem;/bytes_left <= frame_len;/"
fi

if [ "$fail" -ne 0 ]; then echo; echo "SUITE FAILED"; exit 1; fi
echo; echo "SUITE PASSED"
