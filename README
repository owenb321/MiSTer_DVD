This is a mpeg2 video core. To run a testbench:

1. Download a sample video

cd tools/streams
wget ftp://ftp.tek.com/tv/test/streams/Element/MPEG-Video/625/susi_015.m2v
mv susi_015.m2v stream-susi.mpg

2. Install Icarus verilog

apt-get install iverilog

3. Run testbench

cd bench/iverilog
Verify top of Makefile looks like this:

STREAM = ../../tools/streams/stream-susi.mpg
MODELINE = MODELINE_SIF

make clean test

Directory ought to fill with .ppm files. 

