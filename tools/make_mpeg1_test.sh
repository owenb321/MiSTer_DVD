#!/usr/bin/env bash
# make_mpeg1_test.sh — transcode any input video (mkv/mp4/...) into a
# DVD-COMPLIANT MPEG-1 + MP2 test file for the MPEG-1 codec path
# (feature/mpeg1-codecs, docs/mpeg1.md): MPEG-1 video at the DVD-legal SIF
# resolution, MP2 48 kHz stereo audio, MPEG-2 Program Stream mux (`-f dvd`,
# MP2 on stream_id 0xC0) — exactly what a real MPEG-1 DVD title carries.
#
# Usage:
#   tools/make_mpeg1_test.sh <input.mkv> <output.vob> [options]
# Options:
#   --pal            352x288 @25 fps (default: NTSC 352x240 @29.97)
#   --duration N     seconds to convert (default 120)
#   --start T        start offset (ffmpeg time syntax, default 0)
#   --abitrate K     MP2 bitrate in kbps (default 224; DVD allows up to 384)
#
# Copy the output .vob to the SD card and open it with the core's file picker
# (linear VOB path — no ISO needed). DVD-spec limits honoured: video
# <= 1.856 Mbps with the standard 40 KB VBV, audio 48 kHz Layer II.

set -euo pipefail

if [ $# -lt 2 ]; then
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

IN="$1"; OUT="$2"; shift 2

SIZE=352x240; RATE=30000/1001; DUR=120; START=0; ABR=224
while [ $# -gt 0 ]; do
    case "$1" in
        --pal)       SIZE=352x288; RATE=25 ;;
        --duration)  DUR="$2"; shift ;;
        --start)     START="$2"; shift ;;
        --abitrate)  ABR="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

W=${SIZE%x*}; H=${SIZE#*x}

# scale to fit inside WxH preserving aspect, pad to exactly WxH (4:3 frame)
VF="scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2,fps=${RATE}"

ffmpeg -y -loglevel warning -stats \
    -ss "$START" -t "$DUR" -i "$IN" \
    -vf "$VF" \
    -c:v mpeg1video -b:v 1150k -maxrate 1856k -bufsize 327680 \
    -c:a mp2 -ar 48000 -ac 2 -b:a "${ABR}k" \
    -f dvd "$OUT"

echo
echo "wrote $OUT ($(du -h "$OUT" | cut -f1)) — MPEG-1 ${SIZE}, MP2 48 kHz ${ABR}k, DVD PS mux"
ffprobe -hide_banner "$OUT" 2>&1 | grep -E "Stream|Duration" | sed 's/^ *//'
