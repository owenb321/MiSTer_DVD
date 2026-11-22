#!/usr/bin/env bash
# run_drc_mode.sh -- gate for the OSD's Dynamic Range (issue #189: AC-3 DRC Normal /
# Full / Night) and the DTS DYNF count that rides with it. docs/status_log.md
# "Dynamic Range".
#
# WHAT IS PROVEN, and where
#   [drc]    tools/imdct_isa.py check: drc_coef's (multiplier, shift) equals the gain each
#            mode is DEFINED as (Normal the authored dynrng, Full unity, Night its square
#            capped at 0x7F's x15.75), all 256 dynrng x 4 modes; and the term program
#            bit-exact against imdct_model on random blocks in every mode
#   [eng]    bench/dvd/run_imdct_eng.sh: dts_vec op 25 applies each mode word for word
#            (its --red arms M12-M17 are the mode's mutations); Normal unchanged
#   [wiring] tools/check_drc_wiring.py: the OSD row to dts_vec, the flags to telemetry
#   The DYNF count is scored by bench/dvd/run_dts.sh [count] (V20, written_misc), against
#   the reference parser's reading of the header bit (tools/dts_golden.py).
#
# --red: the wiring arms below (each must fail with its own message), then
# run_imdct_eng.sh --red.
#
# Usage: bench/dvd/run_drc_mode.sh [--red]     (exit 0 = ALL GREEN)
set -uo pipefail
cd "$(dirname "$0")/../.."
fails=0

echo "== GREEN: [drc] the gains, the term program in every mode =="
out=$(python3 tools/imdct_isa.py check --random 12 2>&1); echo "$out" | sed 's/^/  /'
echo "$out" | grep -q '^\[drc\]  PASS' && echo "$out" | grep -q '^RESULT: PASS' \
    || { echo "  FAIL: imdct_isa check"; fails=$((fails+1)); }
echo "== GREEN: [eng] dts_vec op 25 =="
if [ "${1:-}" = "--red" ]; then bench/dvd/run_imdct_eng.sh --red; else bench/dvd/run_imdct_eng.sh; fi \
    || fails=$((fails+1))
echo "== GREEN: [wiring] =="
python3 tools/check_drc_wiring.py || fails=$((fails+1))

if [ "${1:-}" = "--red" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  LOG="$tmp/log"
  wire_case() {   # $1 label, $2 file (emu|dec|eng|top|qsf), $3 sed program, $4 expected text
    echo "== RED wiring [$1] =="
    cp dvd/emu.sv "$tmp/emu.sv"; cp dvd/dvd_audio_decode.sv "$tmp/dec.sv"
    cp dvd/audio_engine.sv "$tmp/eng.sv"; cp dvd/dts/dts_top.sv "$tmp/top.sv"; cp DVD.qsf "$tmp/DVD.qsf"
    case "$2" in
      emu) f="$tmp/emu.sv"; o=dvd/emu.sv ;;   dec) f="$tmp/dec.sv"; o=dvd/dvd_audio_decode.sv ;;
      eng) f="$tmp/eng.sv"; o=dvd/audio_engine.sv ;; top) f="$tmp/top.sv"; o=dvd/dts/dts_top.sv ;;
      qsf) f="$tmp/DVD.qsf"; o=DVD.qsf ;;
    esac
    sed -i "$3" "$f"
    if cmp -s "$f" "$o"; then
      echo "  FAIL: the mutation did not apply to $o"; fails=$((fails+1)); return
    fi
    if python3 tools/check_drc_wiring.py --emu "$tmp/emu.sv" --dec "$tmp/dec.sv" --eng "$tmp/eng.sv" \
         --top "$tmp/top.sv" --qsf "$tmp/DVD.qsf" > "$LOG" 2>&1; then
      echo "  FAIL: the check PASSED a broken wiring"; fails=$((fails+1))
    elif ! grep -qF -- "$4" "$LOG"; then
      echo "  FAIL: the check failed, but not with \"$4\":"; sed 's/^/    /' "$LOG" | head -3; fails=$((fails+1))
    else
      echo "  failed as required:"; grep -F -- "$4" "$LOG" | head -1 | sed 's/^/    /'
    fi
  }
  wire_case "the setting from the wrong bits"     emu 's/aud_drc = status\[62:61\];/aud_drc = status[61:60];/' "aud_drc = status[62:61];"
  wire_case "the bits shared with another row"    emu 's/P2O\[46\],Analog CSync/P2O[61],Analog CSync/' "also claimed by"
  wire_case "the row's values re-ordered"         emu 's/,Dynamic Range,Normal,Full,Night;/,Dynamic Range,Full,Normal,Night;/' "expected one CONF_STR row"
  wire_case "decode tied off in emu"              emu 's/\.drc_mode    (aud_drc),/.drc_mode    (2'"'"'d0),/' ".drc_mode(2'd0), want .drc_mode(aud_drc)"
  wire_case "engine tied off in the decoder"      dec 's/\.drc_mode    (drc_mode),/.drc_mode    (2'"'"'d0),/' "audio_engine: .drc_mode(2'd0)"
  wire_case "dts_top not given the mode"          eng 's/\.codec(eng_codec), \.drc_mode,/.codec(eng_codec), .drc_mode(2'"'"'d0),/' "audio_engine dts_top: .drc_mode(2'd0)"
  wire_case "dts_vec not given the mode"          top 's/\.coef_q, \.drc_mode);/.coef_q, .drc_mode(2'"'"'d0));/' "dts_top dts_vec: .drc_mode(2'd0)"
  wire_case "DYNF flag left off telemetry"        emu 's/3'"'"'d0, drc_capped_w, dts_dynf_w, dts_active_w,/3'"'"'d0, drc_capped_w, 1'"'"'b0, dts_active_w,/' "emu dvd_telem: .dts_flags"
  wire_case "cap flag never set"                  dec 's/if (eng_drc_capped) dbg_drc_capped <= 1'"'"'b1;//' "dbg_drc_capped is not set"
  wire_case "DYNF count not exported"             eng 's/\.dynf_frames(n_dynf),/.dynf_frames(),/' "dts_top: .dynf_frames()"
  wire_case "the decoder missing from the qsf"    qsf '/dvd\/dvd_audio_decode\.sv/d' "does not name dvd/dvd_audio_decode.sv"
  if [ "$fails" -ne 0 ]; then echo "run_drc_mode: RED SUITE FAILED: $fails arm(s)"; exit 1; fi
  echo "run_drc_mode: RED suite OK: every mutation was caught by its own arm."
  exit 0
fi

[ "$fails" = 0 ] && echo "run_drc_mode: ALL GREEN" || echo "run_drc_mode: FAILURES ($fails)"
exit $([ "$fails" = 0 ] && echo 0 || echo 1)
