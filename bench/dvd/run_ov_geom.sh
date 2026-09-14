#!/usr/bin/env bash
#
# run_ov_geom.sh — overlay geometry on a NARROW DE window (VCD/SVCD over the progressive
# output): the window emu publishes, the HUD text box, the seek bar and the idle logo.
# Design: docs/transport_hud.md "Narrow windows", docs/vcd_svcd.md §5.
#
#   bash bench/dvd/run_ov_geom.sh          GREEN — everything must pass
#   bash bench/dvd/run_ov_geom.sh --red    every mutation must FAIL, and fail in ITS OWN arm
#
# ⚠ THE 720 ARMS ARE THE REGRESSION GATE AND THE NARROW ARMS ARE THE FEATURE. A change
# that fixed the narrow case by moving the full-width box would pass every narrow arm here
# and ship a visibly different HUD on every DVD, so both widths run on every invocation.
#
# ⚠ AND THE SHARPEST ARM IS [double] IN hud_frame_tb: it renders the SAME text twice, at
# 720 and at 352, and requires the narrow render to be the wide one with each column PAIR
# collapsed. Counting lit pixels inside a box cannot tell a correct narrow render from a
# plausible wrong one; that comparison can.
set -e
cd "$(dirname "$0")/../.."

SIM=/tmp/ovgeom_$$
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
  run "check_ov_geom_wiring" python3 tools/check_ov_geom_wiring.py

  echo "== the HUD text box: full width, then every narrow window =="
  iverilog -g2012 -o "$SIM.hud" dvd/transport_hud.sv bench/dvd/transport_hud_tb.sv
  run "transport_hud_tb  (720x480, the DVD case)" vvp "$SIM.hud"
  run "transport_hud_tb  (352x240, VCD NTSC)"     vvp "$SIM.hud" +act_w=352 +act_h=240
  run "transport_hud_tb  (352x288, VCD PAL)"      vvp "$SIM.hud" +act_w=352 +act_h=288
  run "transport_hud_tb  (480x480, SVCD)"         vvp "$SIM.hud" +act_w=480

  echo "== the pixel gate: box inside the window, and the doubling identity =="
  iverilog -g2012 -o "$SIM.hf" dvd/transport_hud.sv dvd/subpic_blend.sv bench/dvd/hud_frame_tb.sv
  run "hud_frame_tb      (720x480 + [narrow] + [double])" vvp "$SIM.hf"
  run "hud_frame_tb      (480x480, SVCD)"                 vvp "$SIM.hf" +act_w=480
  run "hud_frame_tb      (352x240, VCD)"                  vvp "$SIM.hf" +act_w=352 +act_h=240

  echo "== the seek bar: same box, and the 0..511 column space re-sampled =="
  iverilog -g2012 -o "$SIM.bar" dvd/seek_bar.sv bench/dvd/seek_bar_tb.sv
  # ⚠ ONE invocation on purpose: T1..T11 are full-width arms and T12 drives the narrow
  # widths itself, sweeping both 352 (VCD) and 480 (SVCD). A +act_w run would put the
  # full-width arms in a narrow window and fail them against correct RTL.
  run "seek_bar_tb       (720 + T12 narrow 352/480)" vvp "$SIM.bar"

  echo "== the idle logo: the bounce box IS the window (screensaver + Stop show it) =="
  iverilog -g2012 -o "$SIM.logo" dvd/idle_logo.sv bench/dvd/idle_logo_tb.sv
  # ⚠ Every window the SCREENSAVER and STOP can be up in, not just the idle one: T1 and
  # T18b each fly the logo for 20,000 frame ticks and fail on any excursion, so a window
  # whose box underflowed or collapsed is caught rather than reasoned about.
  run "idle_logo_tb      (720x480 + T18 narrow)"  vvp "$SIM.logo"
  run "idle_logo_tb      (352x240, VCD prog)"     vvp "$SIM.logo" +act_w=352 +act_h=240
  run "idle_logo_tb      (352x288, VCD PAL prog)" vvp "$SIM.logo" +act_w=352 +act_h=288
  run "idle_logo_tb      (480x480, SVCD prog)"    vvp "$SIM.logo" +act_w=480
  run "idle_logo_tb      (720x240, VCD 240p)"     vvp "$SIM.logo" +act_h=240
  run "idle_logo_tb      (720x288, VCD 288p)"     vvp "$SIM.logo" +act_h=288

  echo "== the frame renders, unchanged (no regression at full width) =="
  iverilog -g2012 -o "$SIM.if" dvd/idle_logo.sv dvd/subpic_blend.sv bench/dvd/idle_frame_tb.sv
  run "idle_frame_tb     (bit-exact vs the mask)" vvp "$SIM.if"

  echo
  echo "ov_geom: $pass passed, $fail failed"
  rm -f "$SIM".*
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# RED — each mutation must make its OWN arm fail.
#
# ⚠ A sed pattern that no longer matches produces an UNMUTATED copy, which then PASSES
# and silently turns a RED arm into a second GREEN one (this has happened twice in this
# tree), so every mutation verifies that the file actually CHANGED before it is used.
# ---------------------------------------------------------------------------
redfail=0
mut=/tmp/ovgeom_mut_$$.sv
mut_emu=/tmp/ovgeom_emu_$$.sv

# ⚠ The emu mutations edit dvd/emu.sv IN PLACE and restore it. Without this trap a Ctrl-C
# mid-arm leaves a MUTATED emu.sv in the working tree, and the mutation it leaves behind
# (a window tied to 720) is exactly the kind nothing else fails on.
restore_emu() {
  if [ -f "$mut_emu.orig" ]; then
    cp "$mut_emu.orig" dvd/emu.sv
    echo "  (restored dvd/emu.sv)"
  fi
  rm -f "$mut" "$mut_emu" "$mut_emu.orig"
}
trap restore_emu EXIT INT TERM

# rtl_red <label> <module file> <sed program> <bench file> <plusargs...>
rtl_red() {
  local label="$1" src="$2" prog="$3" tb="$4"; shift 4
  echo "== RED [$label] =="
  sed "$prog" "$src" > "$mut"
  if cmp -s "$src" "$mut"; then
    echo "  FAIL: the mutation did not change $src (stale sed pattern)"
    redfail=$((redfail+1)); return
  fi
  if ! iverilog -g2012 -o "$SIM.red" "$mut" $EXTRA "$tb" 2>"$SIM.cerr"; then
    # ⚠ A mutation that does not COMPILE is not a caught mutation -- it proves nothing
    # about the arm. (run_spu_window.sh shipped two arms that "passed" on a build error.)
    echo "  FAIL: the mutated $src does not compile"
    head -5 "$SIM.cerr"
    redfail=$((redfail+1)); return
  fi
  if vvp "$SIM.red" "$@" > /dev/null 2>&1; then
    echo "  FAIL: the bench PASSED a mutated $src"
    redfail=$((redfail+1))
  else
    echo "  ok   caught"
  fi
}

emu_red() {   # $1 = label, $2 = sed program
  echo "== RED [emu: $1] =="
  sed "$2" dvd/emu.sv > "$mut_emu"
  if cmp -s dvd/emu.sv "$mut_emu"; then
    echo "  FAIL: the mutation did not change dvd/emu.sv (stale sed pattern)"
    redfail=$((redfail+1)); return
  fi
  cp dvd/emu.sv "$mut_emu.orig"; cp "$mut_emu" dvd/emu.sv
  if python3 tools/check_ov_geom_wiring.py > /dev/null 2>&1; then
    echo "  FAIL: check_ov_geom_wiring PASSED a mutated emu.sv"
    redfail=$((redfail+1))
  else
    echo "  ok   caught"
  fi
  cp "$mut_emu.orig" dvd/emu.sv
}

# ---- the HUD box ----------------------------------------------------------
# M1 — THE BUG ITSELF: the box back at a fixed 720-authored origin. On a 352-wide window
#      the text falls outside the picture, which is the reported "VCD has no HUD".
EXTRA="dvd/subpic_blend.sv" rtl_red "M1 HUD box back at the fixed X0=104/512" dvd/transport_hud.sv \
  "s|            hs2_q <= (act_w_i >= HS2_MIN);|            hs2_q <= 1'b1;|; \
   s|            x0_q  <= ((act_w_i >= HS2_MIN) ? (act_w_i - 12'd512) : (act_w_i - 12'd256)) >> 1;|            x0_q  <= 12'd104;|; \
   s|            x1_q  <= (((act_w_i >= HS2_MIN) ? (act_w_i - 12'd512) : (act_w_i - 12'd256)) >> 1)|            x1_q  <= 12'd616;\n            if (1'b0) x1_q  <= (((act_w_i >= HS2_MIN) ? (act_w_i - 12'd512) : (act_w_i - 12'd256)) >> 1)|" \
  bench/dvd/hud_frame_tb.sv +act_w=352 +act_h=240

# M2 — THE SVCD HALF OF THE REPORT: the fixed 512 px box in a 480 px window, so the right
#      of the status line is drawn where the picture has no pixels.
EXTRA="dvd/subpic_blend.sv" rtl_red "M2 HUD box overruns a 480-wide window" dvd/transport_hud.sv \
  "s|            x0_q  <= ((act_w_i >= HS2_MIN) ? (act_w_i - 12'd512) : (act_w_i - 12'd256)) >> 1;|            x0_q  <= 12'd104;|; \
   s|            x1_q  <= (((act_w_i >= HS2_MIN) ? (act_w_i - 12'd512) : (act_w_i - 12'd256)) >> 1)|            x1_q  <= 12'd616;\n            if (1'b0) x1_q  <= (((act_w_i >= HS2_MIN) ? (act_w_i - 12'd512) : (act_w_i - 12'd256)) >> 1)|" \
  bench/dvd/hud_frame_tb.sv +act_w=480

# M2b — the box narrows correctly but keeps the 2x glyph pitch, so only the first 16 cells
#       are drawn. It sits ENTIRELY inside the window and passes every count check; only
#       the doubling identity can see it.
EXTRA="dvd/subpic_blend.sv" rtl_red "M2b HUD narrows the box but keeps the 2x pitch" dvd/transport_hud.sv \
  "s|            hs2_q <= (act_w_i >= HS2_MIN);|            hs2_q <= 1'b1;|" \
  bench/dvd/hud_frame_tb.sv

# M3 — the pitch drops but the glyph column walk does not follow, so the narrow render is
#      the LEFT HALF of the text rather than the whole line at half pitch. Every count
#      check still passes; only [double] can see it.
EXTRA="dvd/subpic_blend.sv" rtl_red "M3 narrow pitch draws the left half, not the whole line" dvd/transport_hud.sv \
  "s|            s0_col <= hs2_q ? hx\[8:4\] : hx\[7:3\];|            s0_col <= hx[8:4];|; \
   s|            s0_gx  <= hs2_q ? hx\[3:1\] : hx\[2:0\];|            s0_gx  <= hx[3:1];|" \
  bench/dvd/hud_frame_tb.sv

# ---- the seek bar ---------------------------------------------------------
# M4 — the bar narrows but its 0..511 column space is not re-sampled: it draws the left
#      half of the bar, so the fill edge, the cursor and the notches are all at 2x their
#      true position.
EXTRA="" rtl_red "M4 seek bar narrows without re-mapping its columns" dvd/seek_bar.sv \
  "s|    wire \[9:0\]  hcol = hs2_q ? hx\[9:0\] : {hx\[8:0\], 1'b0};|    wire [9:0]  hcol = hx[9:0];|" \
  bench/dvd/seek_bar_tb.sv

# M5 — the odd sibling dropped from the notch read: every notch whose column pair starts
#      odd disappears at the narrow pitch (3 of the 4 in T12f).
# ⚠ delimiter is @ here, not | -- the expression being mutated CONTAINS a bitwise |.
EXTRA="" rtl_red "M5 seek bar notch read loses the odd sibling" dvd/seek_bar.sv \
  "s@(~hs2_q & tick_bm\[hcol\[8:0\] | 9'd1\]);@1'b0;@" \
  bench/dvd/seek_bar_tb.sv

# ---- the idle logo --------------------------------------------------------
# M6 — the bounce box back at a literal 720: on a VCD the logo wanders ~368 px off the
#      right of the picture. ⚠ The logo is NOT idle-only -- the screensaver and Stop both
#      show it over a mounted, playing title, i.e. over a VCD.
EXTRA="" rtl_red "M6 idle logo bounce box back at 720" dvd/idle_logo.sv \
  "s|wire \[11:0\] x_hi = (act_w_i > w2) ? act_w_i - w2 : 12'd0;|wire [11:0] x_hi = 12'd720 - w2;|" \
  bench/dvd/idle_logo_tb.sv

# M7 — a 2x logo too large for the window is no longer demoted, so its box is wider than
#      the screen and the clamp pins it at 0 with nowhere to bounce.
# ⚠ delimiter @ again, and BOTH lines of the expression must go -- dropping only the
# first leaves a dangling continuation that does not compile, which is not a caught
# mutation, it is a broken arm.
EXTRA="" rtl_red "M7 oversized 2x logo not forced native" dvd/idle_logo.sv \
  "s@= u_scale1x | ({2'd0, u_w, 1'b0} > act_w_i)@= u_scale1x@; \
   s@| ({4'd0, u_h, 1'b0} > act_h_i);@;@" \
  bench/dvd/idle_logo_tb.sv

# ---- emu: the values on the wires ----------------------------------------
# M8 — the width tied to the raster instead of the picture. THE PORTS ARE ALL STILL THERE
#      and every module bench still passes; this is the shape the defect actually had.
emu_red "M8 act_w_eff tied to a constant 720" \
  "s|assign      act_w_eff = (sif_hfill_eff \|\| hsz_s2 == 14'd0 \|\| hsz_s2 >= 14'd720) ? 12'd720|assign      act_w_eff = (1'b1) ? 12'd720|"

# M9 — the height back to the raster resolution (the pre-fix value): correct on a DVD,
#      480 on a 240-line VCD, which puts the whole HUD below the bottom of the picture.
emu_red "M9 act_h_eff back to the raster resolution" \
  "s|assign      act_h_eff = (vsz_eff == 14'd0 \|\| vsz_eff >= {2'b0, act_vres}) ? act_vres|assign      act_h_eff = (1'b1) ? act_vres|"

# M10 — an overlay loses the width connection (Quartus would tie the port low = a 0-wide
#       window). idle_logo is picked deliberately: it is the one a reader is most likely
#       to think of as idle-only and therefore exempt.
emu_red "M10 idle_logo loses .act_w_i" \
  "s|    \.act_w_i        (act_w_eff),||"

# M11 — the vertical fill transform dropped, so an interlaced SIF disc mid-debounce (line
#       repeat ON, 240p verdict not yet latched) would anchor to 240 on a 480-line window.
emu_red "M11 vsz_eff drops the 2x line-repeat transform" \
  "s|wire \[13:0\] vsz_eff   = sif_v2x_eff ? {vsz_s2\[12:0\], 1'b0} : vsz_s2;|wire [13:0] vsz_eff   = vsz_s2;|"

rm -f "$SIM".* "$mut"
echo
if [ "$redfail" -eq 0 ]; then
  echo "ov_geom RED: all mutations caught"
else
  echo "ov_geom RED: $redfail mutation(s) NOT caught"
  exit 1
fi
