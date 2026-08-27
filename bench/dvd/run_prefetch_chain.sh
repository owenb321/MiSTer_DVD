#!/usr/bin/env bash
#
# run_prefetch_chain.sh — build & compare the SHALLOW (upstream 256-deep) vs
# DEEP (N64-style 2048-deep line-prefetch) display chain, using the extended
# bench/dvd/resample_chain_tb.sv.
#
# SHALLOW = upstream disp_reader depths, rtl/mpeg2/fifo_size.v.
# DEEP    = -DDEEP_DISP (2048-deep disp_reader) AND `-I dvd/mem_override` first
#           so resample.v compiles with the deepened RESAMPLE_DEPTH (run-ahead).
#
# Tests:
#   1. correctness — every height 256/272/480 renders CLEAN in continuous + held,
#      for BOTH configs (deepening must not regress the working path).
#   2. robustness  — under a bursty memory stall (+stallon/+stalloff) the SHALLOW
#      buffer underruns (black frames) where the DEEP prefetch rides through.
#
set -e
cd "$(dirname "$0")/../.."

SRC="rtl/mpeg2/resample.v dvd/resample_addrgen.v rtl/mpeg2/resample_dta.v \
rtl/mpeg2/resample_bilinear.v rtl/mpeg2/mem_addr.v rtl/mpeg2/mixer.v \
rtl/mpeg2/pixel_queue.v rtl/mpeg2/syncgen.v rtl/mpeg2/read_write.v \
rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xilinx_fifo_dc.v rtl/mpeg2/xfifo_sc.v \
bench/dvd/resample_chain_tb.sv"

echo "### building SHALLOW (upstream 256) ..."
iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/chain_shallow $SRC

echo "### building DEEP (prefetch 1024) ..."
iverilog -g2012 -D__IVERILOG__ -DDEEP_DISP -I dvd/mem_override -I rtl/mpeg2 -o bench/dvd/chain_deep $SRC

run() { # $1=bin $2..=plusargs ; prints only the SUMMARY line
  vvp "$@" 2>&1 | grep -E 'SUMMARY|====' | grep -v DONE
}

echo
echo "============ 1. CORRECTNESS (no stall) ============"
for h in 16 17 30; do
  for held in 0 1; do
    echo "-- mbh=$h held=$held --"
    echo -n "   SHALLOW: "; vvp bench/dvd/chain_shallow +mbh=$h +held=$held 2>&1 | grep SUMMARY
    echo -n "   DEEP   : "; vvp bench/dvd/chain_deep    +mbh=$h +held=$held 2>&1 | grep SUMMARY
  done
done

echo
echo "============ 2. ROBUSTNESS (bursty memory stall, mbh=30/480p) ============"
# The display cushion = pixel_queue (1024 px) + the disp data buffer, both drained
# at the scanout-limited rate, so the buffer protects against a stall burst lasting
# up to roughly:  SHALLOW(256w) ~6-7k clks ;  DEEP(2048w) ~38k clks.
# We serve 20000 clks (more than enough to refill either buffer; avg bandwidth far
# exceeds consumption) then stall for S clks, and sweep S across that gap:
#   S=4000  : both survive          (control: short burst, neither starves)
#   S=12000 : SHALLOW starves, DEEP rides through  (the prefetch win)
#   S=45000 : both starve           (control: burst exceeds even the deep buffer)
for son in 4000 12000 45000; do
  echo "-- mbh=30  serve=20000  stall=$son  (avg $(( 100*20000/(20000+son) ))%) --"
  echo -n "   SHALLOW: "; vvp bench/dvd/chain_shallow +mbh=30 +held=0 +stalloff=20000 +stallon=$son 2>&1 | grep SUMMARY
  echo -n "   DEEP   : "; vvp bench/dvd/chain_deep    +mbh=30 +held=0 +stalloff=20000 +stallon=$son 2>&1 | grep SUMMARY
done
