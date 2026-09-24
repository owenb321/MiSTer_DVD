#!/usr/bin/env bash
#
# run_field_blend.sh -- gate for the non-adaptive field blend on the Progressive
# raster (docs/field_blend.md; dvd/field_blend.sv, the addrgen's H+1 emission and
# sideband). Structure adapted from Stage A's run_deint.sh (feature/deinterlace).
#
# GREEN
#   field_blend_tb    the module, BIT-EXACT against tools/field_blend_model.py on a
#                     synthetic fixture (regenerated every run) and, when the ISO is
#                     reachable, a real Thayer's Quest frame; with backpressure; plus
#                     the PLAIN bypass                                    [K1..K4]
#
# --red  each arm must FAIL exactly where designed:
#   RED-K  -Pfield_blend_tb.BLEND=0 (the pre-feature weave) vs the model   -> K1
#   MK1  bob kernel ((a+d+1)>>1)                                          -> K1
#   MK2  the +2 rounding dropped                                          -> K1
#   MK3  a 9-bit sum (the kernel overflows on bright content)             -> K1
#   MK4  top edge replicate (a := b) instead of mirror                    -> K1
#   MK5  OSD blended                                                      -> K1
#   MK6  line 1 re-coded ROW_X_COL_0 instead of ROW_1_COL_0               -> K3
# ⚠ every sed must prove it applied (cmp) and every mutant must compile. The verdict
#   is the RESULT line plus the exit status, never a pipe.
set -u
cd "$(dirname "$0")/../.."
OUT=.sim/field_blend; mkdir -p "$OUT"
FX=bench/dvd/test_vobs; mkdir -p "$FX"
IV="iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2"
MOD_SRC="rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xilinx_fifo_dc.v rtl/mpeg2/xfifo_sc.v
 bench/dvd/field_blend_tb.sv"
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
  $IV -o "$OUT/$name" "$@" 2>"$OUT/$name.build.log" || { echo "  BUILD FAILED: $name (see $OUT/$name.build.log)"; return 1; }
}
# run <sim> <label> <want pass|fail> [<expected failing arms>] -- <plusargs>
# With an arm list, the set of "FAIL: [..]" ids must equal it EXACTLY.
run() {
  local sim=$1 label=$2 want=$3; shift 3
  local arms=""
  if [ $# -gt 0 ] && [ "$1" != "--" ]; then arms=$1; shift; fi
  if [ $# -gt 0 ] && [ "$1" = "--" ]; then shift; fi
  vvp -n "$OUT/$sim" "$@" >"$OUT/$label.log" 2>&1; local rc=$?
  local got=fail; if [ $rc = 0 ] && grep -q '^RESULT: PASS' "$OUT/$label.log"; then got=pass; fi
  local ids; ids=$(grep -oE '^FAIL: \[[A-Z][0-9]+[A-Z]?\]' "$OUT/$label.log" | grep -oE '[A-Z][0-9]+[A-Z]?' | sort -u | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" != "$want" ]; then echo "  FAIL  $label: want $want, got $got [$ids] (see $OUT/$label.log)"; fail=1; return; fi
  if [ -n "$arms" ] && [ "$ids" != "$arms" ]; then echo "  FAIL  $label: failing arms [$ids], designed [$arms]"; fail=1; return; fi
  echo "  ok    $label ($got${ids:+ [$ids]})"
}
mod_args() { echo "+in=$1.in.hex +exp=$1.exp.hex +meta=$1.meta.hex"; }

echo "== field_blend: GREEN =="
build mod dvd/field_blend.sv $MOD_SRC || fail=1
run mod mod_synth        pass -- $(mod_args "$FX/fblend_synth")
run mod mod_synth_stall  pass -- $(mod_args "$FX/fblend_synth") +stall=5
run mod mod_plain        pass -- $(mod_args "$FX/fblend_synth") +plain=1 +stall=5
[ -n "$THAYER" ] && run mod mod_thayer pass -- $(mod_args "$THAYER") +stall=7

if [ "${1:-}" = "--red" ]; then
  echo "== field_blend: RED =="
  $IV -Pfield_blend_tb.BLEND=0 -o "$OUT/mod_red" dvd/field_blend.sv $MOD_SRC 2>"$OUT/mod_red.build.log" \
    && run mod_red red_weave_vs_model fail "K1" -- $(mod_args "$FX/fblend_synth")
  [ -n "$THAYER" ] && run mod_red red_weave_thayer fail "K1" -- $(mod_args "$THAYER")

  mutate() {  # mutate <name> <file> <sed> -> path of the mutant (proves it applied)
    local dst="$OUT/mut_$1_$(basename "$2")"
    sed "$3" "$2" >"$dst"
    if cmp -s "$2" "$dst"; then echo "  FAIL  mutation $1 did not apply" >&2; return 1; fi
    echo "$dst"
  }
  # mutm <id> <sed on field_blend.sv> <module arms>
  mutm() {
    local id=$1 expr=$2 kA=$3
    local m; m=$(mutate "$id" dvd/field_blend.sv "$expr") || { fail=1; return; }
    build "mut_${id}_mod" "$m" $MOD_SRC || { fail=1; return; }
    run "mut_${id}_mod" "${id}_mod" "$([ -n "$kA" ] && echo fail || echo pass)" "$kA" -- $(mod_args "$FX/fblend_synth")
  }
  mutm MK1 's/r_y   <= p2_blend ? k_y\[9:2\]  : p2_d\[31:24\];/r_y   <= p2_blend ? (({1'"'"'b0,a_y} + {1'"'"'b0,p2_d[31:24]} + 9'"'"'d1) >> 1) : p2_d[31:24];/' "K1"
  mutm MK2 's/+ {2.d0, p2_d\[31:24\]} + 10.d2;/+ {2'"'"'d0, p2_d[31:24]};/' "K1"
  mutm MK3 's/wire  \[9:0\] k_y = /wire  [8:0] k_y9 = /; s/r_y   <= p2_blend ? k_y\[9:2\]/r_y   <= p2_blend ? {1'"'"'b0, k_y9[8:2]}/' "K1"
  mutm MK4 's/wire  \[7:0\] a_y = p2_first ? p2_d\[31:24\] : a2\[23:16\];/wire  [7:0] a_y = p2_first ? b2[31:24] : a2[23:16];/' "K1"
  mutm MK5 's/r_osd <= p2_blend ? b2\[7:0\]   : p2_d\[7:0\];/r_osd <= p2_blend ? ((b2[7:0] + p2_d[7:0] + 8'"'"'d1) >> 1) : p2_d[7:0];/' "K1"
  mutm MK6 's/(e_sline == 12.d2) ? ROW_1_COL_0 : ROW_X_COL_0/(e_sline == 12'"'"'d2) ? ROW_X_COL_0 : ROW_X_COL_0/' "K3"
fi

[ $fail -eq 0 ] && echo "== field_blend: OK ==" || { echo "== field_blend: FAIL =="; exit 1; }
