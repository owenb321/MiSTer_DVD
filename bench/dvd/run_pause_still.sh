#!/usr/bin/env bash
# Gate for the PAUSE FIELD STILL (2026-09-18, docs/field_parity.md "Pause shows one
# field"). See bench/dvd/pause_still_tb.sv for what is measured and why.
#
#   ./bench/dvd/run_pause_still.sh          GREEN arms
#   ./bench/dvd/run_pause_still.sh --red    + the RED arm (feature disabled = pre-fix
#                                             behaviour must FAIL the still phase) and
#                                             targeted mutations, each of which must fail
set -u
cd "$(dirname "$0")/../.."
OUT=.sim/pause_still; mkdir -p "$OUT"
SRC_COMMON="rtl/mpeg2/resample.v rtl/mpeg2/resample_dta.v rtl/mpeg2/resample_bilinear.v
 rtl/mpeg2/mem_addr.v rtl/mpeg2/mixer.v rtl/mpeg2/pixel_queue.v rtl/mpeg2/syncgen.v
 rtl/mpeg2/read_write.v rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xilinx_fifo_dc.v
 dvd/disp_hstretch.sv rtl/mpeg2/xfifo_sc.v bench/dvd/pause_still_tb.sv"
fail=0

build() {   # build <name> <addrgen.v> <disp_vscale.sv>
  iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o "$OUT/$1" $SRC_COMMON "$2" "$3" 2>"$OUT/$1.build.log" \
    || { echo "  BUILD FAILED: $1 (see $OUT/$1.build.log)"; return 1; }
}
# Runs are launched in the background and scored together at the end (each is ~1 min).
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

echo "== pause field still: GREEN arms"
build green dvd/resample_addrgen.v dvd/disp_vscale.sv || exit 1
run green interlaced_pin_top    pass +pin=0
run green interlaced_pin_bottom pass +pin=1
run green film_control_top      pass +pfr=1 +pin=0
run green film_control_bottom   pass +pfr=1 +pin=1
run green letterbox_pin_top     pass +lb=1 +pin=0
run green letterbox_pin_bottom  pass +lb=1 +pin=1
run green letterbox_film        pass +lb=1 +pfr=1 +pin=0

if [ "${1:-}" = "--red" ]; then
  echo "== RED: feature disabled (the pre-fix addrgen behaviour)"
  run green red_disabled_top    fail +still_en=0 +pin=0
  run green red_disabled_bottom fail +still_en=0 +pin=1
  run green red_disabled_lb     fail +still_en=0 +pin=0 +lb=1

  mutate() {  # mutate <name> <file> <sed-expr>
    local name=$1 file=$2 expr=$3 dst="$OUT/mut_$1_$(basename "$2")"
    sed "$expr" "$file" >"$dst"
    if cmp -s "$file" "$dst"; then echo "  FAIL  mutation $name did not apply" >&2; return 1; fi
    echo "$dst"
  }
  mut_run() { # mut_run <name> <file> <sed> <pin> [extra plusargs]
    local name=$1 file=$2 expr=$3 pinv=$4; shift 4
    local m; m=$(mutate "$name" "$file" "$expr") || { fail=1; return; }
    if [ "$file" = dvd/resample_addrgen.v ]; then build "mut_$name" "$m" dvd/disp_vscale.sv || { fail=1; return; }
    else build "mut_$name" dvd/resample_addrgen.v "$m" || { fail=1; return; }; fi
    run "mut_$name" "mut_$name" fail +pin="$pinv" "$@"
  }
  echo "== RED: mutations (each must fail)"
  # M1: the cur_ilace gate dropped -> a film pause would lose its weave
  mut_run M1_no_ilace_gate  dvd/resample_addrgen.v 's/cur_ilace && img0_field/img0_field/' 0 +pfr=1
  # M2: repeat-first/last swapped
  mut_run M2_rf_swapped     dvd/resample_addrgen.v 's/(half_rf ? (oline == 12.d0) : (oline >= (fld_H - 12.d1)))/(~half_rf ? (oline == 12'"'"'d0) : (oline >= (fld_H - 12'"'"'d1)))/' 1
  # M3: HALF blends with weight 0 (no interpolation)
  mut_run M3_half_f0        dvd/disp_vscale.sv 's/(e_mode == M_HALF) ? 8.d128/(e_mode == M_HALF) ? 8'"'"'d0/' 0
  # M4: lock not released by resume (pause term dropped)
  mut_run M4_lock_sticky    dvd/resample_addrgen.v 's/still_en \&\& pause \&\& ~step_arm/still_en \&\& ~step_arm/' 0
  # M5: the busy term dropped from routing (a scan can overtake a draining one)
  mut_run M5_no_busy_route  dvd/disp_vscale.sv 's/wire        ft_route = vscale_en | sb_half | path_busy;/wire        ft_route = vscale_en | sb_half;/' 0
  # M7: Letterbox's interpolated slot loses its half-line phase
  mut_run M7_lbh_no_phase   dvd/disp_vscale.sv 's/(h_mode == M_LBH) ? 3.d3 : 3.d0/3'"'"'d0/' 0 +lb=1
  # M8: the sixths weight table off by one step (plain Letterbox must catch it too)
  mut_run M8_f_sixths       dvd/disp_vscale.sv 's/(next_r == 3.d1) ? 8.d43 /(next_r == 3'"'"'d1) ? 8'"'"'d85 /' 1 +lb=1
  # M6: the pin taken from last_image (one scan stale -- the first cut's bug)
  mut_run M6_pin_stale      dvd/resample_addrgen.v 's/wire \[1:0\] just_shown  = .*/wire [1:0] just_shown  = last_image;/' 0
fi
score
[ $fail -eq 0 ] && echo "ALL OK" || { echo "SOME ARMS FAILED"; exit 1; }
