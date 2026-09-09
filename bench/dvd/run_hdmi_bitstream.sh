#!/usr/bin/env bash
# Suite for the IEC 61937 bitstream outputs (optical S/PDIF + HDMI).
#
# Also the first runner iec61937_wrap_tb has ever had - it was run by hand from
# docs/iec61937.md, which is how a TB quietly rots. `set -e` plus explicit exit
# checks matter here: CLAUDE.md records vvp exit-0 masking hiding failing
# testbenches for weeks after the M17 DRC change.
#
#   ./bench/dvd/run_hdmi_bitstream.sh         GREEN only
#   ./bench/dvd/run_hdmi_bitstream.sh --red   + 5 mutations, each of which must
#                                             be caught by its own named test
set -euo pipefail

cd "$(dirname "$0")/../.."
OUT=bench/dvd
fail=0
RED=0
[ "${1:-}" = "--red" ] && RED=1

SRCS=(dvd/spdif_pass.sv dvd/hdmi_bs_i2s.sv sys/i2s.v dvd/iec61937_wrap.sv)
TB=bench/dvd/iec61937_wrap_tb.sv

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

# 61937 burst assembly + the S/PDIF channel-status block + the HDMI pair tap
run iec61937_wrap "${SRCS[@]}" "$TB"

# ---------------------------------------------------------------------------
# RED arm. The bench INSTANTIATES iec61937_wrap, so it cannot mutate the module
# under test from the inside - each mutation is a sed'd COPY compiled in its
# place (the csync_field_tb pattern). Two properties are checked, not one: the
# mutation must be caught, and it must be caught by the test written for it. A
# mutation caught only by some unrelated assertion means the intended test is
# still vacuous, which is the whole failure mode this branch exists to fix.
red_case() {
    local name="$1" expect="$2" sedexpr="$3"
    local dir; dir=$(mktemp -d)
    sed "$sedexpr" dvd/iec61937_wrap.sv > "$dir/iec61937_wrap.sv"
    if cmp -s dvd/iec61937_wrap.sv "$dir/iec61937_wrap.sv"; then
        echo "  !! RED $name: mutation matched nothing (the anchor moved)"
        fail=1; rm -rf "$dir"; return
    fi
    if ! iverilog -g2012 -o "$dir/sim" dvd/spdif_pass.sv dvd/hdmi_bs_i2s.sv sys/i2s.v \
            "$dir/iec61937_wrap.sv" "$TB" 2>"$dir/build.log"; then
        # A mutant that does not compile is not evidence of anything.
        echo "  !! RED $name: mutant did not compile"; sed -n '1,4p' "$dir/build.log"
        fail=1; rm -rf "$dir"; return
    fi
    vvp "$dir/sim" > "$dir/log" 2>&1 || true
    if grep -q "ALL TESTS PASSED" "$dir/log"; then
        echo "  !! RED $name: bench PASSED against broken RTL"; fail=1
    elif ! grep -q "$expect" "$dir/log"; then
        echo "  !! RED $name: caught, but not by $expect"
        grep -E '^  FAIL' "$dir/log" | head -3; fail=1
    else
        echo "  RED $name -> caught by $expect"
    fi
    rm -rf "$dir"
}

if [ "$RED" -eq 1 ]; then
    echo
    echo "=== RED arm"

    # 1. THE retracted defect (docs/iec61937.md:243-251): session state clocked
    #    off rst_sys_n, so a seek or an audio-track switch disarms the fill in
    #    precisely the two windows it exists for.
    red_case session-on-rst_sys_n "FAIL: session disarmed by a track switch" \
        's/negedge rst_sess_n) begin/negedge rst_sys_n) begin/; s/if (!rst_sess_n) begin/if (!rst_sys_n) begin/'

    # 2. The pre-existing byte-drain defect: pop the descriptor, strand the
    #    payload, desync audio_ring's two pointers for the rest of the title.
    red_case no-payload-drain "FAIL: LPCM payload not drained" \
        '/LPCM\/unknown -> not wrappable/,/S_SKIP;/ s/bytes_left  <= frame_len;/bytes_left  <= 16'"'"'d0;/'

    # 3. Pa/Pb suppressed on a pause burst - the receiver has no preamble to
    #    find it by, which is what a width-only check would have missed.
    red_case pause-without-preamble "FAIL pause-Pa" \
        's/burst_silent<= ~fill_pause;/burst_silent<= 1'"'"'b1;/'

    # 4. The fill drops the non-PCM flag, so the format re-negotiates per gap.
    red_case fill-drops-nonpcm "FAIL: fill 1 dropped the non-PCM flag" \
        's/cur_nonpcm  <= fill_nonpcm;/cur_nonpcm  <= 1'"'"'b0;/'

    # 5. Burst period reset per track switch - the Pa/Pb grid jumps 512 -> 1536
    #    on the first gap after a track change inside a DTS title.
    red_case period-on-rst_sys_n "FAIL: burst period reverted" \
        's/pc_val      <= PC_AC3;$/pc_val      <= PC_AC3; cur_period <= PERIOD_AC3;/'
fi

if [ "$fail" -ne 0 ]; then echo; echo "SUITE FAILED"; exit 1; fi
echo; echo "SUITE PASSED"
