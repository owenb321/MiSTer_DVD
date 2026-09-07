#!/usr/bin/env bash
# run_aud_boost.sh -- gate for the framework core-audio boost in sys/audio_out.sv.
#
#   GREEN arm: the shipped file must pass aud_boost_tb (all 65,536 input codes
#              per boost setting).
#   RED   arm: a copy of the file with UPSTREAM's constants restored (the `+ 1`
#              in boost_x, and no saturation between the unsigned curve and the
#              signed sample) must FAIL -- otherwise the bench proves nothing
#              about the defect it exists to catch.
#
# The RED arm is what stops this becoming a bench-that-cannot-fail: the checks
# are properties of the transfer curve, so they have to be shown to actually
# reject the broken curve.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TB=bench/dvd/aud_boost_tb.sv
SRC=sys/audio_out.sv
TMP=bench/dvd/.aud_boost_red.sv
rc=0

echo "=== [GREEN] shipped sys/audio_out.sv ==="
iverilog -g2012 -s aud_boost_tb -o bench/dvd/aud_boost_sim "$SRC" "$TB" 2>&1 \
    | grep -v "Static variable initialization" || true
if vvp bench/dvd/aud_boost_sim; then
    echo "    GREEN ok"
else
    echo "    *** GREEN FAILED -- the shipped boost curve is broken ***"
    rc=1
fi

echo
echo "=== [RED] upstream constants (boost_x + 1, no saturation) ==="
# Restore upstream's off-by-one and drop the clamp, so v1 truncates 17->16 bits
# exactly as upstream's 16-bit assignment does.
sed -e 's|^localparam boost_x1 = ((32767 \* (boost_f1 - 1)) / ((boost_f1 \* boost_a1) - 1));|localparam boost_x1 = ((32767 * (boost_f1 - 1)) / ((boost_f1 * boost_a1) - 1)) + 1;|' \
    -e 's|^localparam boost_x2 = ((32767 \* (boost_f2 - 1)) / ((boost_f2 \* boost_a2) - 1));|localparam boost_x2 = ((32767 * (boost_f2 - 1)) / ((boost_f2 * boost_a2) - 1)) + 1;|' \
    -e "s|^wire \[15:0\] boost_sat   = (boost_curve > 17'd32767) ? 16'd32767 : boost_curve\[15:0\];|wire [15:0] boost_sat   = boost_curve[15:0];|" \
    "$SRC" > "$TMP"

if ! grep -q '1)) + 1;' "$TMP"; then
    echo "    *** RED SETUP FAILED: could not restore the upstream constants."
    echo "        The sed patterns no longer match $SRC -- fix them, do not skip the arm."
    rc=1
else
    iverilog -g2012 -s aud_boost_tb -o bench/dvd/aud_boost_red_sim "$TMP" "$TB" 2>&1 \
        | grep -v "Static variable initialization" || true
    if vvp bench/dvd/aud_boost_red_sim > bench/dvd/.aud_boost_red.log 2>&1; then
        echo "    *** RED PASSED -- the bench does NOT catch the upstream overflow ***"
        rc=1
    else
        echo "    RED fails as expected:"
        grep -E "FAIL|peaks" bench/dvd/.aud_boost_red.log | head -6 | sed 's/^/      /'
    fi
fi
rm -f "$TMP"

echo
if [ "$rc" -eq 0 ]; then echo "run_aud_boost.sh: ALL GREEN"; else echo "run_aud_boost.sh: FAILURES"; fi
exit $rc
