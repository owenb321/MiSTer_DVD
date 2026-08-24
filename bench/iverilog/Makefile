#
# Use: make [all|test|project|clean]
#

STREAM = ../../tools/streams/stream-susi.mpg
#STREAM = ../../tools/streams/colorbars.mpg
#STREAM = ../../tools/streams/telediario_2.mpg
#STREAM = /home/koen/m2v/neujahrskonzert.mv2

MODELINE = MODELINE_SIF
#MODELINE = MODELINE_PAL_INTERL

SRCS = \
  testbench.v \
  mem_ctl.v \
  wrappers.v \
  generic_fifo_dc.v \
  generic_fifo_sc_b.v \
  generic_dpram.v \
  ../../rtl/mpeg2/mpeg2video.v \
  ../../rtl/mpeg2/vbuf.v \
  ../../rtl/mpeg2/getbits.v \
  ../../rtl/mpeg2/vld.v \
  ../../rtl/mpeg2/rld.v \
  ../../rtl/mpeg2/iquant.v \
  ../../rtl/mpeg2/idct.v \
  ../../rtl/mpeg2/motcomp.v \
  ../../rtl/mpeg2/motcomp_motvec.v \
  ../../rtl/mpeg2/motcomp_addrgen.v \
  ../../rtl/mpeg2/motcomp_picbuf.v \
  ../../rtl/mpeg2/motcomp_dcttype.v \
  ../../rtl/mpeg2/motcomp_recon.v \
  ../../rtl/mpeg2/fwft.v \
  ../../rtl/mpeg2/resample.v \
  ../../rtl/mpeg2/resample_addrgen.v \
  ../../rtl/mpeg2/resample_dta.v \
  ../../rtl/mpeg2/resample_bilinear.v \
  ../../rtl/mpeg2/pixel_queue.v \
  ../../rtl/mpeg2/mixer.v \
  ../../rtl/mpeg2/syncgen.v \
  ../../rtl/mpeg2/syncgen_intf.v \
  ../../rtl/mpeg2/yuv2rgb.v \
  ../../rtl/mpeg2/osd.v \
  ../../rtl/mpeg2/regfile.v \
  ../../rtl/mpeg2/reset.v \
  ../../rtl/mpeg2/watchdog.v \
  ../../rtl/mpeg2/framestore.v \
  ../../rtl/mpeg2/framestore_request.v \
  ../../rtl/mpeg2/framestore_response.v \
  ../../rtl/mpeg2/read_write.v \
  ../../rtl/mpeg2/mem_addr.v \
  ../../rtl/mpeg2/synchronizer.v \
  ../../rtl/mpeg2/probe.v \
  ../../rtl/mpeg2/xfifo_sc.v

INCS = \
  ../../rtl/mpeg2/fifo_size.v \
  ../../rtl/mpeg2/mem_codes.v \
  ../../rtl/mpeg2/modeline.v \
  ../../rtl/mpeg2/motcomp_dctcodes.v \
  ../../rtl/mpeg2/resample_codes.v \
  ../../rtl/mpeg2/timescale.v \
  ../../rtl/mpeg2/vlc_tables.v \
  ../../rtl/mpeg2/vld_codes.v \
  ../../rtl/mpeg2/zigzag_table.v

IVERILOG_DUMPER=lxt

all: mpeg2 stream.dat

mpeg2: $(SRCS) $(INCS)
	iverilog -D__IVERILOG__ -D$(MODELINE) -I ../../rtl/mpeg2 -o mpeg2 $(SRCS)

test: mpeg2 stream.dat
	IVERILOG_DUMPER=lxt ./mpeg2 

clean: 
	rm -f mpeg2 stream.dat testbench.lxt trace framestore_*.ppm tv_out_*.ppm

# convert mpeg2 stream to .dat file for testbench
stream.dat: $(STREAM)
	head --bytes=4m $? | xxd -c 1 - | cut -d\  -f 2 > $@
	xxd -c 1 ../../tools/streams/end-of-sequence.mpg | cut -d\  -f 2 >> $@

# Count number of semicolons; indication of the number of statements in the code.
cntstmnts: 
	echo counting semicolons of mpeg2 decoder source files
	cat $(SRCS) $(INCS) | tr  -d '\n'  | sed -e 's/[^;]//g'| wc -c
	echo counting lines of mpeg2 decoder source files
	cat $(SRCS) $(INCS) | wc -l
	echo counting semicolons of ml505 implementation source files
	cat ../../rtl/mpeg2/*.v ../../rtl/dvi/*.v ../../rtl/mem_interface/*.v ../../rtl/ethernet/*.v ../../rtl/ml505/*.v | tr  -d '\n'  | sed -e 's/[^;]//g'| wc -c
#not truncated
