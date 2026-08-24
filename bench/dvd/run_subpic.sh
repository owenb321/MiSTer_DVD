#!/usr/bin/env bash
# Run the DVD subpicture (subtitle) module testbenches in Icarus Verilog.
# Mirrors the other bench/dvd run scripts. Regenerate the real-SPU fixture with
# tools/spu_ref.py first (see spu_decode_tb.sv header) if it's missing.
set -e
cd "$(dirname "$0")/../.."

echo "=== ps_demux subpicture routing ==="
iverilog -g2012 -o bench/dvd/ps_demux_subpic_sim dvd/ps_demux.sv bench/dvd/ps_demux_subpic_tb.sv 2>/dev/null
vvp bench/dvd/ps_demux_subpic_sim | grep RESULT

echo "=== subpic_blend alpha compositor ==="
iverilog -g2012 -o bench/dvd/subpic_blend_sim dvd/subpic_blend.sv bench/dvd/subpic_blend_tb.sv 2>/dev/null
vvp bench/dvd/subpic_blend_sim | grep RESULT

echo "=== spu_decode (real Matrix SPU vs golden model) ==="
iverilog -g2012 -o bench/dvd/spu_decode_sim dvd/spu_decode.sv bench/dvd/spu_decode_tb.sv 2>/dev/null
vvp bench/dvd/spu_decode_sim | grep RESULT

echo "=== spu_decode 480i interlaced render (both fields reassemble golden) ==="
iverilog -g2012 -o bench/dvd/spu_decode_480i_sim dvd/spu_decode.sv bench/dvd/spu_decode_480i_tb.sv 2>/dev/null
vvp bench/dvd/spu_decode_480i_sim | grep RESULT

echo "=== full chain: real VOB -> ps_demux -> spu_decode ==="
iverilog -g2012 -o bench/dvd/subpic_chain_sim dvd/ps_demux.sv dvd/spu_decode.sv bench/dvd/subpic_chain_tb.sv 2>/dev/null
vvp bench/dvd/subpic_chain_sim | grep RESULT

echo "=== crt_ov_map: CRT Letterbox/Crop overlay inverse map (co-sim vs the real scalers) ==="
iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/crt_ov_map_sim \
  dvd/crt_ov_map.sv dvd/disp_hstretch.sv dvd/disp_vscale.sv dvd/spu_decode.sv \
  rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xfifo_sc.v rtl/mpeg2/xilinx_fifo_dc.v \
  bench/dvd/crt_ov_map_tb.sv 2>/dev/null
vvp bench/dvd/crt_ov_map_sim | grep -E "PASS|FAIL"
