#!/usr/bin/env bash
# run_wav.sh — WAV / CD-DA PCM playback verification suite (feature/wav-audio).
#
# Fixtures + PCM goldens are GENERATED here by tools/wav_ref.py into the
# gitignored bench/dvd/test_wav/ (synthetic + deterministic, so nothing large
# needs committing — the model itself is the artifact under review).
#
# Runs:
#   1. wav_probe_tb   — RIFF/WAVE probe + chunk walk + payload streaming through
#                       the REAL dvd_iso_reader: accepts byte-exact, all five
#                       reject shapes refused with zero bytes out, flat/small-
#                       file regressions, seek pair-phase alignment
#   2. cdda_audio_tb  — end-to-end reader -> dvd_audio_decode(cdda) -> AUDIO_L/R:
#                       PCM BIT-EXACT vs the golden, 44.1/48 kHz NCO cadence,
#                       pause continuity, post-seek channel-swap guard, the
#                       and the RED-first `le` proof
#   3. regressions    — the paths this feature touched must be unchanged:
#                       lpcm_unpack (DVD LPCM BE), dvd_audio_decode (AC-3+LPCM),
#                       transport_hud + hud_frame (persist_set/persist_o), and the
#                       whole VCD/MP2 suite (reader raw mode + MP2 chain)
#   4. audio CD       — cdda_toc (the track table + the skip resolver)

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
rc=0

echo "== fixtures + goldens (tools/wav_ref.py) =="
python3 tools/wav_ref.py gen bench/dvd/test_wav

echo "== 1. WAV probe + payload streaming (dvd_iso_reader) =="
iverilog -g2012 -o bench/dvd/wav_probe_sim \
    dvd/dvd_iso_reader.sv dvd/bcd_time_add.sv bench/dvd/wav_probe_tb.sv 2>/dev/null
vvp bench/dvd/wav_probe_sim | tail -18 || rc=1

echo "== 2. end-to-end PCM chain (reader -> dvd_audio_decode -> AUDIO_L/R) =="
iverilog -g2012 -I dvd/ac3 -o bench/dvd/cdda_audio_sim \
    dvd/dvd_iso_reader.sv dvd/bcd_time_add.sv dvd/dvd_audio_decode.sv \
    dvd/lpcm_unpack.sv dvd/mp2/mp2_decode.sv dvd/ac3/*.sv \
    bench/dvd/cdda_audio_tb.sv 2>/dev/null
vvp bench/dvd/cdda_audio_sim | tail -12 || rc=1

echo "== 3a. regression: lpcm_unpack (DVD LPCM big-endian path) =="
iverilog -g2012 -o bench/dvd/lpcm_sim \
    dvd/lpcm_unpack.sv bench/dvd/lpcm_unpack_tb.sv 2>/dev/null
vvp bench/dvd/lpcm_sim | tail -2 || rc=1

echo "== 3b. regression: dvd_audio_decode (AC-3 + LPCM + drain gate) =="
iverilog -g2012 -I dvd/ac3 -o bench/dvd/dad_sim \
    dvd/dvd_audio_decode.sv dvd/lpcm_unpack.sv dvd/mp2/mp2_decode.sv \
    dvd/ac3/*.sv bench/dvd/dvd_audio_decode_tb.sv 2>/dev/null
vvp bench/dvd/dad_sim | tail -2 || rc=1

echo "== 3c-pre. linear time/rate model (the CD-DA fixed-rate bypass) =="
iverilog -g2012 -o bench/dvd/lin_rate_sim \
    dvd/lin_rate.sv dvd/secs_bcd.sv bench/dvd/lin_rate_tb.sv
vvp bench/dvd/lin_rate_sim | tail -2 || rc=1

echo "== 3c-bar. progress bar (seek_bar force_show) =="
iverilog -g2012 -o bench/dvd/seek_bar_sim \
    dvd/seek_bar.sv bench/dvd/seek_bar_tb.sv
vvp bench/dvd/seek_bar_sim | tail -2 || rc=1

echo "== 3c. regression: transport HUD (persist_set / persist_o) =="
iverilog -g2012 -o bench/dvd/transport_hud_sim \
    dvd/transport_hud.sv bench/dvd/transport_hud_tb.sv 2>/dev/null
vvp bench/dvd/transport_hud_sim | tail -2 || rc=1
iverilog -g2012 -o bench/dvd/hud_frame_sim \
    dvd/transport_hud.sv dvd/subpic_blend.sv bench/dvd/hud_frame_tb.sv
vvp bench/dvd/hud_frame_sim | tail -2 || rc=1

# 4a prints a PASS/FAIL banner rather than relying on vvp's exit status.
passed() { grep -q "ALL TESTS PASSED" <<<"$1"; }

echo "== 4a. audio-CD track table (cdda_toc) =="
python3 tools/cdda_toc_ref.py bench/dvd/test_cdda >/dev/null
iverilog -g2012 -o bench/dvd/cdda_toc_sim dvd/cdda_toc.sv bench/dvd/cdda_toc_tb.sv
out=$(vvp bench/dvd/cdda_toc_sim || true); tail -2 <<<"$out"; passed "$out" || rc=1

echo "== 3d. regression: VCD/SVCD suite (reader raw mode + MP2 chain) =="
./bench/dvd/run_vcd.sh | tail -3 || rc=1

if [ $rc -eq 0 ]; then echo "ALL WAV TESTS PASS"; else echo "WAV SUITE FAILED"; fi
exit $rc
