#!/usr/bin/env bash
# run_stc_freerun.sh — THE STC IS A CLOCK (docs/stc_freerun.md): the whole gate.
#
#   1. run_pts_assoc.sh   PTS -> picture association through the real decoder path,
#                         across a flush, with its RED arm (needs DVD_ISO_DIR / the VOB)
#   2. run_disp_sched.sh  the display scheduler, 12 scenarios + 5 mutations
#   3. av_sync_tb         the clk_sys mirror of the clock
#   4. dvd_audio_decode_tb  the audio side (drain gate, catch-up, re-base port tied)
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
echo "== 5. contracts =="
iv /tmp/flush_ctl_sim dvd/flush_ctl.sv bench/dvd/flush_ctl_tb.sv && run flush_ctl "PASS" vvp /tmp/flush_ctl_sim
bash bench/dvd/run_telem.sh || fail=1
echo "== 6. display =="
for tb in pickup_hold_tb resample_persist_tb resample_addr_realstride_tb film_detect_tb; do
  iv /tmp/${tb}_sim dvd/resample_addrgen.v rtl/mpeg2/mem_addr.v bench/dvd/$tb.sv && run $tb "PASS" vvp /tmp/${tb}_sim
done
bash bench/dvd/run_field_phase.sh  | tail -1
bash bench/dvd/run_field_parity.sh | tail -1

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
