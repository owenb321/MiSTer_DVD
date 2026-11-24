#!/usr/bin/env bash
#
# run_trick_demux.sh -- ps_demux's aud_drop: trick play discards every audio PES
# (docs/trick_play.md "Audio and subpicture").
#
# Fixtures (bench/dvd/trick_demux_fixtures.py): synthetic packs carrying video, MP2
# (0xC0), AC-3 (0xBD 0x80) and a subpicture; and, with a disc, the raw sectors of 6
# trick-play reads of Men in Black 3. Expected video = tools/trick_scan.py video_es.
#
#   [1] aud_drop, audio ring FULL: no audio out, no stall, video byte-identical
#   [2] control, no drop, ring ready: audio DOES flow (the fixture carries it, so [1]'s
#       zero is not vacuous); video byte-identical
#   [3] control, no drop, ring full: the demux stalls (why aud_drop exists)
#   --red:
#   [R1] the MP2 (stream 0xC0) site ignores aud_drop          -> [1] on syn
#   [R2] the private_stream_1 site ignores aud_drop           -> [1] on syn and disc
#
#   ./bench/dvd/run_trick_demux.sh [--red]
set -euo pipefail
cd "$(dirname "$0")/../.."

RED=0; [ "${1:-}" = "--red" ] && RED=1
OUT=bench/dvd/test_vobs/trick_demux       # gitignored
mkdir -p "$OUT"
ISO="${TRICK_ISO:-}"
if [ -z "$ISO" ] && [ -n "${DVD_ISO_DIR:-}" ] && [ -d "$DVD_ISO_DIR" ]; then
  ISO=$(find "$DVD_ISO_DIR" -maxdepth 3 -name 'MEN_IN_BLACK_3*.iso' 2>/dev/null | sort | head -1)
fi
python3 bench/dvd/trick_demux_fixtures.py "$OUT" ${ISO:+"$ISO"}
FIX="syn"; [ -f "$OUT/disc.ps" ] && [ -n "$ISO" ] && FIX="syn disc"

# check <vvp> <tag>: runs the three arms on every fixture, prints failures, returns 1 on any
check() {
  local vvp=$1 tag=$2 bad=0 f r aud vid stall
  for f in $FIX; do
    for c in "1 0 1" "0 1 2" "0 0 3"; do
      set -- $c
      r=$(vvp -n "$vvp" +IN="$OUT/$f.ps" +VID="$OUT/$f.$tag$3.out" +DROP=$1 +AUDREADY=$2 | head -1)
      read -r _ aud _ _ _ vid _ _ _ stall <<<"$r"
      case $3 in
        1) if [ "$aud" != 0 ] || [ "$stall" != 0 ] || ! cmp -s "$OUT/$f.$tag$3.out" "$OUT/$f.vid"; then
             echo "  [1] $f: $r"; bad=1; fi ;;
        2) if [ "$aud" = 0 ] || [ "$stall" != 0 ] || ! cmp -s "$OUT/$f.$tag$3.out" "$OUT/$f.vid"; then
             echo "  [2] $f: $r"; bad=1; fi ;;
        3) if [ "$stall" != 1 ]; then echo "  [3] $f: $r (expected a stall)"; bad=1; fi ;;
      esac
    done
  done
  return $bad
}

iverilog -g2012 -o "$OUT/base.vvp" dvd/ps_demux.sv bench/dvd/trick_demux_tb.sv
rc=0
if out=$(check "$OUT/base.vvp" base); then
  echo "[1][2][3] PASS on: $FIX"
else
  echo "$out"; echo "FAIL"; rc=1
fi

if [ "$RED" = 1 ]; then
  red() {   # red <id> <fixture that must fail [1]> <perl substitution>
    local m="$OUT/mut_$1.sv" out
    perl -0pe "$3" dvd/ps_demux.sv > "$m"
    if cmp -s "$m" dvd/ps_demux.sv; then echo "[$1] FAIL: the mutation did not apply"; rc=1; return; fi
    iverilog -g2012 -o "$OUT/$1.vvp" "$m" bench/dvd/trick_demux_tb.sv
    out=$(check "$OUT/$1.vvp" "$1" || true)
    if grep -q "^  \[1\] $2:" <<<"$out"; then echo "[$1] PASS ($2 fails [1])"
    else echo "[$1] FAIL: survived"; rc=1; fi
  }
  red R1 syn 's/if \(in_byte\[2:0\] == aud_track && !aud_drop\)/if (in_byte[2:0] == aud_track)/'
  red R2 syn 's/end else if \(aud_drop \|\| in_byte\[2:0\] != aud_track\)/end else if (in_byte[2:0] != aud_track)/'
fi

[ -z "$ISO" ] && echo "NOTE: no disc (DVD_ISO_DIR / TRICK_ISO): the synthetic fixture only"
[ $rc = 0 ] && echo "run_trick_demux: PASS" || echo "run_trick_demux: FAIL"
exit $rc
