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
run iec61937_wrap dvd/spdif_pass.sv dvd/i2s_iec958.sv dvd/iec61937_wrap.sv \
    bench/dvd/iec61937_wrap_tb.sv

# IEC958-direct serialization for the ADV7513's I2S input, read back off the wire
run i2s_iec958 dvd/spdif_pass.sv dvd/i2s_iec958.sv bench/dvd/i2s_iec958_tb.sv

if [ "$fail" -ne 0 ]; then echo; echo "SUITE FAILED"; exit 1; fi
echo; echo "SUITE PASSED"
