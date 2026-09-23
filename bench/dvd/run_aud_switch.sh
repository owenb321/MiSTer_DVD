#!/usr/bin/env bash
# run_aud_switch.sh -- an audio-track switch must hand the AC-3 decoder only whole,
# correct frames of the NEW track (docs/fabric_audio.md "Audio-track switch
# realign"). Real front half of the audio path over a real disc slice:
#   ps_demux -> ac3/dts/mp2_reframer -> audio_ring, flush_ctl's aud_resync on the ring.
#
#   sweep     38 switches 0x81 (5.1) <-> 0x80 (2.0) at staggered offsets
#   stray-N   one switch landing on a PES whose partial frame carries a STRAY
#             0x0B77 ahead of its real first frame (3 of the 5 in the slice)
#   subhdr-N  one switch landing INSIDE the old track's audio sub-header
#
#   --red     the pre-fix wiring must FAIL, and each mutation must fail ITS arm:
#             N1 no first_access_unit skip   -> stray-*
#             N2 no cut of the in-flight PES -> sweep
#             N3 reframer locks kept         -> sweep
#             N4 no substream re-check       -> subhdr-*
#
# Fixture: 8 MB of MEN_IN_BLACK VTS_21_1.VOB, cut from $DVD_ISO_DIR with isoinfo
# (a commercial disc is never committed). Without it every arm SKIPS -- loudly.
set -u
cd "$(dirname "$0")/../.."
RED=0; [ "${1:-}" = "--red" ] && RED=1
ISO_DIR="${DVD_ISO_DIR:-$HOME/dvd-isos}"
FIX=".sim/aud_switch"; VOB="$FIX/mib21.vob"
mkdir -p "$FIX"

if [ ! -s "$VOB" ]; then
    ISO=$(find "$ISO_DIR" -iname 'MEN_IN_BLACK.iso' 2>/dev/null | head -1)
    if [ -z "$ISO" ] || ! command -v isoinfo >/dev/null; then
        echo "== run_aud_switch: SKIPPED (need isoinfo and MEN_IN_BLACK.iso under DVD_ISO_DIR=$ISO_DIR) =="
        exit 0
    fi
    isoinfo -i "$ISO" -x '/VIDEO_TS/VTS_21_1.VOB;1' 2>/dev/null \
        | head -c 12582912 | tail -c 8388608 > "$VOB"
fi

REST="dvd/ac3_reframer.sv dvd/dts_reframer.sv dvd/mp2_reframer.sv dvd/flush_ctl.sv dvd/audio_ring.sv bench/dvd/aud_switch_chain_tb.sv"
iv() { iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o "$1" "${@:2}" 2>&1 | grep -v sorry; }

# arms: name | plusargs.  Offsets were measured on this slice (see the tb header).
ARMS=(
  "sweep|"
  "stray-81|+SWAT=300000 +FROM=0 +TO=1 +MB=5"
  "stray-82|+SWAT=120000 +FROM=0 +TO=2 +MB=5"
  "stray-83|+SWAT=4340000 +FROM=0 +TO=3 +MB=5"
  "subhdr-to51|+SWSUB +SWAT=300000 +FROM=0 +TO=1 +MB=5"
  "subhdr-to20|+SWSUB +SWAT=120000 +FROM=1 +TO=0 +MB=5"
)

# run SIM over every arm; prints the names of the arms that FAILED
failed_arms() {
    local sim=$1 extra=${2:-} out=""
    for a in "${ARMS[@]}"; do
        local name=${a%%|*} args=${a#*|}
        if ! vvp "$sim" $args $extra +VOB="$VOB" 2>&1 | grep -q "AUD_SWITCH_CHAIN: PASS"; then
            out="$out $name"
        fi
    done
    echo "${out# }"
}

fail=0
iv "$FIX/sim" dvd/ps_demux.sv $REST
got=$(failed_arms "$FIX/sim")
if [ -z "$got" ]; then echo "  PASS aud_switch_chain: all ${#ARMS[@]} arms"
else echo "  FAIL aud_switch_chain: $got"; fail=1; fi

if [ "$RED" -eq 1 ]; then
    # RED: the pre-fix wiring (no realign, reframers on the core reset) must fail
    got=$(failed_arms "$FIX/sim" +PRE)
    case " $got " in *" sweep "*) echo "  PASS RED pre-fix wiring fails: $got";;
                     *) echo "  FAIL RED pre-fix wiring was not caught ($got)"; fail=1;; esac

    # mutation: name | sed expr on ps_demux (or empty) | extra plusarg | arm(s) that must fail
    mut() {
        local name=$1 expr=$2 extra=$3 want=$4 d; d=$(mktemp -d)
        cp dvd/ps_demux.sv "$d/m.sv"
        if [ -n "$expr" ]; then
            sed -i "$expr" "$d/m.sv"
            if cmp -s dvd/ps_demux.sv "$d/m.sv"; then echo "  FAIL $name: anchor missed"; fail=1; rm -rf "$d"; return; fi
        fi
        iv "$d/sim" "$d/m.sv" $REST
        got=$(failed_arms "$d/sim" "$extra")
        local ok=1 w
        for w in $want; do case " $got " in *" $w "*) ;; *) ok=0;; esac; done
        if [ $ok -eq 1 ]; then echo "  PASS $name caught by: $got"
        else echo "  FAIL $name: expected [$want] to fail, got [$got]"; fail=1; fi
        rm -rf "$d"
    }
    mut N1 "s/end else if ({fap_hi_r, in_byte} == 16'd1) begin/end else if (1'b1) begin/" "" \
        "stray-81 stray-82 stray-83"
    mut N2 "s/            if (state == S_AUDIO_DATA) begin/            if (1'b0) begin/" "" "sweep"
    mut N3 "" "+KEEPLOCK" "sweep"
    mut N4 "s/end else if (aud_ssid_r != aud_track) begin/end else if (1'b0) begin/" "" \
        "subhdr-to51 subhdr-to20"
fi

[ $fail -eq 0 ] && echo "== AUD SWITCH: ALL GREEN ==" || echo "== AUD SWITCH: FAILURES =="
exit $fail
