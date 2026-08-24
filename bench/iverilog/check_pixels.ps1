param([string]$File)
$lines = Get-Content $File
$nonBlack = 0
$blanking = 0
$black = 0
$other = 0
foreach ($line in $lines) {
    $t = $line.Trim()
    if ($t -eq '0   0   0') { $black++ }
    elseif ($t -eq '48  48  48') { $blanking++ }
    elseif ($t.StartsWith('#') -or $t.StartsWith('P3') -or $t -match '^\d+\s+\d+\s+255$') { continue }
    else { $other++; if ($other -le 10) { Write-Output "Non-standard pixel at line $($lines.IndexOf($line)+1): $t" } }
}
Write-Output ""
Write-Output "Summary: Black=$black, Blanking=$blanking, Other=$other"
