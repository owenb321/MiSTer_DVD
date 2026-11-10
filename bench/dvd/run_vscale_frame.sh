#!/usr/bin/env bash
# Gate for disp_vscale on the PROGRESSIVE FRAME path (feature/progressive-aspect,
# docs/crt_anamorphic.md §11 + §13). See bench/dvd/disp_vscale_frame_tb.sv for what is
# scored and why.
#
#   ./bench/dvd/run_vscale_frame.sh          GREEN arms
#   ./bench/dvd/run_vscale_frame.sh --red    + mutations, each of which must fail its own arm
#
# What the arms prove:
#   frame_lb*   Letterbox on a frame scan: H*3/4 lines, golden blend values, tags
#               ROW_0 / ROW_1 / ROW_X (the mixer's contract; a ROW_X on line 1 is a black
#               line under the top bar). NTSC 480 and PAL 576, with and without back-pressure.
#   field_lb*   the Interlaced (field) path: tags ROW_0-or-ROW_1 / ROW_X / ROW_X -- unchanged.
#   frame_fit   vscale_en = 0: frame scans pass through untouched.
#   toggle      a Letterbox change landing between a frame's line 0 and line 1 takes effect
#               on the NEXT scan, in both directions.
#   *_r3, *_r4  Standard Convert To PAL: 6/5 UP (replay lines, the bottom field's clamp, the
#               tail) and 9/10, with exact line counts (docs/standard_convert.md Phase 4).
set -u
cd "$(dirname "$0")/../.."
OUT=.sim/vscale_frame; mkdir -p "$OUT"
SRC="rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xfifo_sc.v rtl/mpeg2/xilinx_fifo_dc.v"
TB=bench/dvd/disp_vscale_frame_tb.sv
fail=0

build() {   # build <name> <disp_vscale.sv>
  iverilog -g2012 -I rtl/mpeg2 -o "$OUT/$1" $SRC "$2" $TB 2>"$OUT/$1.build.log" \
    || { echo "  BUILD FAILED: $1 (see $OUT/$1.build.log)"; return 1; }
}
PENDING=()
run() {     # run <sim> <label> <expect pass|fail> <plusargs...>
  local sim=$1 label=$2 want=$3; shift 3
  ( vvp -n "$OUT/$sim" "$@" >"$OUT/$label.log" 2>&1; echo $? >"$OUT/$label.rc" ) &
  PENDING+=("$label:$want")
}
score() {
  wait
  local e label want rc got
  for e in "${PENDING[@]}"; do
    label=${e%%:*}; want=${e##*:}; rc=$(cat "$OUT/$label.rc" 2>/dev/null || echo 99)
    got=fail
    if [ "$rc" = 0 ] && grep -q "RESULT: PASS" "$OUT/$label.log"; then got=pass; fi
    if [ "$got" = "$want" ]; then echo "  ok    $label (${got})"
    else echo "  FAIL  $label: want $want, got $got (see $OUT/$label.log)"; fail=1; fi
  done
  PENDING=()
}
green_arms() {   # green_arms <sim> <prefix> <expect>
  local sim=$1 p=$2 w=$3
  run "$sim" "${p}frame_lb"      "$w" +case=frame_lb
  run "$sim" "${p}frame_lb_pal"  "$w" +case=frame_lb +h=576
  run "$sim" "${p}frame_lb_bp"   "$w" +case=frame_lb +bp=1
  run "$sim" "${p}field_lb"      "$w" +case=field_lb
  run "$sim" "${p}field_lb_pal"  "$w" +case=field_lb +h=288
  run "$sim" "${p}field_lb_bp"   "$w" +case=field_lb +bp=1
  run "$sim" "${p}frame_fit"     "$w" +case=frame_fit
  run "$sim" "${p}frame_fit_bp"  "$w" +case=frame_fit +bp=1
  run "$sim" "${p}toggle"        "$w" +case=toggle
  run "$sim" "${p}toggle_bp"     "$w" +case=toggle +bp=1
  # Standard Convert ratios (docs/standard_convert.md): 576 -> 480 / 360, 288 -> 240 / 180 per field
  run "$sim" "${p}frame_r1"      "$w" +case=frame_r +ratio=1 +lines=480
  run "$sim" "${p}frame_r2"      "$w" +case=frame_r +ratio=2 +lines=360
  run "$sim" "${p}frame_r1_bp"   "$w" +case=frame_r +ratio=1 +lines=480 +bp=1
  run "$sim" "${p}field_r1"      "$w" +case=field_r +ratio=1 +lines=240
  run "$sim" "${p}field_r2"      "$w" +case=field_r +ratio=2 +lines=180
  run "$sim" "${p}field_r2_bp"   "$w" +case=field_r +ratio=2 +lines=180 +bp=1
  run "$sim" "${p}field_r0_cf"   "$w" +case=field_r +ratio=0 +h=240 +lines=180
  run "$sim" "${p}rtoggle"       "$w" +case=rtoggle
  run "$sim" "${p}rtoggle_bp"    "$w" +case=rtoggle +bp=1
  # To PAL (2026-11-09): 6/5 UP (480 -> 576, 240 -> 288 a field) and 9/10 (480 -> 432, 240 -> 216)
  run "$sim" "${p}frame_r3"      "$w" +case=frame_r +ratio=3 +lines=576
  run "$sim" "${p}frame_r3_bp"   "$w" +case=frame_r +ratio=3 +lines=576 +bp=1
  run "$sim" "${p}field_r3"      "$w" +case=field_r +ratio=3 +lines=288
  run "$sim" "${p}field_r3_bp"   "$w" +case=field_r +ratio=3 +lines=288 +bp=1
  run "$sim" "${p}frame_r4"      "$w" +case=frame_r +ratio=4 +lines=432
  run "$sim" "${p}field_r4"      "$w" +case=field_r +ratio=4 +lines=216
  run "$sim" "${p}field_r4_bp"   "$w" +case=field_r +ratio=4 +lines=216 +bp=1
}

echo "== disp_vscale frame path: GREEN arms"
build green dvd/disp_vscale.sv || exit 1
green_arms green "" pass
score

if [ "${1:-}" = "--red" ]; then
  mutate() {  # mutate <name> <sed-expr>
    local dst="$OUT/mut_$1.sv"
    sed "$2" dvd/disp_vscale.sv >"$dst"
    if cmp -s dvd/disp_vscale.sv "$dst"; then echo "  FAIL  mutation $1 did not apply (anchor moved)" >&2; return 1; fi
    build "mut_$1" "$dst"
  }
  echo "== RED: mutations (each must fail its own arm)"
  # M1: head side takes the paired ROW_1 for a new scan again (the 359-line re-arm)
  if mutate M1_head_rearm 's/wire        h_ft   = (h_pos == ROW_0_COL_0) || ((h_pos == ROW_1_COL_0) \&\& ~h_prev_row0);/wire        h_ft   = (h_pos == ROW_0_COL_0) || (h_pos == ROW_1_COL_0);/'; then
    run mut_M1_head_rearm M1_head_rearm fail +case=frame_lb
    run mut_M1_head_rearm M1_head_rearm_field pass +case=field_lb      # the field path never pairs
  else fail=1; fi
  # M2: input side re-decides route/mode at the paired ROW_1 (a mid-frame change tears)
  if mutate M2_input_rearm 's/wire        in_ft   = (in_pos == ROW_0_COL_0) || ((in_pos == ROW_1_COL_0) \&\& ~in_prev_row0);/wire        in_ft   = (in_pos == ROW_0_COL_0) || (in_pos == ROW_1_COL_0);/'; then
    run mut_M2_input_rearm M2_input_rearm fail +case=toggle
  else fail=1; fi
  # M3: output line 1 of a frame scan tagged ROW_X (the black line under the top bar)
  if mutate M3_no_row1_tag 's/(e_line_second \&\& scan_frame) ? ROW_1_COL_0 : ROW_X_COL_0/ROW_X_COL_0/'; then
    run mut_M3_no_row1_tag M3_no_row1_tag fail +case=frame_lb
  else fail=1; fi
  # M4: ROW_1 tag on line 1 of EVERY scan, field scans included (changes the Interlaced path)
  if mutate M4_row1_on_fields 's/(e_line_second \&\& scan_frame) ? ROW_1_COL_0/e_line_second ? ROW_1_COL_0/'; then
    run mut_M4_row1_on_fields M4_row1_on_fields fail +case=field_lb
  else fail=1; fi
  # M5: the 5/6 step off by three 180ths, i.e. one sixtieth (drift down the picture)
  if mutate M5_r1_step "s/(scan_ratio == 3'd1) ? 8'd36 /(scan_ratio == 3'd1) ? 8'd39 /"; then
    run mut_M5_r1_step M5_r1_step_frame fail +case=frame_r +ratio=1 +lines=480
    run mut_M5_r1_step M5_r1_step_r2 pass +case=frame_r +ratio=2 +lines=360   # other ratios untouched
  else fail=1; fi
  # M6: no bottom-field phase (the bob the plan fixes); the frame path never uses it
  if mutate M6_no_bot_phase "s/: (h_pos == ROW_1_COL_0) ? bot_phase : 8'd0;/: 8'd0;/"; then
    run mut_M6_no_bot_phase M6_no_bot_phase fail +case=field_r +ratio=1 +lines=240
    run mut_M6_no_bot_phase M6_no_bot_phase_frame pass +case=frame_r +ratio=1 +lines=480
  else fail=1; fi
  # M7: the head follows the LIVE ratio instead of the scan's (a mid-scan change tears)
  if mutate M7_live_ratio "s/scan_ratio <= h_ratio;/scan_ratio <= vscale_ratio;/"; then
    run mut_M7_live_ratio M7_live_ratio fail +case=rtoggle
  else fail=1; fi
  # M8: weight without its rounding term (every non-integer blend lands one LSB low)
  if mutate M8_weight_floor "s/\* 15'd91 + 15'd32;/* 15'd91;/"; then
    run mut_M8_weight_floor M8_weight_floor fail +case=field_r +ratio=2 +lines=180
  else fail=1; fi
  # M9: ratio 0 given a bottom phase (3/4 must stay bit-identical in this change)
  if mutate M9_r0_phase "s/(h_ratio == 3'd4) ? 8'd10 : 8'd0;/(h_ratio == 3'd4) ? 8'd10 : 8'd30;/"; then
    run mut_M9_r0_phase M9_r0_phase fail +case=field_lb
  else fail=1; fi
  # --- To PAL (2026-11-09) ---
  # U1: no replay: a pair never gives its second line (the upscale comes out one line in six short)
  if mutate U1_no_replay "s/wire        rp_pair_due = scan_up \& up_room/wire        rp_pair_due = 1'b0 \& up_room/"; then
    run mut_U1_no_replay U1_no_replay fail +case=frame_r +ratio=3 +lines=576
    run mut_U1_no_replay U1_no_replay_r4 pass +case=field_r +ratio=4 +lines=216   # downscales never replay
  else fail=1; fi
  # U2: the replay blends the stale incoming pixel instead of buf2's line
  if mutate U2_replay_b "s/s3_rep ? b_q\[31:24\] : s3_by/s3_by/"; then
    run mut_U2_replay_b U2_replay_b fail +case=field_r +ratio=3 +lines=288
  else fail=1; fi
  # U3: no bottom-field clamp: the bottom field starts at 0 like the top (a bob on fine detail)
  if mutate U3_no_clamp "s/wire        e_upre       = h_ft ? (h_up \& (h_pos == ROW_1_COL_0)/wire        e_upre       = h_ft ? (1'b0 \& (h_pos == ROW_1_COL_0)/"; then
    run mut_U3_no_clamp U3_no_clamp fail +case=field_r +ratio=3 +lines=288
    run mut_U3_no_clamp U3_no_clamp_frame pass +case=frame_r +ratio=3 +lines=576   # a frame has no bottom start
  else fail=1; fi
  # U4: no tail: the scan stops short of the bottom of the raster
  if mutate U4_no_tail "s/wire        rp_tail_due = scan_up \& up_room/wire        rp_tail_due = 1'b0 \& up_room/"; then
    run mut_U4_no_tail U4_no_tail fail +case=frame_r +ratio=3 +lines=576
  else fail=1; fi
  # U5: the tail unbounded by N*6/5 (a bottom field would emit an extra line)
  if mutate U5_unbounded "s/wire        up_room    = (emitted_cnt < up_m);/wire        up_room    = 1'b1;/"; then
    run mut_U5_unbounded U5_unbounded fail +case=field_r +ratio=3 +lines=288
  else fail=1; fi
  # U6: 9/10 without its bottom phase; the frame path never uses it
  if mutate U6_r4_phase "s/(h_ratio == 3'd4) ? 8'd10 : 8'd0;/(h_ratio == 3'd4) ? 8'd0 : 8'd0;/"; then
    run mut_U6_r4_phase U6_r4_phase fail +case=field_r +ratio=4 +lines=216
    run mut_U6_r4_phase U6_r4_phase_frame pass +case=frame_r +ratio=4 +lines=432
  else fail=1; fi
  # U7: the replay reads the wrong linebuf bank for `a` (the tail's a = b broken)
  if mutate U7_tail_bank "s/{rp_tail ? wr_bank : rd_bank, rp_col\[9:0\]}/{rd_bank, rp_col[9:0]}/"; then
    run mut_U7_tail_bank U7_tail_bank fail +case=frame_r +ratio=3 +lines=576
  else fail=1; fi
  score
fi
[ $fail -eq 0 ] && echo "ALL OK" || { echo "SOME ARMS FAILED"; exit 1; }
