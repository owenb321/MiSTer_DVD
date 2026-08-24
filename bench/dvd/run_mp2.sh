#!/usr/bin/env bash
# run_mp2.sh — MP2 decoder verification suite.
#
# Generates fixtures (ffmpeg + tools/mp2_ref.py, all regenerable — nothing
# committed), then runs:
#   1. mp2_ref.py selftest + SNR compare vs ffmpeg float decode (model gate)
#   2. mp2_decode_tb  — RTL BIT-EXACT vs the model, per fixture
#   3. mp2_reframer_tb
#
# Optional: set MP2_REAL=<file.mp2> to also run a real-content fixture
# (e.g. an ES extracted from a VCD rip — not committed, machine-local).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

FIX=bench/dvd/test_mp2
mkdir -p "$FIX"
rc=0

gen_fix () {  # name, ffmpeg-source-args..., frames
    local name="$1"; shift
    local frames="$1"; shift
    if [ ! -f "$FIX/$name.mp2" ]; then
        ffmpeg -y -loglevel error "$@" "$FIX/$name.mp2"
    fi
    python3 tools/mp2_ref.py fixture "$FIX/$name.mp2" "$FIX/$name" --frames "$frames"
}

echo "== model selftest =="
python3 tools/mp2_ref.py selftest

echo "== fixtures =="
# DVD-spec: 48 kHz stereo 224k (sine sweep exercises many subbands)
gen_fix tone48 20 \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=1" \
    -f lavfi -i "sine=frequency=3000:sample_rate=48000:duration=1" \
    -filter_complex "[0:a][1:a]amerge=inputs=2[a]" -map "[a]" \
    -c:a mp2 -ar 48000 -ac 2 -b:a 224k -f mp2
# white noise stresses high subbands + big scalefactor spread
gen_fix noise48 12 \
    -f lavfi -i "anoisesrc=colour=white:sample_rate=48000:duration=0.5:amplitude=0.5" \
    -ac 2 -c:a mp2 -ar 48000 -b:a 384k -f mp2
# mono 48 kHz (mono duplication path)
gen_fix mono48 12 \
    -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=0.5" \
    -ac 1 -c:a mp2 -ar 48000 -b:a 96k -f mp2
# 44.1 kHz (VCD rate: different alloc table + frame length)
gen_fix tone441 12 \
    -f lavfi -i "sine=frequency=1000:sample_rate=44100:duration=0.5" \
    -ac 2 -c:a mp2 -ar 44100 -b:a 224k -f mp2
# low rate -> table 3-B.2c (8 subbands)
gen_fix low48 12 \
    -f lavfi -i "sine=frequency=300:sample_rate=48000:duration=0.5" \
    -ac 2 -c:a mp2 -ar 48000 -b:a 64k -f mp2

echo "== model vs ffmpeg SNR =="
for f in tone48 noise48 mono48 tone441 low48; do
    python3 tools/mp2_ref.py compare "$FIX/$f.mp2" --frames 20 || rc=1
done

echo "== RTL bit-exact cosim =="
iverilog -g2012 -I dvd/ac3 -o bench/dvd/mp2_decode_sim \
    dvd/mp2/mp2_decode.sv dvd/ac3/bit_fifo.sv dvd/ac3/bit_reader.sv \
    bench/dvd/mp2_decode_tb.sv
for f in tone48 noise48 mono48 tone441 low48; do
    echo "-- $f"
    vvp bench/dvd/mp2_decode_sim +FIXDIR="$FIX/$f" || rc=1
done

if [ -n "${MP2_REAL:-}" ]; then
    echo "== real-content fixture ($MP2_REAL) =="
    python3 tools/mp2_ref.py fixture "$MP2_REAL" "$FIX/real" --frames 30
    python3 tools/mp2_ref.py compare "$MP2_REAL" --frames 30 || rc=1
    vvp bench/dvd/mp2_decode_sim +FIXDIR="$FIX/real" || rc=1
fi

echo "== reframer =="
iverilog -g2012 -o bench/dvd/mp2_reframer_sim dvd/mp2_reframer.sv bench/dvd/mp2_reframer_tb.sv
vvp bench/dvd/mp2_reframer_sim || rc=1

if [ $rc -eq 0 ]; then echo "ALL MP2 TESTS PASS"; else echo "MP2 SUITE FAILED"; fi
exit $rc
