@echo off
REM Build and run mpeg2fpga iverilog simulation with stream-susi.mpg
REM Usage: run_susi.bat [compile|run|clean|all]

set IVERILOG=C:\iverilog\bin\iverilog.exe
set VVP=C:\iverilog\bin\vvp.exe
set MODELINE=MODELINE_SIF
set STREAM=..\..\tools\streams\stream-susi.mpg
set END_SEQ=..\..\tools\streams\end-of-sequence.mpg

if "%1"=="clean" goto clean
if "%1"=="run" goto run
if "%1"=="compile" goto compile
if "%1"=="all" goto all
goto all

:all
call :compile
if errorlevel 1 goto :eof
call :setup_stream
call :run
goto :eof

:compile
echo === Compiling with iverilog ===
"%IVERILOG%" -D__IVERILOG__ -D%MODELINE% -I ..\..\rtl\mpeg2 -o mpeg2.vvp ^
  testbench.v ^
  mem_ctl.v ^
  wrappers.v ^
  generic_fifo_dc.v ^
  generic_fifo_sc_b.v ^
  generic_dpram.v ^
  ..\..\rtl\mpeg2\mpeg2video.v ^
  ..\..\rtl\mpeg2\vbuf.v ^
  ..\..\rtl\mpeg2\getbits.v ^
  ..\..\rtl\mpeg2\vld.v ^
  ..\..\rtl\mpeg2\rld.v ^
  ..\..\rtl\mpeg2\iquant.v ^
  ..\..\rtl\mpeg2\idct.v ^
  ..\..\rtl\mpeg2\motcomp.v ^
  ..\..\rtl\mpeg2\motcomp_motvec.v ^
  ..\..\rtl\mpeg2\motcomp_addrgen.v ^
  ..\..\rtl\mpeg2\motcomp_picbuf.v ^
  ..\..\rtl\mpeg2\motcomp_dcttype.v ^
  ..\..\rtl\mpeg2\motcomp_recon.v ^
  ..\..\rtl\mpeg2\fwft.v ^
  ..\..\rtl\mpeg2\resample.v ^
  ..\..\rtl\mpeg2\resample_addrgen.v ^
  ..\..\rtl\mpeg2\resample_dta.v ^
  ..\..\rtl\mpeg2\resample_bilinear.v ^
  ..\..\rtl\mpeg2\pixel_queue.v ^
  ..\..\rtl\mpeg2\mixer.v ^
  ..\..\rtl\mpeg2\syncgen.v ^
  ..\..\rtl\mpeg2\syncgen_intf.v ^
  ..\..\rtl\mpeg2\yuv2rgb.v ^
  ..\..\rtl\mpeg2\osd.v ^
  ..\..\rtl\mpeg2\regfile.v ^
  ..\..\rtl\mpeg2\reset.v ^
  ..\..\rtl\mpeg2\watchdog.v ^
  ..\..\rtl\mpeg2\framestore.v ^
  ..\..\rtl\mpeg2\framestore_request.v ^
  ..\..\rtl\mpeg2\framestore_response.v ^
  ..\..\rtl\mpeg2\read_write.v ^
  ..\..\rtl\mpeg2\mem_addr.v ^
  ..\..\rtl\mpeg2\synchronizer.v ^
  ..\..\rtl\mpeg2\probe.v ^
  ..\..\rtl\mpeg2\xfifo_sc.v
if errorlevel 1 (
    echo === Compilation FAILED ===
    exit /b 1
)
echo === Compilation successful ===
goto :eof

:setup_stream
echo === Setting up test stream ===
if exist vid.mpg del vid.mpg
copy /b "%STREAM%" + "%END_SEQ%" vid.mpg
echo Created vid.mpg from %STREAM% and %END_SEQ%
goto :eof

:run
echo === Running simulation ===
if not exist vid.mpg (
    call :setup_stream
)
"%VVP%" mpeg2.vvp -lxt2 > sim.log 2>&1
echo === Simulation complete ===
goto :eof

:clean
echo === Cleaning ===
del /q mpeg2.vvp vid.mpg testbench.lxt 2>nul
del /q framestore_*.ppm tv_out_*.ppm 2>nul
echo === Clean complete ===
goto :eof
