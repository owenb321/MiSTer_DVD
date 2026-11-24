#!/usr/bin/env bash
#
# run_trick_decode.sh -- trick play's spliced I-frame stream through the WHOLE RTL video
# decoder (docs/trick_play.md "The splice through our decoder").
#
# tools/trick_splice.py builds the stream trick play feeds the decoder: per VOBU, the read
# [nv_pck .. nv_pck + vobu_1stref_ea], cut by the ES filter, then a jump by fwda. ffmpeg
# decodes it cleanly on 192/192 walks; this gate checks that OUR decoder
# (rtl/mpeg2/mpeg2video.v, as dvd/emu.sv instantiates it) does too. bench/dvd/trick_decode_tb.sv
# logs every reconstructed-picture write; bench/dvd/trick_decode_score.py rebuilds each picture
# and compares it with ffmpeg's decode (PSNR floor, not equality: the IDCTs differ).
#
# The fixture is cut from a real disc: set DVD_ISO_DIR to a library of decrypted rips, or
# TRICK_ISO to one image. Without one every arm SKIPs loudly. Default disc: the first
# MEN_IN_BLACK_3*.iso under the library (its walk is the one documented in docs/trick_play.md).
#
#   [1] the filtered splice decodes to ffmpeg's pictures            (gated)
#   [2] vacuity: the scorer FAILs when asked for one picture more    (always; no sim)
#   --red adds
#   [R1] the RAW cut sectors (no ES filter) against the filtered reference must FAIL: the
#        filter is load-bearing in our decoder, not only in ffmpeg
#
# Slow: the full decoder runs ~2,000 clk_dec cycles/s in Icarus, about 8 min per picture.
# PICS (default 3) sets how many pictures are scored. The walk is one VOBU longer: the
# decoder holds a picture's last 8 words until the next picture starts.
#
#   ./bench/dvd/run_trick_decode.sh [--red]
set -euo pipefail
cd "$(dirname "$0")/../.."

RED=0; [ "${1:-}" = "--red" ] && RED=1
PICS="${PICS:-3}"
TIER="${TIER:-1}"                       # 2 s jumps (8x)
OUT=bench/dvd/test_vobs/trick_decode    # gitignored
mkdir -p "$OUT"

ISO="${TRICK_ISO:-}"
if [ -z "$ISO" ] && [ -n "${DVD_ISO_DIR:-}" ] && [ -d "$DVD_ISO_DIR" ]; then
  ISO=$(find "$DVD_ISO_DIR" -maxdepth 3 -name 'MEN_IN_BLACK_3*.iso' 2>/dev/null | sort | head -1)
fi
if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
  echo "SKIP run_trick_decode: no disc (set DVD_ISO_DIR or TRICK_ISO) -- NOTHING WAS CHECKED"
  exit 0
fi
echo "== fixture: $(basename "$ISO"), tier $TIER fwd, $PICS pictures =="
python3 tools/trick_splice.py "$ISO" --tier "$TIER" --dir fwd --frames $((PICS + 1)) -o "$OUT/splice.m2v"
python3 tools/trick_splice.py "$ISO" --tier "$TIER" --dir fwd --frames $((PICS + 1)) --raw -o "$OUT/raw.m2v" || true

# the decoder, as DVD.qsf builds it (dvd/resample_addrgen.v shadows the rtl/ copy)
DEC="dvd/disp_hstretch.sv dvd/disp_sched.sv dvd/disp_vscale.sv dvd/field_blend.sv
     dvd/resample_addrgen.v dvd/std_rate.sv dvd/dec_duty.sv dvd/frame_drop_ctl.sv
     dvd/mem_req_prefetch.sv dvd/pts_assoc.sv dvd/ref_dta_gate.sv dvd/vbuf_pos.sv"
for f in rtl/mpeg2/*.v; do
  case "$(basename "$f")" in
    resample_addrgen.v|timescale.v|fifo_size.v|mem_codes.v|modeline.v.inc) ;;
    *) grep -q '^ *module ' "$f" && DEC="$DEC $f" ;;
  esac
done
iverilog -g2012 -D__IVERILOG__ -I dvd/mem_override -I rtl/mpeg2 -o "$OUT/sim.vvp" \
  $DEC bench/dvd/trick_decode_tb.sv

# PICS pictures of 64,800 words at ~80k words per 1M cycles, with a 2x margin
MAXCYC=$(( PICS * 1700000 + 2000000 ))
sim() { (cd "$OUT" && vvp sim.vvp +M2V="$1" +PICS="$PICS" +MAXCYC="$MAXCYC" +OUT="$2" | tail -2); }
rc=0

echo "== [1] filtered splice =="
sim splice.m2v splice.log
if python3 bench/dvd/trick_decode_score.py "$OUT/splice.log" "$OUT/splice.m2v" --pics "$PICS"; then
  echo "[1] PASS"
else
  echo "[1] FAIL"; rc=1
fi

echo "== [2] vacuity: one picture more than was decoded =="
if python3 bench/dvd/trick_decode_score.py "$OUT/splice.log" "$OUT/splice.m2v" --pics $((PICS + 1)) >/dev/null; then
  echo "[2] FAIL: the scorer passed a picture that was never decoded"; rc=1
else
  echo "[2] PASS (scorer refused)"
fi

if [ "$RED" = 1 ]; then
  echo "== [R1] RED: raw cut sectors, scored against the filtered reference =="
  sim raw.m2v raw.log
  if python3 bench/dvd/trick_decode_score.py "$OUT/raw.log" "$OUT/splice.m2v" --pics "$PICS"; then
    echo "[R1] FAIL: the unfiltered stream scored clean, so the gate cannot see the filter"; rc=1
  else
    echo "[R1] PASS (unfiltered stream fails, as it must)"
  fi
fi

[ $rc = 0 ] && echo "run_trick_decode: PASS" || echo "run_trick_decode: FAIL"
exit $rc
