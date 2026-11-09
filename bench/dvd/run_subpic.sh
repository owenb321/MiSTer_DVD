#!/usr/bin/env bash
# Run the DVD subpicture (subtitle) module testbenches in Icarus Verilog.
# Mirrors the other bench/dvd run scripts. Regenerate the real-SPU fixture with
# tools/spu_ref.py first (see spu_decode_tb.sv header) if it's missing.
set -e
cd "$(dirname "$0")/../.."

# subp_stream_map's vectors are GENERATED (bench/dvd/test_vobs/ is gitignored, the
# same convention as aud_map_vec.hex) -- regenerate so the bench can never run
# against a stale fixture.
# ISSUE #81: the module's truth table is unchanged by that fix -- what changed is
# which of emu's signals is wired to the domain gate, and there is no emu-level
# bench. This reads the port connection out of dvd/emu.sv (the acmod_scan.py /
# csync_pipe_tb pattern) and is RED on the pre-#81 file. Costs milliseconds.
echo "=== subp_stream_map wiring: emu.sv passes the DOMAIN, not the menu context (#81) ==="
python3 tools/check_subp_map_wiring.py

# The subpicture layer is ALSO gated by the burn-in policy: Stop and the screensaver
# blank the picture, and everything derived from the picture goes with it (a subtitle,
# a menu button highlight). That composition lives in emu.sv, which has no bench, so
# anyone touching this layer should trip the same check the screensaver suite runs.
echo "=== subpicture burn-in gate: pic_blank hides the layer (Stop / screensaver) ==="
python3 tools/check_saver_overlay_wiring.py

echo "=== subp_stream_map: logical->physical subpicture map vs the golden model ==="
python3 tools/gen_subp_map_vec.py >/dev/null
iverilog -g2012 -o bench/dvd/subp_stream_map_sim dvd/subp_stream_map.sv bench/dvd/subp_stream_map_tb.sv 2>/dev/null
vvp bench/dvd/subp_stream_map_sim | grep -q "PASSED" && echo "  PASSED"
echo "=== ps_demux subpicture routing ==="
iverilog -g2012 -o bench/dvd/ps_demux_subpic_sim dvd/ps_demux.sv bench/dvd/ps_demux_subpic_tb.sv 2>/dev/null
vvp bench/dvd/ps_demux_subpic_sim | grep -q "RESULT: PASS" && echo "  RESULT: PASS"
echo "=== subpic_blend alpha compositor ==="
iverilog -g2012 -o bench/dvd/subpic_blend_sim dvd/subpic_blend.sv bench/dvd/subpic_blend_tb.sv 2>/dev/null
vvp bench/dvd/subpic_blend_sim | grep -q "RESULT: PASS" && echo "  RESULT: PASS"
echo "=== spu_decode (real Matrix SPU vs golden model) ==="
iverilog -g2012 -o bench/dvd/spu_decode_sim dvd/spu_decode.sv bench/dvd/spu_decode_tb.sv 2>/dev/null
vvp bench/dvd/spu_decode_sim | grep -q "RESULT: PASS" && echo "  RESULT: PASS"
echo "=== spu_decode 480i interlaced render (both fields reassemble golden) ==="
iverilog -g2012 -o bench/dvd/spu_decode_480i_sim dvd/spu_decode.sv bench/dvd/spu_decode_480i_tb.sv 2>/dev/null
vvp bench/dvd/spu_decode_480i_sim | grep -q "RESULT: PASS" && echo "  RESULT: PASS"
echo "=== full chain: real VOB -> ps_demux -> spu_decode ==="
iverilog -g2012 -o bench/dvd/subpic_chain_sim dvd/ps_demux.sv dvd/spu_decode.sv bench/dvd/subpic_chain_tb.sv 2>/dev/null
vvp bench/dvd/subpic_chain_sim | grep -q "RESULT: PASS" && echo "  RESULT: PASS"
echo "=== crt_ov_map: CRT Letterbox/Crop overlay inverse map (co-sim vs the real scalers) ==="
iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/crt_ov_map_sim \
  dvd/crt_ov_map.sv dvd/disp_hstretch.sv dvd/disp_vscale.sv dvd/spu_decode.sv \
  rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xfifo_sc.v rtl/mpeg2/xilinx_fifo_dc.v \
  bench/dvd/crt_ov_map_tb.sv 2>/dev/null
# The bench prints a PASS line per test, so only its final verdict may count.
vvp bench/dvd/crt_ov_map_sim | grep -q "crt_ov_map_tb: ALL TESTS PASS" && echo "  PASS"
echo "=== display-order commit (PR #63 regression: the white-rabbit blink + subtitle tails) ==="
# Kept as its own script because it carries RED arms; run it with --red when touching
# spu_decode's commit path. See docs/subpicture.md "The COMMIT contract".
bash "$(dirname "$0")/run_spu_window.sh"

# --red: Standard Convert's overlay inverse (crt_ov_map_tb T10, docs/standard_convert.md).
# Each mutation must fail its own test (T10 the ratios, T11 the subtitle offset) and no other.
if [ "${1:-}" = "--red" ]; then
  echo "=== RED: Standard Convert overlay (each must fail its own test only) ==="
  RD=$(mktemp -d)
  ov_mut() {  # name file old new test   (file: crt_ov_map | spu_decode; the test that alone must fail)
    local name=$1 file=$2 old=$3 new=$4 t=$5
    local OV=dvd/crt_ov_map.sv SP=dvd/spu_decode.sv
    if ! python3 - "$RD/$file.sv" "dvd/$file.sv" "$old" "$new" <<'PYEOF'
import sys
s = open(sys.argv[2]).read()
if s.count(sys.argv[3]) != 1:
    sys.exit("RED anchor moved: " + sys.argv[3])
open(sys.argv[1], 'w').write(s.replace(sys.argv[3], sys.argv[4]))
PYEOF
    then echo "  FAIL $name: mutation did not apply"; RED_FAIL=1; return; fi
    [ "$file" = crt_ov_map ] && OV="$RD/crt_ov_map.sv" || SP="$RD/spu_decode.sv"
    iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o "$RD/sim" \
      "$OV" dvd/disp_hstretch.sv dvd/disp_vscale.sv "$SP" \
      rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xfifo_sc.v rtl/mpeg2/xilinx_fifo_dc.v \
      bench/dvd/crt_ov_map_tb.sv 2>/dev/null || true
    vvp "$RD/sim" > "$RD/log" 2>&1 || true   # a mutant must $fatal; set -e must not end the gate
    rm -f "$RD/$file.sv"
    if grep -q "^$t .*: FAIL" "$RD/log" && ! grep -E '^T[0-9]+[a-z]? .*: FAIL' "$RD/log" | grep -qv "^$t " \
       && ! grep -q 'ALL TESTS PASS' "$RD/log"; then
      echo "  PASS $name (failed $t only)"
    else
      echo "  FAIL $name: wanted $t alone to fail"; grep -E ': (PASS|FAIL)' "$RD/log" | sed 's/^/      /'; RED_FAIL=1
    fi
  }
  RED_FAIL=0
  ov_mut "R1 no bottom-field phase" crt_ov_map "lr       <= (v_pos_in == v_bar) ? 6'd0 : l_phase;" "lr       <= 6'd0;" T10
  ov_mut "R2 nearest tap one late"  crt_ov_map "(lr >= 6'd30) ? vstep" "(lr >= 6'd31) ? vstep" T10
  ov_mut "R3 5/6 step off by 1/60"  crt_ov_map "(ratio == 2'd1) ? 6'd12 : (ratio == 2'd2) ? 6'd36 : 6'd20;" "(ratio == 2'd1) ? 6'd13 : (ratio == 2'd2) ? 6'd36 : 6'd20;" T10
  ov_mut "R4 offset not in the read" spu_decode "bmp_rd <= bmp[q_row_base + q_off_base + {{(ABW-12){1'b0}}, q_x}];" "bmp_rd <= bmp[q_row_base + {{(ABW-12){1'b0}}, q_x}];" T11
  ov_mut "R5 area test unoffset"     spu_decode "(q_y_eff >= c_sy) && (q_y_eff <= c_ey);" "(q_y >= c_sy) && (q_y <= c_ey);" T11
  ov_mut "R6 no sentinel guard"      spu_decode "wire in_y = (q_y != 12'hFFF) && " "wire in_y = " T11
  ov_mut "R7 offset not sign-extended" spu_decode "{{20{q_y_off[11]}}, q_y_off}" "{20'd0, q_y_off}" T11
  rm -rf "$RD"
  [ $RED_FAIL = 0 ] && echo "  RED: ALL OK" || { echo "  RED: SOME ARMS FAILED"; exit 1; }
fi
