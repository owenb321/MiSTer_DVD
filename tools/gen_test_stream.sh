#!/usr/bin/env bash
# Generate controlled AC-3 elementary streams for decoder bring-up.
#
# PoC scope target: plain AC-3, 48 kHz, acmod=2 (L/R stereo), lfeon=0, no LFE.
# We deliberately use simple, fully-understood content first (a single tone and
# silence) — one hand-understood frame beats a real VOB for first bring-up.
#
# Outputs (in tools/streams/):
#   tone_1k_48k_stereo_192k.ac3   1 kHz sine, 48k, stereo, 192 kbps
#   silence_48k_stereo_192k.ac3   digital silence, same params
#   *.ac3.hex                     one-byte-per-line hex (for $readmemh / sims)
#   *.frame0.hex                  just the first frame's bytes
#
# Notes:
#   - `-c:a ac3` is the float encoder; `-c:a ac3_fixed` is the integer encoder
#     (kept here commented — useful later if we ever want a bit-exact target).
#   - 192 kbps @ 48k => frmsizcod selects a fixed frame word count; sync_crc will
#     derive the frame length from frmsizcod and we cross-check against this.
#   - Verify params afterwards with:  ffprobe -show_streams <file>.ac3
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/tools/streams"
mkdir -p "$OUT"

SR=48000
BR=192k
COMMON=(-ac 2 -ar "$SR" -c:a ac3 -b:a "$BR" -f ac3)

echo "[gen] 1 kHz tone -> tone_1k_48k_stereo_192k.ac3"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=1000:duration=0.20:sample_rate=$SR" \
    "${COMMON[@]}" "$OUT/tone_1k_48k_stereo_192k.ac3"

echo "[gen] silence -> silence_48k_stereo_192k.ac3"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=$SR:duration=0.20" \
    "${COMMON[@]}" "$OUT/silence_48k_stereo_192k.ac3"

# Coupled hardware-listen vector (M12+): a 5 s log frequency sweep 80 Hz -> 16 kHz.
# At 192 kbps stereo ffmpeg uses channel coupling AND stereo rematrixing (cpl=1,
# rematflg=0xf) -- both in scope since M12 -- so this exercises the full coupled
# datapath end to end and is a far better listen test than a single tone (you
# hear the pitch rise smoothly).  The instantaneous phase of a log sweep is
# phi(t) = 2*PI * f0*T/ln(f1/f0) * ((f1/f0)^(t/T) - 1); with f0=80,f1=16000,T=5
# the constants fold to 474.3 and ln(200)/T = 1.05966.  NB: the OLD sweep_192k.ac3
# was a dud -- it decoded to digital silence (all-zeros, confirmed via ffmpeg),
# which read as a hardware "failure" that was really an empty vector.  Co-sim
# verified: in scope, PCM <=0.44 LSB @ s16 vs liba52.
echo "[gen] coupled sweep (5 s, hardware listen) -> sweep_192k.ac3"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "aevalsrc=exprs=0.4*sin(474.3*(exp(1.05966*t)-1)):d=5:s=$SR" \
    "${COMMON[@]}" "$OUT/sweep_192k.ac3"

# In-PoC-scope stream: band-split decorrelated stereo at the max AC-3 bitrate.
# ffmpeg uses channel coupling for stereo at typical bitrates and stereo
# rematrixing whenever L/R correlate — BOTH out of PoC scope.  640 kbps disables
# coupling; to also keep *every* block rematrix-free we make L and R occupy
# disjoint frequency bands (L = lowpass<6 kHz noise, R = highpass>8 kHz noise),
# so the encoder's sum/difference (rematrixing) coding never saves bits and is
# never selected.  Plain independent white noise per channel still trips
# rematrixing on a handful of mid-frame blocks (random short-window correlation);
# the band split is structurally decorrelated, so all 6 blocks of all 7 frames
# are in scope (chincpl==0, rematflg==0, long blocks).  This lets the full
# blocks-0..5 datapath (M10) be verified end-to-end against liba52.  Verify with:
#   /tmp/scope_probe3-style tap, or the run_front_cosim.sh per-block golden check.
echo "[gen] in-scope noise -> noise_48k_stereo_640k.ac3"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "anoisesrc=d=0.20:c=white:r=$SR:a=0.7:seed=19" \
    -f lavfi -i "anoisesrc=d=0.20:c=white:r=$SR:a=0.7:seed=119" \
    -filter_complex "[0:a]lowpass=f=6000[l];[1:a]highpass=f=8000[r];[l][r]amerge=inputs=2[a]" -map "[a]" \
    -ac 2 -ar "$SR" -c:a ac3 -b:a 640k -f ac3 "$OUT/noise_48k_stereo_640k.ac3"

# Same recipe, 5 seconds long — a HARDWARE LISTENING vector (the 0.20 s one above
# is the co-sim vector: short = fast verilator runs).  Load this over the F1
# "Load AC-3" loader on the DE10-Nano to hear sustained continuous noise: with
# the M10 real-time metering the parser consumes the ES at ~48 kHz, so ioctl_wait
# throttles the HPS download to playback rate and the file "loads" over ~5 s while
# it plays.  In scope (band-split -> no coupling/rematrix), so it actually decodes
# — unlike tone_1k / silence (192 kbps), which use coupling and fail loud.
echo "[gen] in-scope noise (5 s, hardware listen) -> noise_48k_stereo_640k_5s.ac3"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "anoisesrc=d=5.0:c=white:r=$SR:a=0.7:seed=19" \
    -f lavfi -i "anoisesrc=d=5.0:c=white:r=$SR:a=0.7:seed=119" \
    -filter_complex "[0:a]lowpass=f=6000[l];[1:a]highpass=f=8000[r];[l][r]amerge=inputs=2[a]" -map "[a]" \
    -ac 2 -ar "$SR" -c:a ac3 -b:a 640k -f ac3 "$OUT/noise_48k_stereo_640k_5s.ac3"

# --- 5.1 (acmod==7 + LFE) vectors for M14 -----------------------------------
# A 3/2 + LFE stream: ffmpeg sets acmod=7, lfeon=1.  liba52 decodes all 6
# channels (L C R Ls Rs LFE); our decoder decodes the 5 fbw channels, parses
# (and drops) LFE, and downmixes to stereo.  Two vectors:
#
#   (a) tone_5p1: a distinct sine per channel (different freq each), so every
#       decoded channel carries unique, easily-checked content.  Cosim golden-
#       checks per-channel exps/bap and the stereo downmix vs liba52 A52_STEREO.
#   (b) noise_5p1_640k: 6 decorrelated band-split noise channels at the AC-3 max
#       bitrate (640k) to keep coupling off where possible — the "clean" in-scope
#       5.1 vector for the full per-channel datapath check.
#
# aevalsrc exprs are pipe-separated, one per channel in 5.1 order
# (FL FR FC LFE BL BR).  Verify acmod/lfe afterwards with `ffprobe -show_streams`.
echo "[gen] 5.1 tone -> tone_5p1_48k_192k.ac3"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "aevalsrc=exprs=0.30*sin(2*PI*440*t)|0.30*sin(2*PI*1320*t)|0.30*sin(2*PI*880*t)|0.30*sin(2*PI*60*t)|0.30*sin(2*PI*1760*t)|0.30*sin(2*PI*2200*t):c=5.1:d=0.20:s=$SR" \
    -ac 6 -ar "$SR" -c:a ac3 -b:a "$BR" -f ac3 "$OUT/tone_5p1_48k_192k.ac3"

echo "[gen] 5.1 decorrelated noise (640k) -> noise_5p1_48k_640k.ac3"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "anoisesrc=d=0.20:c=white:r=$SR:a=0.6:seed=11" \
    -f lavfi -i "anoisesrc=d=0.20:c=white:r=$SR:a=0.6:seed=22" \
    -f lavfi -i "anoisesrc=d=0.20:c=white:r=$SR:a=0.6:seed=33" \
    -f lavfi -i "anoisesrc=d=0.20:c=white:r=$SR:a=0.6:seed=44" \
    -f lavfi -i "anoisesrc=d=0.20:c=white:r=$SR:a=0.6:seed=55" \
    -f lavfi -i "anoisesrc=d=0.20:c=white:r=$SR:a=0.6:seed=66" \
    -filter_complex "[0:a]lowpass=f=5000[a0];[1:a]highpass=f=9000[a1];[2:a]bandpass=f=6000:width_type=h:w=1500[a2];[3:a]lowpass=f=120[a3];[4:a]bandpass=f=12000:width_type=h:w=2000[a4];[5:a]bandpass=f=15000:width_type=h:w=2000[a5];[a0][a1][a2][a3][a4][a5]join=inputs=6:channel_layout=5.1[a]" -map "[a]" \
    -ac 6 -ar "$SR" -c:a ac3 -b:a 640k -f ac3 "$OUT/noise_5p1_48k_640k.ac3"

# Convert each stream to hex (one byte per line) + extract the first frame.
# An AC-3 syncframe at 192 kbps / 48 kHz is a fixed size; we slice the first
# frame by locating the second 0B77 sync word.
hexify() {
    local f="$1"
    xxd -p -c1 "$f" > "$f.hex"
    # first frame = bytes up to (but not including) the 2nd occurrence of 0b 77
    python3 - "$f" > "$f.frame0.hex" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
sync = b"\x0b\x77"
first = data.find(sync)
assert first == 0, f"stream does not start with 0B77 (found at {first})"
second = data.find(sync, 2)
frame0 = data[:second] if second != -1 else data
sys.stderr.write(f"  {sys.argv[1]}: frame0 = {len(frame0)} bytes "
                 f"(= {len(frame0)//2} 16-bit words)\n")
for b in frame0:
    print(f"{b:02x}")
PY
}

for f in "$OUT"/*.ac3; do
    echo "[hex] $f"
    hexify "$f"
done

echo "[done] streams in $OUT"
ls -l "$OUT"
