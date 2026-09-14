#!/usr/bin/env bash
#
# run_p240.sh — native 240p/288p: the raster, its composite sync, the detector that
# selects it, the overlays that anchor to it, and the emu wiring that connects them.
# Design: docs/mpeg1.md §B.3a.
#
#   bash bench/dvd/run_p240.sh          GREEN — everything must pass
#   bash bench/dvd/run_p240.sh --red    every mutation must FAIL, and fail in ITS OWN arm
#
# ⚠ THE RED ARMS ARE THE POINT. Most of what this feature does is turn things OFF
# (the vertical line repeat, the half-line, the interlaced bit, the field flag), and a
# check that something is off passes just as happily when the whole feature is absent.
# Every GREEN check below therefore has a mutation that must break it.
set -e
cd "$(dirname "$0")/../.."

SIM=/tmp/p240_$$
pass=0; fail=0
ok()   { echo "  ok   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }

run() {  # $1 = label, rest = command
  local label="$1"; shift
  if "$@" > "$SIM.log" 2>&1; then ok "$label"; else bad "$label"; tail -20 "$SIM.log"; fi
}

# ---------------------------------------------------------------------------
# GREEN
# ---------------------------------------------------------------------------
if [ "${1:-}" != "--red" ]; then
  echo "== emu wiring (dvd/emu.sv read directly -- emu has no bench) =="
  run "check_p240_wiring" python3 tools/check_p240_wiring.py

  echo "== the raster: 262/312 lines, progressive, constant rate =="
  iverilog -g2012 -I rtl/mpeg2 -o "$SIM.csg" rtl/mpeg2/syncgen.v bench/dvd/crt_syncgen_tb.sv
  run "crt_syncgen_tb (PHASE 1-7, incl. 240p/288p)" vvp "$SIM.csg"

  echo "== composite sync on the progressive raster =="
  iverilog -g2012 -I rtl/mpeg2 -o "$SIM.cs" rtl/mpeg2/syncgen.v dvd/csync_smpte.sv bench/dvd/csync_p240_tb.sv
  run "csync_p240_tb NTSC 240p" vvp "$SIM.cs"
  run "csync_p240_tb PAL  288p" vvp "$SIM.cs" +pal=1

  echo "== the detector: one timer, two verdicts =="
  iverilog -g2012 -o "$SIM.pd" dvd/pal_detect.sv bench/dvd/pal_detect_tb.sv
  run "pal_detect_tb (13 scenarios)" vvp "$SIM.pd"

  echo "== the overlays bottom-anchor to the real active height =="
  iverilog -g2012 -o "$SIM.hud" dvd/transport_hud.sv bench/dvd/transport_hud_tb.sv
  run "transport_hud_tb  (480)" vvp "$SIM.hud"
  run "transport_hud_tb  (240)" vvp "$SIM.hud" +act_h=240
  iverilog -g2012 -o "$SIM.bar" dvd/seek_bar.sv bench/dvd/seek_bar_tb.sv
  run "seek_bar_tb       (480)" vvp "$SIM.bar"
  run "seek_bar_tb       (240)" vvp "$SIM.bar" +act_h=240
  iverilog -g2012 -o "$SIM.logo" dvd/idle_logo.sv bench/dvd/idle_logo_tb.sv
  run "idle_logo_tb      (480)" vvp "$SIM.logo"
  run "idle_logo_tb      (240)" vvp "$SIM.logo" +act_h=240

  echo
  echo "p240: $pass passed, $fail failed"
  rm -f "$SIM".*
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# RED — each mutation must make its OWN arm fail.
#
# ⚠ A sed pattern that no longer matches produces an UNMUTATED copy, which then PASSES
# and silently turns a RED arm into a second GREEN one. That has already happened in
# run_csync_field.sh (a `fpar` -> `fpar_now` rename), so every mutation here verifies
# that the file actually CHANGED before it is used.
# ---------------------------------------------------------------------------
redfail=0
mut_emu=/tmp/p240_emu_$$.sv
mut_pd=/tmp/p240_pd_$$.sv

# ⚠ The emu mutations edit dvd/emu.sv IN PLACE and restore it. Without this trap a Ctrl-C
# or a failing command mid-arm leaves a MUTATED emu.sv in the working tree -- which would
# then be committed, and the mutation it leaves behind (a dead p240 arm, a raw-tap engage)
# is exactly the kind that nothing else fails on.
restore_emu() {
  if [ -f "$mut_emu.orig" ]; then
    cp "$mut_emu.orig" dvd/emu.sv
    echo "  (restored dvd/emu.sv)"
  fi
  rm -f "$mut_emu" "$mut_emu.orig" "$mut_pd"
}
trap restore_emu EXIT INT TERM

emu_red() {   # $1 = label, $2 = sed program
  echo "== RED [emu: $1] =="
  sed "$2" dvd/emu.sv > "$mut_emu"
  if cmp -s dvd/emu.sv "$mut_emu"; then
    echo "  FAIL: the mutation did not change dvd/emu.sv (stale sed pattern)"
    redfail=$((redfail+1)); return
  fi
  cp dvd/emu.sv "$mut_emu.orig"; cp "$mut_emu" dvd/emu.sv
  if python3 tools/check_p240_wiring.py > /dev/null 2>&1; then
    echo "  FAIL: check_p240_wiring PASSED a mutated emu.sv"
    redfail=$((redfail+1))
  else
    echo "  ok   caught"
  fi
  cp "$mut_emu.orig" dvd/emu.sv
}

# M1 — THE ORDERING TRAP. p240_prev implies il_prev, so moving the p240 arm after the
# il arm makes it dead code: the raster silently stays 480i and nothing else fails.
emu_red "M1 p240 VERT_RES arm after the il arm" \
  "s|: p240_prev   ? {4'b0, 12'd240, 4'b0, 12'd261}   // NTSC 240p: 262 lines => 60.055 Hz||; \
   s|: il_prev     ? {4'b0, 12'd480, 4'b0, 12'd261}   // 262 lines/field|: il_prev     ? {4'b0, 12'd480, 4'b0, 12'd261}\n                            : p240_prev   ? {4'b0, 12'd240, 4'b0, 12'd261}|"

# M2 — the feature itself: leave the nearest-neighbour line repeat on.
emu_red "M2 vertical line repeat left on at 240p" \
  "s|wire sif_v2x_eff   = interlaced_eff & sif_v_s2 & ~p240_eff;|wire sif_v2x_eff   = interlaced_eff \& sif_v_s2;|"

# M3 — drop pixel repetition from the 240p VID_MODE write: a 31.5 kHz line no CRT takes.
emu_red "M3 240p VID_MODE loses pixrep (3'b010 -> 3'b000)" \
  "s|p240_prev ? {4'b0, 12'd0,   13'b0, 3'b010}|p240_prev ? {4'b0, 12'd0,   13'b0, 3'b000}|"

# M4 — drive the raster from the RAW size tap instead of the debounced verdict.
emu_red "M4 p240_eff from the raw sif_v_s2 tap" \
  "s|assign p240_eff = interlaced_eff \& sif_det_s2;|assign p240_eff = interlaced_eff \& sif_v_s2;|"

# M5 — a field consumer left on il_eff: VGA_F1 would tag a progressive frame as a field.
emu_red "M5 VGA_F1 back on il_eff" \
  "s|assign VGA_F1       = fields_eff ?|assign VGA_F1       = il_eff ?|"

# M6 — the raster change bypasses mode_realign (straight into the fallback flush).
emu_red "M6 mode_realign loses the p240 edge" \
  "s|\.mode_edge       (il_switch \| p240_switch),|.mode_edge       (il_switch),|"

# M7 — an overlay keeps deriving its own height.
emu_red "M7 seek_bar loses act_h_eff" \
  "s|    \.act_h_i    (act_h_eff),||"

# M8 — the HORIZONTAL fill wrongly removed too (it must stay: a CRT needs full width).
emu_red "M8 horizontal fill switched off at 240p" \
  "s|wire sif_hfill_eff = interlaced_eff \& sif_h_s2;|wire sif_hfill_eff = interlaced_eff \& sif_h_s2 \& ~p240_eff;|"

# M9 — Analog Aspect left reachable at 240p: crt_ov_map would draw 480-line bars on a
# 240-line raster and map the overlay inverse into the wrong rows.
emu_red "M9 Letterbox left reachable at 240p" \
  "s|assign analog_letterbox = interlaced_eff \& ~p240_eff \&|assign analog_letterbox = interlaced_eff \&|"

# ---- detector mutations ---------------------------------------------------
pd_red() {   # $1 = label, $2 = sed program, $3 = plusargs
  echo "== RED [pal_detect: $1] =="
  sed "$2" dvd/pal_detect.sv > "$mut_pd"
  if cmp -s dvd/pal_detect.sv "$mut_pd"; then
    echo "  FAIL: the mutation did not change dvd/pal_detect.sv (stale sed pattern)"
    redfail=$((redfail+1)); return
  fi
  iverilog -g2012 -o "$SIM.pdred" "$mut_pd" bench/dvd/pal_detect_tb.sv 2>/dev/null
  if vvp "$SIM.pdred" $3 > /dev/null 2>&1; then
    echo "  FAIL: pal_detect_tb PASSED a mutated detector"
    redfail=$((redfail+1))
  else
    echo "  ok   caught"
  fi
}

# S1 — wrong bound: 480 would read as SIF and every DVD would take the 240p raster.
pd_red "S1 sif bound 288 -> 480" "s|wire vs_sif   = (vsize <= 14'd288);|wire vs_sif   = (vsize <= 14'd480);|"
# S2 — sif tied to pal: 240 (NTSC, SIF) and 576 (PAL, not SIF) both become wrong.
pd_red "S2 sif tied to the pal verdict" "s|assign sif   = vq\[1\];|assign sif   = vq[0];|"
# S3 — the verdict pair stops being compared as a pair, so only pal is debounced and a
#      stray header moves sif at once.
pd_red "S3 disagreement tested on pal alone" "s|if (!vs_plaus \|\| (vs_q == vq))|if (!vs_plaus \|\| (vs_q[0] == vq[0]))|"

# ---- csync mutation -------------------------------------------------------
echo "== RED [csync: C1 blk_half not forced on a progressive raster] =="
iverilog -g2012 -I rtl/mpeg2 -o "$SIM.csred" rtl/mpeg2/syncgen.v dvd/csync_smpte.sv bench/dvd/csync_p240_tb.sv 2>/dev/null
c1=0
vvp "$SIM.csred" +red_half=1        > /dev/null 2>&1 || c1=$((c1+1))
vvp "$SIM.csred" +pal=1 +red_half=1 > /dev/null 2>&1 || c1=$((c1+1))
if [ "$c1" -eq 2 ]; then echo "  ok   caught on both standards"; else
  echo "  FAIL: the half-line RED arm did not fail on both standards ($c1/2)"
  redfail=$((redfail+1)); fi

# ---- raster mutation ------------------------------------------------------
echo "== RED [raster: R1 240p phase left interlaced] =="
mut_sg=/tmp/p240_sg_$$.sv
sed "s|    horizontal_halfline   = 12'd0;    interlaced            = 1'b0;\n    horizontal_size = 14'd1440;  vertical_size = 14'd240;|X|" bench/dvd/crt_syncgen_tb.sv > /dev/null
sed "s|horizontal_halfline   = 12'd0;    interlaced            = 1'b0;|horizontal_halfline   = 12'd858;  interlaced            = 1'b1;|" bench/dvd/crt_syncgen_tb.sv > "$mut_sg"
if cmp -s bench/dvd/crt_syncgen_tb.sv "$mut_sg"; then
  echo "  FAIL: the mutation did not change the bench (stale sed pattern)"
  redfail=$((redfail+1))
else
  iverilog -g2012 -I rtl/mpeg2 -o "$SIM.sgred" rtl/mpeg2/syncgen.v "$mut_sg" 2>/dev/null
  if vvp "$SIM.sgred" > /dev/null 2>&1; then
    echo "  FAIL: crt_syncgen_tb PASSED an interlaced 240p phase"
    redfail=$((redfail+1))
  else
    echo "  ok   caught"
  fi
fi

rm -f "$SIM".* "$mut_emu" "$mut_emu.orig" "$mut_pd" "$mut_sg"
echo
if [ "$redfail" -eq 0 ]; then
  echo "p240 RED: all mutations caught"
else
  echo "p240 RED: $redfail mutation(s) NOT caught"
  exit 1
fi
