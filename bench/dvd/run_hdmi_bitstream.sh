#!/usr/bin/env bash
# Suite for the IEC 61937 bitstream outputs (optical S/PDIF + HDMI).
#
# Also the first runner iec61937_wrap_tb has ever had - it was run by hand from
# docs/iec61937.md, which is how a TB quietly rots. `set -e` plus explicit exit
# checks matter here: CLAUDE.md records vvp exit-0 masking hiding failing
# testbenches for weeks after the M17 DRC change.
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

# 61937 burst assembly + the S/PDIF channel-status block + the HDMI pair tap
run iec61937_wrap dvd/spdif_pass.sv dvd/hdmi_bs_i2s.sv sys/i2s.v dvd/iec61937_wrap.sv \
    bench/dvd/iec61937_wrap_tb.sv


# ---------------------------------------------------------------------------
# RED arm. The bench INSTANTIATES iec61937_wrap, so it cannot mutate the module
# under test from the inside -- the mutation is a sed'd COPY compiled in its place
# (the csync_field_tb pattern). Two properties, not one: the mutation must be
# caught, and caught by the test written for it.
red_case() {
    local name="$1" expect="$2" sedexpr="$3"
    local dir; dir=$(mktemp -d)
    sed "$sedexpr" dvd/iec61937_wrap.sv > "$dir/iec61937_wrap.sv"
    if cmp -s dvd/iec61937_wrap.sv "$dir/iec61937_wrap.sv"; then
        echo "  !! RED $name: mutation matched nothing (the anchor moved)"
        fail=1; rm -rf "$dir"; return
    fi
    if ! iverilog -g2012 -o "$dir/sim" dvd/spdif_pass.sv dvd/hdmi_bs_i2s.sv sys/i2s.v \
            "$dir/iec61937_wrap.sv" bench/dvd/iec61937_wrap_tb.sv 2>"$dir/build.log"; then
        echo "  !! RED $name: mutant did not compile"; sed -n '1,4p' "$dir/build.log"
        fail=1; rm -rf "$dir"; return
    fi
    vvp "$dir/sim" > "$dir/log" 2>&1 || true
    if grep -q "ALL TESTS PASSED" "$dir/log"; then
        echo "  !! RED $name: bench PASSED against broken RTL"; fail=1
    elif ! grep -q "$expect" "$dir/log"; then
        echo "  !! RED $name: caught, but not by $expect"; fail=1
    else
        echo "  RED $name -> caught by $expect"
    fi
    rm -rf "$dir"
}

if [ "$RED" -eq 1 ]; then
    echo
    echo "=== RED arm"
    # The pre-existing defect: pop the descriptor, strand the payload, desync
    # audio_ring's two pointers for the rest of the title.
    red_case no-payload-drain "FAIL: LPCM payload not drained" \
        '/LPCM\/unknown -> not wrappable/,/S_SKIP;/ s/bytes_left  <= frame_len;/bytes_left  <= 16'"'"'d0;/'
    # The PCM path must not still be flagged as a data burst: PCM into a sink that
    # expects non-PCM is full-scale noise, which is the worst failure here.
    red_case pcm-flagged-nonpcm "FAIL: PCM mode still flags the stream non-PCM" \
        "s/cur_pair <= pcm_mode  ? {1'b0, pcm_hold}/cur_pair <= pcm_mode  ? {1'b1, pcm_hold}/"
    # Remove the PCM-mode gate on the HDMI serializer: an older Main leaves the ack
    # up, so real samples would be clocked into a sink expecting a data burst.
    red_case hdmi-carries-pcm "FAIL: PCM samples reach the HDMI serializer" \
        "s/wire \[31:0\] hdmi_pair = pcm_mode ? 32'd0 : cur_pair\[31:0\];/wire [31:0] hdmi_pair = cur_pair[31:0];/"
fi

if [ "$fail" -ne 0 ]; then echo; echo "SUITE FAILED"; exit 1; fi
echo; echo "SUITE PASSED"
