#!/usr/bin/env bash
# run_vcd.sh — VCD/SVCD playback verification suite.
#
# Uses the COMMITTED real-VCD fixtures (bench/dvd/test_vobs/vcd_*.hex,
# svcd_slice*.hex — regenerate with tools/vcd_fixtures.py) and generates the
# PCM golden for the audio chain via tools/mp2_ref.py (gitignored).
#
# Runs:
#   1. iso_reader_raw_tb  — raw MODE2/2352 detect + deblock, byte-exact
#   2. ps_demux_m1_tb     — MPEG-1 system-stream demux, byte-exact + PTS
#   3. vcd_chain_tb       — full chain (deblocked PS -> ps_demux -> reframers
#                           -> ring -> dvd_audio_decode), PCM BIT-EXACT vs
#                           mp2_ref.py + 44.1 kHz NCO checks; free-run AND
#                           +SCHED (real drain gate) modes

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

FIX=bench/dvd/test_mp2/vcdchain
rc=0

echo "== PCM golden (real VCD audio ES -> mp2_ref.py) =="
mkdir -p bench/dvd/test_mp2
python3 - <<'PYEOF'
# vcd_mid.aes.hex (committed, one hex byte per line) -> binary .mp2
data = bytes(int(l, 16) for l in open('bench/dvd/test_vobs/vcd_mid.aes.hex') if l.strip())
open('bench/dvd/test_mp2/vcdchain.mp2', 'wb').write(data)
print(f"audio ES: {len(data)} bytes")
PYEOF
python3 tools/mp2_ref.py fixture bench/dvd/test_mp2/vcdchain.mp2 "$FIX" --frames 24

echo "== 1. raw MODE2/2352 reader =="
iverilog -g2012 -o bench/dvd/iso_reader_raw_sim \
    dvd/dvd_iso_reader.sv dvd/bcd_time_add.sv bench/dvd/iso_reader_raw_tb.sv
vvp bench/dvd/iso_reader_raw_sim | tail -8 || rc=1

echo "== 2. MPEG-1 system-stream demux =="
iverilog -g2012 -o bench/dvd/ps_demux_m1_sim \
    dvd/ps_demux.sv bench/dvd/ps_demux_m1_tb.sv
vvp bench/dvd/ps_demux_m1_sim | tail -4 || rc=1

echo "== 3. full chain (free-run) =="
iverilog -g2012 -I dvd/ac3 -o bench/dvd/vcd_chain_sim \
    dvd/ps_demux.sv dvd/ac3_reframer.sv dvd/dts_reframer.sv dvd/mp2_reframer.sv \
    dvd/audio_ring.sv dvd/dvd_audio_decode.sv dvd/lpcm_unpack.sv \
    dvd/mp2/mp2_decode.sv dvd/ac3/*.sv bench/dvd/vcd_chain_tb.sv 2>/dev/null
vvp bench/dvd/vcd_chain_sim | tail -4 || rc=1

echo "== 3b. full chain (+SCHED drain-gate mode) =="
vvp bench/dvd/vcd_chain_sim +SCHED | tail -4 || rc=1

if [ $rc -eq 0 ]; then echo "ALL VCD TESTS PASS"; else echo "VCD SUITE FAILED"; fi
exit $rc
