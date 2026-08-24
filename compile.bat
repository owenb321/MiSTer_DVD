set PATH=C:\intelFPGA_lite\17.0\quartus\bin64;%PATH%
echo Running Map...
quartus_map mpeg2fpga
if %errorlevel% neq 0 exit /b %errorlevel%
echo Running Fit...
quartus_fit mpeg2fpga
if %errorlevel% neq 0 exit /b %errorlevel%
echo Running Asm...
quartus_asm mpeg2fpga
if %errorlevel% neq 0 exit /b %errorlevel%
echo Running STA...
quartus_sta mpeg2fpga
if %errorlevel% neq 0 exit /b %errorlevel%
echo Generating RBF...
quartus_cpf -c -o bitstream_compression=on output_files\mpeg2fpga.sof output_files\mpeg2fpga.rbf
if %errorlevel% neq 0 exit /b %errorlevel%
echo Done.
