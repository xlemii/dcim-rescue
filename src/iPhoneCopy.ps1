# DCIM Rescue - command line version.
#
#   iPhoneCopy.ps1 -Destination D:\Photos\iPhone          copy everything (resumes where it left off)
#   iPhoneCopy.ps1 -Destination D:\Photos\iPhone -Verify  compare the phone with the folder, copy nothing
#   iPhoneCopy.ps1 -ListOnly                              just count files and size
#
# Run with:  powershell -NoProfile -ExecutionPolicy Bypass -STA -File iPhoneCopy.ps1 [options]
param(
    [string]$Destination = (Join-Path ([Environment]::GetFolderPath('MyPictures')) 'iPhone'),
    [int]$MaxRetries = 5,
    [int]$StallSeconds = 90,
    [switch]$Verify,
    [switch]$ListOnly
)

. (Join-Path $PSScriptRoot 'iPhoneCopy.Core.ps1')

$colors = @{ Info = 'Gray'; Ok = 'Green'; Warn = 'Yellow'; Error = 'Red'; Title = 'Cyan' }
$log = { param($line, $level) Write-Host $line -ForegroundColor $colors[$level] }
$progress = {
    param($p)
    if ($p.Phase -eq 'Copy' -and $p.TotalBytes -gt 0) {
        $eta = if ($p.Eta) { $p.Eta.ToString('hh\:mm\:ss') } else { '?' }
        Write-Progress -Activity 'Copying from iPhone' -PercentComplete ([math]::Min(100, 100 * $p.BytesDone / $p.TotalBytes)) `
            -Status ("{0}/{1}   {2} of {3}   {4:N1} MB/s   ~{5} left" -f $p.Index, $p.Total, (Format-Size $p.BytesDone), (Format-Size $p.TotalBytes), ($p.Speed / 1MB), $eta)
    }
}

if ($Verify) {
    $r = Invoke-IPhoneVerify -Destination $Destination -Log $log -Progress $progress
    Write-Progress -Activity 'Copying from iPhone' -Completed
    if ($r.Stopped -or $r.Missing.Count -or $r.WrongSize.Count) { exit 1 }
} else {
    $r = Invoke-IPhoneCopy -Destination $Destination -MaxRetries $MaxRetries -StallSeconds $StallSeconds -ListOnly:$ListOnly -Log $log -Progress $progress
    Write-Progress -Activity 'Copying from iPhone' -Completed
    if ($r.Stopped -or $r.Failed.Count) { exit 1 }
}
exit 0
