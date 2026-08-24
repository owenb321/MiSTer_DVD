$all = [System.IO.File]::ReadAllBytes('C:\code\mpeg2fpga-master\tools\streams\greyramp.mpg')
# Sequence header starts at offset 4 (after 00 00 01 B3)
# Bytes 4-7: horizontal_size(12), vertical_size(12), aspect_ratio(4), frame_rate(4)
$b4 = $all[4]; $b5 = $all[5]; $b6 = $all[6]; $b7 = $all[7]
$horz = ($b4 -shl 4) -bor ($b5 -shr 4)
$vert = (($b5 -band 0x0F) -shl 8) -bor $b6
$aspect = ($b7 -shr 4)
$framerate = ($b7 -band 0x0F)

Write-Output "Sequence Header:"
Write-Output "  Horizontal size: $horz"
Write-Output "  Vertical size: $vert"
Write-Output "  Aspect ratio code: $aspect"
Write-Output "  Frame rate code: $framerate"

$frNames = @{1="23.976"; 2="24"; 3="25"; 4="29.97"; 5="30"; 6="50"; 7="59.94"; 8="60"}
if ($frNames.ContainsKey($framerate)) {
    Write-Output "  Frame rate: $($frNames[$framerate]) fps"
}
