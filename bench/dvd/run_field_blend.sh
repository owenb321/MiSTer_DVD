#!/usr/bin/env bash
#
# run_field_blend.sh -- gate for the non-adaptive field blend on the Progressive
# raster (docs/field_blend.md; dvd/field_blend.sv, the addrgen's H+1 emission and
# sideband). Structure adapted from Stage A's run_deint.sh (feature/deinterlace).
#
# GREEN
#   field_blend_tb        the module, BIT-EXACT against tools/field_blend_model.py on
#                         a synthetic fixture (regenerated every run) and, when the ISO
#                         is reachable, a real Thayer's Quest frame; with backpressure;
#                         plus the PLAIN bypass                              [K1..K4]
#   field_blend_chain_tb  the real display chain over a (line, macroblock)-stamped
#                         framestore: kernel, both mirrored edges, H+1 in / H out,
#                         row codes, held picture byte-identical, film control, order
#                         across a blend->film switch, a paused step, the fields arm
#                                                                            [C1..C8]
#   PROGRESSIVE BOB (docs/field_blend.md "Bob"): field_blend_tb +bob=1|2 against the
#   model's .bobt/.bobb expectations (both kept fields, backpressure, Thayer), and the
#   chain +bob=1 (pickup scans keep the first field [C9], held re-scans the second and
#   are byte-identical [C1 C5], film untouched [C4], the fields arm unmarked [C8],
#   both kinds of scan actually scored [C10])
#
# --red  each arm must FAIL exactly where designed:
#   RED-K  -Pfield_blend_tb.BLEND=0 (the pre-feature weave) vs the model   -> K1
#   RED-C  +blend_en=0 (the option off) in the chain                       -> C1 C1B C1T
#   MK1  bob kernel ((a+d+1)>>1)                                          -> K1
#   MK2  the +2 rounding dropped                                          -> K1
#   MK3  a 9-bit sum (the kernel overflows on bright content)             -> K1
#   MK4  top edge replicate (a := b) instead of mirror                    -> K1
#   MK5  OSD blended                                                      -> K1
#   MK6  line 1 re-coded ROW_X_COL_0 instead of ROW_1_COL_0               -> K3
#   MC1  addrgen: no H+1 line                                             -> C2
#   MC2  addrgen: the extra line repeats H-1 (Stage A's replicate)         -> C1B
#   MC3  addrgen: cur_ilace gate removed (film blends)                    -> C4
#   MC4  field_blend: PLAIN routing term dropped (a film scan overtakes)  -> C2
#   MC5  field_blend: in_prev_row0 removed (a FRAME's line 1 = new scan)  -> C1 C1B C1T C2 C3
#        (it splits every scan in two, so every arm sees it -- measured, and kept as
#        the exact set: C3 is the one that names the cause)
#   MC7  field_blend: a per-SCAN toggle in the kernel (the LSB flips at each frame
#        top) -- the class of per-refresh state that made Stage A shimmer   -> C1 C1B C1T C5
#   MB1  bob: rebuilt line without the +1 rounding                        -> K1 (bob fixture)
#   MB2  bob: the kept line chosen by the wrong output-line parity         -> K1 (bob fixture)
#   MB3  addrgen: kept field inverted (first <-> second)                  -> C1 C1B C1T C9
#   MB4  addrgen: the kept field ALTERNATES on every re-scan -- the hold flicker
#        a steady second field exists to prevent                         -> C1 C1B C1T C5
#   MB5  addrgen: top_field_first ignored (always TOP first), under +tff=0 -> C1 C1B C1T C9
#   MB6  addrgen: cur_ilace gate removed, bob on film (+pfr=1)             -> C4
#   (no mutation for p2_valid in the idle term: r_wr follows it one cycle later and
#    the idle counter holds 7 cycles, so its removal cannot release the path early --
#    measured surviving. Defence in depth, not a gate.)
#   (no mutation for the addrgen's `deinterlace && ~interlaced` term: on the fields arm
#    every image is TOP/BOTTOM, so `image_0 == FRAME` already excludes it and no bench
#    can see the term's removal -- it is defence in depth. The +ilace arm [C8] stands as
#    the structural confirmation, not as a mutation target.)
#   The exact arm sets are the ARMS strings below; they were measured, and the runner
#   requires EXACTLY them, so a mutation caught by everything cannot hide which arm is
#   load-bearing.
# ⚠ every sed must prove it applied (cmp) and every mutant must compile. The verdict
#   is the RESULT line plus the exit status, never a pipe.
set -u
cd "$(dirname "$0")/../.."
OUT=.sim/field_blend; mkdir -p "$OUT"
FX=bench/dvd/test_vobs; mkdir -p "$FX"
IV="iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2"
MOD_SRC="rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xilinx_fifo_dc.v rtl/mpeg2/xfifo_sc.v
 bench/dvd/field_blend_tb.sv"
CHAIN_SRC="rtl/mpeg2/resample.v rtl/mpeg2/resample_dta.v rtl/mpeg2/resample_bilinear.v
 rtl/mpeg2/mem_addr.v rtl/mpeg2/mixer.v rtl/mpeg2/pixel_queue.v rtl/mpeg2/syncgen.v
 rtl/mpeg2/read_write.v rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xilinx_fifo_dc.v
 rtl/mpeg2/xfifo_sc.v dvd/disp_hstretch.sv dvd/disp_vscale.sv bench/dvd/field_blend_chain_tb.sv"
RED=0; [ "${1:-}" = "--red" ] && RED=1
fail=0

python3 tools/field_blend_model.py synth --out "$FX/fblend_synth" >/dev/null || { echo "model failed"; exit 1; }
THAYER=""
ISO="${FBLEND_ISO:-}"     # (the apostrophe in the disc's name must not sit inside a ${:-} word)
[ -z "$ISO" ] && ISO="${DVD_ISO_DIR:-/mnt/dvd}/interactive/Thayer's Quest.iso"
# ⚠ ALWAYS re-cut when the ISO is reachable: a cached expectation describes whatever
# the model said when it was written, not what it says now.
if [ -f "$ISO" ] && command -v ffmpeg >/dev/null; then
  if python3 tools/field_blend_model.py fixture "$ISO" --vts 1 --frac 0.10 --lines 96 --out "$FX/fblend_thayer" >"$OUT/thayer_fixture.log" 2>&1; then
    THAYER="$FX/fblend_thayer"; tail -1 "$OUT/thayer_fixture.log"
  else echo "  (Thayer fixture not cut: $(tail -1 "$OUT/thayer_fixture.log"))"; fi
else echo "  SKIP real-frame arm: no Thayer ISO at $ISO (set FBLEND_ISO)"; fi

build() {  # build <name> <sources...>
  local name=$1; shift
  $IV -o "$OUT/$name" "$@" 2>"$OUT/$name.build.log" || { echo "  BUILD FAILED: $name (see $OUT/$name.build.log)"; fail=1; return 1; }
}
# Runs are LAUNCHED in the background (a chain run is ~1 min) and SCORED afterwards.
# launch <sim> <label> <want pass|fail> <arms or -> <plusargs...>
PLAN=()
launch() {
  local sim=$1 label=$2 want=$3 arms=$4; shift 4
  [ -f "$OUT/$sim" ] || { echo "  FAIL  $label: no build"; fail=1; return; }
  ( vvp -n "$OUT/$sim" "$@" >"$OUT/$label.log" 2>&1; echo $? >"$OUT/$label.rc" ) &
  PLAN+=("$label|$want|$arms")
}
score() {
  wait
  local e label want arms rc got ids
  for e in "${PLAN[@]}"; do
    IFS='|' read -r label want arms <<<"$e"
    rc=$(cat "$OUT/$label.rc" 2>/dev/null || echo 99)
    got=fail; if [ "$rc" = 0 ] && grep -q '^RESULT: PASS' "$OUT/$label.log"; then got=pass; fi
    ids=$(grep -oE '^FAIL: \[[A-Z][0-9]+[A-Z]?\]' "$OUT/$label.log" | grep -oE '[A-Z][0-9]+[A-Z]?' | sort -u | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" != "$want" ]; then echo "  FAIL  $label: want $want, got $got [$ids] (see $OUT/$label.log)"; fail=1; continue; fi
    if [ "$arms" != "-" ] && [ "$ids" != "$arms" ]; then echo "  FAIL  $label: failing arms [$ids], designed [$arms]"; fail=1; continue; fi
    echo "  ok    $label ($got${ids:+ [$ids]})"
  done
  PLAN=()
}
# mod_args <stem> [bobt|bobb]: the blend expectation, or a bob one (keep TOP / BOTTOM).
# ⚠ $value$plusargs takes the FIRST match, so there is exactly one +exp per arm.
mod_args() {
  case "${2:-}" in
    bobt) echo "+in=$1.in.hex +exp=$1.bobt.exp.hex +meta=$1.meta.hex +bob=1";;
    bobb) echo "+in=$1.in.hex +exp=$1.bobb.exp.hex +meta=$1.meta.hex +bob=2";;
    *)    echo "+in=$1.in.hex +exp=$1.exp.hex +meta=$1.meta.hex";;
  esac
}
mutate() {  # mutate <name> <file> <sed> -> path of the mutant (proves it applied)
  local dst="$OUT/mut_$1_$(basename "$2")"
  sed "$3" "$2" >"$dst"
  if cmp -s "$2" "$dst"; then echo "  FAIL  mutation $1 did not apply" >&2; return 1; fi
  echo "$dst"
}

echo "== field_blend: wiring (tools/check_field_blend_wiring.py) =="
python3 tools/check_field_blend_wiring.py | sed 's/^/  /' || fail=1
[ "${PIPESTATUS[0]}" = 0 ] || fail=1

echo "== field_blend: GREEN =="
build mod dvd/field_blend.sv $MOD_SRC
build chain dvd/field_blend.sv dvd/resample_addrgen.v $CHAIN_SRC
launch mod mod_synth        pass - $(mod_args "$FX/fblend_synth")
launch mod mod_synth_stall  pass - $(mod_args "$FX/fblend_synth") +stall=5
launch mod mod_plain        pass - $(mod_args "$FX/fblend_synth") +plain=1 +stall=5
[ -n "$THAYER" ] && launch mod mod_thayer pass - $(mod_args "$THAYER") +stall=7
launch chain chain_default pass -
launch chain chain_tff0    pass - +tff=0
launch chain chain_film    pass - +pfr=1
launch chain chain_mix     pass - +mix=1
launch chain chain_pause   pass - +pause=1
launch chain chain_ilace   pass - +ilace=1
launch mod mod_bobt        pass - $(mod_args "$FX/fblend_synth" bobt)
launch mod mod_bobb_stall  pass - $(mod_args "$FX/fblend_synth" bobb) +stall=5
launch mod mod_bobt_stall  pass - $(mod_args "$FX/fblend_synth" bobt) +stall=5
[ -n "$THAYER" ] && launch mod mod_thayer_bobb pass - $(mod_args "$THAYER" bobb) +stall=7
launch chain chain_bob      pass - +bob=1
launch chain chain_bob_tff0 pass - +bob=1 +tff=0
launch chain chain_bob_film pass - +bob=1 +pfr=1
launch chain chain_bob_mix  pass - +bob=1 +mix=1
launch chain chain_bob_pause pass - +bob=1 +pause=1
launch chain chain_bob_ilace pass - +bob=1 +ilace=1
score

if [ $RED = 1 ]; then
  echo "== field_blend: RED =="
  $IV -Pfield_blend_tb.BLEND=0 -o "$OUT/mod_red" dvd/field_blend.sv $MOD_SRC 2>"$OUT/mod_red.build.log" || { echo "  BUILD FAILED: mod_red"; fail=1; }
  launch mod_red red_weave_vs_model fail "K1" $(mod_args "$FX/fblend_synth")
  [ -n "$THAYER" ] && launch mod_red red_weave_thayer fail "K1" $(mod_args "$THAYER")
  launch chain red_option_off fail "C1 C1B C1T" +blend_en=0

  # mutm <id> <sed on field_blend.sv> <module arms> [bobt|bobb]
  mutm() {
    local m; m=$(mutate "$1" dvd/field_blend.sv "$2") || { fail=1; return; }
    build "mut_$1_mod" "$m" $MOD_SRC || return
    launch "mut_$1_mod" "$1_mod" fail "$3" $(mod_args "$FX/fblend_synth" "${4:-}")
  }
  # mutc <id> <file> <sed> <chain arms> <chain plusargs...>
  mutc() {
    local id=$1 file=$2 expr=$3 arms=$4; shift 4
    local m; m=$(mutate "$id" "$file" "$expr") || { fail=1; return; }
    local fb=dvd/field_blend.sv ag=dvd/resample_addrgen.v
    case "$file" in dvd/field_blend.sv) fb=$m;; dvd/resample_addrgen.v) ag=$m;; esac
    build "mut_${id}_chain" "$fb" "$ag" $CHAIN_SRC || return
    launch "mut_${id}_chain" "${id}_chain" fail "$arms" "$@"
  }
  Q="'"   # a literal single quote inside the sed programs below
  mutm MK1 "s/wire  \[7:0\] f_y = ~p2_bob ? k_y\[9:2\] :/wire  [7:0] f_y = ~p2_bob ? m_y[8:1] :/" "K1"
  mutm MK2 "s/+ {2.d0, p2_d\[31:24\]} + 10.d2;/+ {2${Q}d0, p2_d[31:24]};/" "K1"
  mutm MK3 "s/wire  \[9:0\] k_y = /wire  [8:0] k_y9 = /; s/f_y = ~p2_bob ? k_y\[9:2\]/f_y = ~p2_bob ? {1${Q}b0, k_y9[8:2]}/" "K1"
  mutm MK4 "s/wire  \[7:0\] a_y = p2_first ? p2_d\[31:24\] : a2\[23:16\];/wire  [7:0] a_y = p2_first ? b2[31:24] : a2[23:16];/" "K1"
  mutm MK5 "s/r_osd <= p2_blend ? b2\[7:0\]   : p2_d\[7:0\];/r_osd <= p2_blend ? ((b2[7:0] + p2_d[7:0] + 8${Q}d1) >> 1) : p2_d[7:0];/" "K1"
  mutm MK6 "s/(e_sline == 12.d2) ? ROW_1_COL_0 : ROW_X_COL_0/(e_sline == 12${Q}d2) ? ROW_X_COL_0 : ROW_X_COL_0/" "K3"
  mutm MB1 "s/wire  \[8:0\] m_y = {1.d0, a_y} + {1.d0, p2_d\[31:24\]} + 9.d1;/wire  [8:0] m_y = {1${Q}d0, a_y} + {1${Q}d0, p2_d[31:24]};/" "K1" bobb
  mutm MB2 "s/p1_keep <= (~e_sline\[0\] == h_bbot);/p1_keep <= (e_sline[0] == h_bbot);/" "K1" bobt

  mutc MC1 dvd/resample_addrgen.v "s/: blend_scan ? (oline >= frm_H)/: blend_scan ? (oline >= (frm_H - 12${Q}d1))/" "C2"
  mutc MC2 dvd/resample_addrgen.v "s/disp_y <= (oline == (frm_H - 12.d1)) ? disp_y - 12.d1 : disp_y + 12.d1;/disp_y <= (oline == (frm_H - 12${Q}d1)) ? disp_y : disp_y + 12${Q}d1;/" "C1B"
  mutc MC3 dvd/resample_addrgen.v "s/wire       filt_ok    = deinterlace \&\& ~interlaced \&\& cur_ilace \&\&/wire       filt_ok    = deinterlace \&\& ~interlaced \&\&/" "C4" +pfr=1
  mutc MC4 dvd/field_blend.sv "s/wire        ft_route  = sb_blend | path_busy;/wire        ft_route  = sb_blend;/" "C2" +mix=1
  mutc MC5 dvd/field_blend.sv "s/wire        in_ft   = (in_pos == ROW_0_COL_0) || ((in_pos == ROW_1_COL_0) \&\& ~in_prev_row0);/wire        in_ft   = (in_pos == ROW_0_COL_0) || (in_pos == ROW_1_COL_0);/" "C1 C1B C1T C2 C3"
  mutc MC7 dvd/field_blend.sv "s/  reg         r_wr;/  reg         r_wr;\n  reg         tgl;/; s/      blend_act <= 1.b0;/      blend_act <= 1${Q}b0; tgl <= 1${Q}b0;/; s/      if (ft_arr) begin blend_act/      if (ft_arr) begin tgl <= ~tgl; blend_act/; s/r_y   <= p2_blend ? f_y       : p2_d\[31:24\];/r_y   <= p2_blend ? (f_y ^ {7${Q}d0, tgl}) : p2_d[31:24];/" "C1 C1B C1T C5"
  mutc MB3 dvd/resample_addrgen.v "s/wire       bob_bot_now = pic_scanned ? cur_tff : ~cur_tff;/wire       bob_bot_now = pic_scanned ? ~cur_tff : cur_tff;/" "C1 C1B C1T C9" +bob=1
  mutc MB4 dvd/resample_addrgen.v "s/else if (clk_en \&\& scan_begin) pic_scanned <= 1.b1;/else if (clk_en \&\& scan_begin) pic_scanned <= ~pic_scanned;/" "C1 C1B C1T C5" +bob=1
  mutc MB5 dvd/resample_addrgen.v "s/      cur_tff     <= top_field_first;/      cur_tff     <= 1${Q}b1;/" "C1 C1B C1T C9" +bob=1 +tff=0
  mutc MB6 dvd/resample_addrgen.v "s/wire       filt_ok    = deinterlace \&\& ~interlaced \&\& cur_ilace \&\&/wire       filt_ok    = deinterlace \&\& ~interlaced \&\&/" "C4" +bob=1 +pfr=1
  score

  # the wiring checker must be RED on the real pre-feature files and on each seam
  # regressed alone (a mutated COPY each; the tree is never written)
  wred() {  # wred <label> <checker args...>
    local label=$1; shift
    # ⚠ RED means a NAMED failure, not a non-zero exit: a checker that crashes also
    # exits 1 (it did, on W0/W9, before this test existed).
    if python3 tools/check_field_blend_wiring.py "$@" >"$OUT/$label.log" 2>&1; then
      echo "  FAIL  $label: the wiring checker PASSED"; fail=1
    elif ! grep -q '^check_field_blend_wiring: FAIL' "$OUT/$label.log"; then
      echo "  FAIL  $label: the wiring checker CRASHED (see $OUT/$label.log)"; fail=1
    else echo "  ok    $label (fail: $(grep -m1 -- '  - ' "$OUT/$label.log" | cut -c5-60))"; fi
  }
  git show refs/heads/main:dvd/emu.sv >"$OUT/w_emu_main.sv" 2>/dev/null && \
  git show refs/heads/main:rtl/mpeg2/mpeg2video.v >"$OUT/w_mpeg_main.v" 2>/dev/null && \
    wred W0_pre_feature --emu "$OUT/w_emu_main.sv" --mpeg "$OUT/w_mpeg_main.v"
  m=$(mutate W1 dvd/emu.sv "s/wire blend_en = (deint_mode == 2.d2) \& ~interlaced_eff;/wire blend_en = (deint_mode == 2${Q}d0) \& ~interlaced_eff;/") && wred W1_default_on --emu "$m"
  m=$(mutate W2 dvd/emu.sv "s/wire blend_en = (deint_mode == 2.d2) \& ~interlaced_eff;/wire blend_en = (deint_mode == 2${Q}d2) \& ~fields_eff;/") && wred W2_fields_gate --emu "$m"
  m=$(mutate W3 dvd/emu.sv "s/\.blend_en          (blend_en_dec)/.blend_en          (blend_en)/") && wred W3_no_cdc --emu "$m"
  m=$(mutate W4 dvd/emu.sv 's/"H0O\[51:50\],Deinterlace,Weave,Bob,Blend;"/"H0O[51:50],Deinterlace,Bob,Weave,Blend;"/') && wred W4_values_swapped --emu "$m"
  m=$(mutate W5 rtl/mpeg2/mpeg2video.v "s/    \.in_y(y_fb), \.in_u(u_fb)/    .in_y(y_resample), .in_u(u_fb)/") && wred W5_vscale_bypass --mpeg "$m"
  m=$(mutate W6 dvd/emu.sv "s/    \.status_menumask({15.d0, interlaced_eff}),/    .status_menumask({15${Q}d0, ~interlaced_eff}),/") && wred W6_menumask_inverted --emu "$m"
  m=$(mutate W7 dvd/emu.sv "s/    \.status_menumask({15.d0, interlaced_eff}),//") && wred W7_menumask_unwired --emu "$m"
  m=$(mutate W8 dvd/emu.sv 's/"h0O\[51:50\],Deinterlace,Weave,Bob;"/"h0O[51:50],Deinterlace,Weave,Bob,Blend;"/') && wred W8_blend_on_interlaced --emu "$m"
  m=$(mutate W9 dvd/emu.sv "s/assign HDMI_BOB_DEINT   = fields_eff \& (deint_mode == 2.d1);/assign HDMI_BOB_DEINT   = fields_eff \& ~status[11];/") && wred W9_hdmi_reads_bit11 --emu "$m"
  m=$(mutate W10 dvd/emu.sv "s/wire bob_en = (deint_mode == 2.d1) \& ~interlaced_eff \& ~filmp_eff;/wire bob_en = (deint_mode == 2${Q}d1) \& ~filmp_eff;/") && wred W10_bob_any_raster --emu "$m"
  m=$(mutate W11 dvd/emu.sv "s/wire bob_en = (deint_mode == 2.d1) \& ~interlaced_eff \& ~filmp_eff;/wire bob_en = (deint_mode == 2${Q}d1) \& ~interlaced_eff;/") && wred W11_bob_on_film_raster --emu "$m"
fi

[ $fail -eq 0 ] && echo "== field_blend: OK ==" || { echo "== field_blend: FAIL =="; exit 1; }
