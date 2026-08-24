$bytes = [System.IO.File]::ReadAllBytes('C:\code\mpeg2fpga-master\tools\streams\greyramp.mpg')[0..63]
$hex = $bytes | ForEach-Object { '{0:X2}' -f $_ }
Write-Output "First 64 bytes:"
Write-Output ($hex -join ' ')
Write-Output ""
# Check for MPEG2 start codes
$all = [System.IO.File]::ReadAllBytes('C:\code\mpeg2fpga-master\tools\streams\greyramp.mpg')
Write-Output "File size: $($all.Length) bytes"
# Look for sequence header (00 00 01 B3)
for ($i = 0; $i -lt [Math]::Min($all.Length, 1000); $i++) {
    if ($all[$i] -eq 0 -and $all[$i+1] -eq 0 -and $all[$i+2] -eq 1) {
        $code = $all[$i+3]
        $codeName = switch ($code) {
            0x00 { "PICTURE_START" }
            0xB3 { "SEQUENCE_HEADER" }
            0xB5 { "EXTENSION" }
            0xB8 { "GROUP_OF_PICTURES" }
            default { "START_CODE_0x{0:X2}" -f $code }
        }
        Write-Output "Offset $i : 00 00 01 $($code.ToString('X2')) = $codeName"
    }
}
