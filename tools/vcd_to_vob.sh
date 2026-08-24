#!/usr/bin/env bash
# vcd_to_vob.sh — convert a VCD rip (the bin/cue DATA track) into a
# DVD-compatible .vob the core plays directly.
#
# A VCD is ALMOST DVD-spec already: the video is MPEG-1 352x240@29.97 (NTSC)
# or 352x288@25 (PAL) — both DVD-legal — so it is STREAM-COPIED bit-for-bit
# (no quality loss, and the core decodes the disc's original encode, the best
# possible real-world MPEG-1 test vector). What is NOT DVD-spec:
#   - the mux: MPEG-1 System stream in CD-ROM MODE2/2352 sectors
#     -> sectors are stripped here (24-byte header; Form2 = 2324 data bytes,
#        Form1 = 2048), then ffmpeg remuxes to a DVD Program Stream (-f dvd,
#        MP2 on stream_id 0xC0)
#   - the audio: MP2 44.1 kHz -> re-encoded at 48 kHz stereo (the DVD rate;
#     the core's output clock is fixed 48 kHz, 44.1 would play ~8.8 % fast)
#
# Usage:
#   tools/vcd_to_vob.sh <track.bin> <output.vob> [--abitrate K] [--duration N]
#
#   <track.bin> is the LARGE data track of the rip (usually "Track 2"; the
#   small Track 1 is the ISO filesystem, not the video). For multi-bin rips
#   convert each data track separately.
#
# Copy the .vob to the SD card and open it with the core's file picker.

set -euo pipefail

if [ $# -lt 2 ]; then
    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

IN="$1"; OUT="$2"; shift 2
ABR=224; DUR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --abitrate) ABR="$2"; shift ;;
        --duration) DUR="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

TMP="$(mktemp --suffix=.mpg)"
trap 'rm -f "$TMP"' EXIT

# Strip MODE2/2352 sectors -> raw MPEG program/system stream.
python3 - "$IN" "$TMP" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
out = open(dst, "wb")
n = form2 = 0
with open(src, "rb") as f:
    while True:
        s = f.read(2352)
        if len(s) < 2352:
            break
        # 12 sync + 3 addr + 1 mode + 8 subheader, then data.
        # Subheader submode bit5 = Form 2 (2324 data bytes, the MPEG sectors);
        # Form 1 = 2048 (filesystem sectors at the head of the track).
        if s[15] != 2:
            continue                      # not a MODE2 sector (audio track?)
        if s[18] & 0x20:
            out.write(s[24:24+2324]); form2 += 1
        else:
            out.write(s[24:24+2048])
        n += 1
if n == 0:
    sys.exit("no MODE2/2352 sectors found — is this the data track .bin?")
print(f"stripped {n} sectors ({form2} Form2) -> {dst}")
PYEOF

DURATION_ARGS=()
[ -n "$DUR" ] && DURATION_ARGS=(-t "$DUR")

# Video: bit-exact stream copy (already DVD-legal MPEG-1).
# Audio: MP2 re-encode at 48 kHz (proper resample — pitch preserved).
ffmpeg -y -loglevel warning -stats \
    -fflags +genpts -i "$TMP" "${DURATION_ARGS[@]}" \
    -map 0:v:0 -map 0:a:0 \
    -c:v copy \
    -c:a mp2 -ar 48000 -ac 2 -b:a "${ABR}k" \
    -f dvd "$OUT"

echo
echo "wrote $OUT ($(du -h "$OUT" | cut -f1)) — video stream-copied, MP2 48 kHz ${ABR}k, DVD PS mux"
ffprobe -hide_banner "$OUT" 2>&1 | grep -E "Stream|Duration" | sed 's/^ *//'
