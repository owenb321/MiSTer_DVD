#!/usr/bin/env bash
# run_stc_freerun.sh — THE STC IS A CLOCK (docs/stc_freerun.md): the whole gate.
#
#   1. run_pts_assoc.sh   PTS -> picture association through the real decoder path,
#                         across a flush, with its RED arm (needs DVD_ISO_DIR / the VOB)
#   2. run_disp_sched.sh  the display scheduler, 12 scenarios + 5 mutations
#   3. av_sync_tb         the clk_sys mirror of the clock
#   4. dvd_audio_decode_tb  the audio side (drain gate, catch-up) + a RED arm proving
#                         the release waits for the DISPLAY anchor, not the parse front
#   5. flush_ctl_tb, dvd_telem_tb  unchanged contracts that must still hold
#   6. the display suites that instantiate the re-paced governor
set -u
cd "$(dirname "$0")/../.."
fail=0
run() {   # name  pass-regex  command...
    local name=$1 pat=$2; shift 2
    local log; log=$(mktemp)
    if "$@" >"$log" 2>&1 && grep -q "$pat" "$log"; then echo "  PASS $name"
    else echo "  FAIL $name"; grep -v "sorry" "$log" | tail -12; fail=1; fi
    rm -f "$log"
}
iv() { iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -I dvd/ac3 -o "$1" "${@:2}"; }

echo "== 1. association =="
bash bench/dvd/run_pts_assoc.sh || fail=1
echo "== 2. scheduler =="
bash bench/dvd/run_disp_sched.sh || fail=1
echo "== 3. mirror =="
iv /tmp/av_sync_sim dvd/av_sync.sv bench/dvd/av_sync_tb.sv && run av_sync "PASS: av_sync" vvp /tmp/av_sync_sim
echo "== 4. audio =="
iv /tmp/aud_sim dvd/ac3/*.sv dvd/lpcm_unpack.sv dvd/mp2/mp2_decode.sv dvd/dvd_audio_decode.sv bench/dvd/dvd_audio_decode_tb.sv \
  && run dvd_audio_decode "PASS: dvd_audio_decode" vvp /tmp/aud_sim
# RED: release on the PROVISIONAL (parse-front) anchor instead of the display one.
# That was the shipping behaviour on 2026-09-07 and it put audio ~1.6 s ahead of the
# picture for a whole title, with play_err reading -98 ms because the measurement had
# been re-based onto the same re-anchor it was supposed to expose.
red_aud=$(mktemp -d)
sed 's/if (play_pts_valid \&\& disp_anchored \&\& video_live/if (play_pts_valid \&\& stc_anchored \&\& video_live/' \
    dvd/dvd_audio_decode.sv > "$red_aud/dvd_audio_decode.sv"
if iv "$red_aud/sim" dvd/ac3/*.sv dvd/lpcm_unpack.sv dvd/mp2/mp2_decode.sv "$red_aud/dvd_audio_decode.sv" \
      bench/dvd/dvd_audio_decode_tb.sv 2>/dev/null \
   && vvp "$red_aud/sim" 2>/dev/null | grep -q "FAIL C1: released against the PROVISIONAL anchor"; then
  echo "  PASS dvd_audio_decode RED (provisional-anchor release is caught)"
else
  echo "  FAIL dvd_audio_decode RED -- the bench cannot see a release against the parse front"; fail=1
fi
rm -rf "$red_aud"
echo "== 5. contracts =="
iv /tmp/flush_ctl_sim dvd/flush_ctl.sv bench/dvd/flush_ctl_tb.sv && run flush_ctl "PASS" vvp /tmp/flush_ctl_sim
bash bench/dvd/run_telem.sh || fail=1
echo "== 6. display =="
for tb in pickup_hold_tb film_detect_tb; do
  iv /tmp/${tb}_sim dvd/resample_addrgen.v rtl/mpeg2/mem_addr.v bench/dvd/$tb.sv && run $tb "PASS" vvp /tmp/${tb}_sim
done
# ⚠ resample_persist_tb and resample_addr_realstride_tb ASSERT NOTHING. They print
# [scan] lines and a "check the [scan] lines" instruction -- no PASS, no FAIL, no
# self-check at all. They were listed above with a "PASS" match, so they reported a
# permanent FAIL that said nothing about the RTL. Run them for their traces (they are
# the 256-line strobe and stride diagnostics) but do not pretend they gate anything.
# ⏳ Worth making self-checking: resample_persist_tb's own header states the property
# ("addr must stay monotonic past disp_y=256"), which is a checkable assertion.
for tb in resample_persist_tb resample_addr_realstride_tb; do
  iv /tmp/${tb}_sim dvd/resample_addrgen.v rtl/mpeg2/mem_addr.v bench/dvd/$tb.sv \
    && vvp /tmp/${tb}_sim >/dev/null 2>&1 && echo "  ran $tb (observational -- asserts nothing)"
done
bash bench/dvd/run_field_phase.sh  | tail -1
bash bench/dvd/run_field_parity.sh | tail -1

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
