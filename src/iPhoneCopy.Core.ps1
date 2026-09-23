# DCIM Rescue - shared logic used by both the window (GUI) and the command line.
#
# Talks to the iPhone through Windows' built-in MTP support (Shell.Application COM),
# the same way File Explorer does, so no extra software is needed besides Apple's USB driver.
# Every file is checked by size after copying; failed files are retried, and re-running
# only copies what is still missing.

if (-not ('IPhoneCopier.Power' -as [type])) {
    Add-Type -Namespace IPhoneCopier -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
'@
}

$script:Shell = New-Object -ComObject Shell.Application
$script:LogSink = $null
$script:ProgressSink = $null
$script:StopCheck = $null
$script:LogFile = $null

# ---------------------------------------------------------------- helpers

function Set-KeepAwake([bool]$On) {
    # ES_CONTINUOUS | ES_SYSTEM_REQUIRED keeps the PC from sleeping; ES_CONTINUOUS alone releases it
    $flags = if ($On) { [uint32]'0x80000001' } else { [uint32]'0x80000000' }
    [void][IPhoneCopier.Power]::SetThreadExecutionState($flags)
}

function Initialize-Run($Destination, $Log, $Progress, $ShouldStop) {
    $script:LogSink = $Log
    $script:ProgressSink = $Progress
    $script:StopCheck = $ShouldStop
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $script:LogFile = Join-Path $Destination 'iphone-copy-log.txt'
}

function Write-Log([string]$Message, [string]$Level = 'Info') {
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message
    if ($script:LogFile) { try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch {} }
    if ($script:LogSink) { $null = & $script:LogSink $line $Level }
}

function Send-Progress($Phase, $Index, $Total, $BytesDone = 0, $TotalBytes = 0, $Speed = 0, $Current = '') {
    if (-not $script:ProgressSink) { return }
    $eta = if ($Speed -gt 0) { [TimeSpan]::FromSeconds([math]::Max(0, ($TotalBytes - $BytesDone) / $Speed)) } else { $null }
    $null = & $script:ProgressSink ([pscustomobject]@{
        Phase = $Phase; Index = $Index; Total = $Total; BytesDone = $BytesDone; TotalBytes = $TotalBytes
        Speed = $Speed; Eta = $eta; Current = $Current
    })
}

function Test-Stop { [bool]($script:StopCheck -and (& $script:StopCheck)) }

function Wait-Seconds([int]$Seconds) {
    for ($t = 0; $t -lt $Seconds * 4 -and -not (Test-Stop); $t++) { Start-Sleep -Milliseconds 250 }
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    "{0:N1} MB" -f ($Bytes / 1MB)
}

function Get-ItemFileName($Item) {
    # .Name hides extensions when Explorer is set to do so - the real file name is in System.FileName
    try { $n = $Item.ExtendedProperty('System.FileName'); if ($n) { return [string]$n } } catch {}
    [string]$Item.Name
}

function Get-ItemFileSize($Item) {
    # .Size is 32-bit and overflows on big videos; System.Size is 64-bit
    try { $s = $Item.ExtendedProperty('System.Size'); if ($s) { return [uint64]$s } } catch {}
    try { return [uint64]$Item.Size } catch { return [uint64]0 }
}

function Test-FileUnlocked($Path) {
    try { $fs = [IO.File]::Open($Path, 'Open', 'Read', 'None'); $fs.Close(); $true } catch { $false }
}

function Test-AlreadyCopied($Target, [uint64]$Size) {
    if (-not (Test-Path -LiteralPath $Target)) { return $false }
    $len = (Get-Item -LiteralPath $Target).Length
    if ($Size -gt 0) { $len -eq $Size } else { $len -gt 0 }
}

# ---------------------------------------------------------------- finding the iPhone

function Get-IPhoneState {
    # Returns @{ Status = 'NotFound' | 'Locked' | 'Ready'; Name; Root }
    $dev = $null
    try { $dev = @($script:Shell.NameSpace(17).Items()) | Where-Object { $_.Name -match 'iPhone|iPad|Apple' } | Select-Object -First 1 } catch {}
    if (-not $dev) { return @{ Status = 'NotFound' } }

    $storage = $null; $children = @()
    try {
        $storage = @($dev.GetFolder.Items()) | Select-Object -First 1   # "Internal Storage"
        if ($storage) { $children = @($storage.GetFolder.Items()) }
    } catch {}
    # a locked or not-yet-trusted phone shows up with empty storage
    if ($children.Count -eq 0) { return @{ Status = 'Locked'; Name = $dev.Name } }

    # older iOS: Internal Storage\DCIM\100APPLE, newer iOS: Internal Storage\202506_a
    $dcim = $children | Where-Object { $_.Name -eq 'DCIM' } | Select-Object -First 1
    $root = if ($dcim) { $dcim.GetFolder } else { $storage.GetFolder }
    @{ Status = 'Ready'; Name = $dev.Name; Root = $root }
}

function Wait-IPhoneRoot {
    $warned = $false
    while (-not (Test-Stop)) {
        $state = Get-IPhoneState
        if ($state.Status -eq 'Ready') { return $state.Root }
        if (-not $warned) {
            Write-Log "Can't see the iPhone's photos. Unlock the phone, tap 'Trust' and check the cable. Waiting..." 'Warn'
            $warned = $true
        }
        Wait-Seconds 3
    }
    $null
}

function Get-IPhoneSubFolder([string]$Name) {
    $root = Wait-IPhoneRoot
    if (-not $root) { return $null }
    $f = @($root.Items()) | Where-Object { $_.IsFolder -and $_.Name -eq $Name } | Select-Object -First 1
    if ($f) { $f.GetFolder } else { $null }
}

function Get-FileIndex($Folder) {
    $map = @{}
    if ($Folder) { foreach ($it in @($Folder.Items())) { if (-not $it.IsFolder) { $map[(Get-ItemFileName $it)] = $it } } }
    $map
}

function Get-IPhoneFileList {
    # Lists every file on the phone as { Folder, Name, Size }. Returns $null when stopped.
    $root = Wait-IPhoneRoot
    if (-not $root) { return $null }
    $folders = @(@($root.Items()) | Where-Object { $_.IsFolder } | ForEach-Object { $_.Name } | Sort-Object)
    Write-Log ("Found {0} folders on the phone, reading the file list (this can take a few minutes)..." -f $folders.Count) 'Title'

    $list = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $folders.Count; $i++) {
        if (Test-Stop) { return $null }
        $fn = $folders[$i]
        Send-Progress 'Scan' ($i + 1) $folders.Count
        $sub = Get-IPhoneSubFolder $fn
        if (-not $sub) { Write-Log "  Can't open $fn - skipped" 'Error'; continue }
        $n = 0
        foreach ($it in @($sub.Items())) {
            if ($it.IsFolder) { continue }
            $list.Add([pscustomobject]@{ Folder = $fn; Name = (Get-ItemFileName $it); Size = (Get-ItemFileSize $it) })
            $n++
        }
        Write-Log ("  {0}: {1} files" -f $fn, $n)
    }
    , $list
}

# ---------------------------------------------------------------- copying

function Copy-IPhoneItem($Item, [string]$DestDir, [string]$Target, [uint64]$Expected, [int]$StallSeconds) {
    # Returns 'Ok', 'Failed' or 'Stopped'
    if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue }
    # 4 = no progress window, 16 = yes to all, 512 = no folder prompts, 1024 = no error dialogs
    $script:Shell.NameSpace($DestDir).CopyHere($Item, 4 + 16 + 512 + 1024)

    # CopyHere returns immediately - wait until the whole file is really on disk
    $appearTimeout = 60 + [math]::Ceiling($Expected / 1MB)
    $sinceStart = [Diagnostics.Stopwatch]::StartNew()
    $sinceChange = [Diagnostics.Stopwatch]::StartNew()
    $lastSize = -1; $stable = 0
    while ($true) {
        if (Test-Stop) { return 'Stopped' }
        Start-Sleep -Milliseconds 250
        if (Test-Path -LiteralPath $Target) {
            $len = (Get-Item -LiteralPath $Target).Length
            if ($len -ne $lastSize) { $lastSize = $len; $sinceChange.Restart(); $stable = 0 } else { $stable++ }
            if ($Expected -gt 0) {
                if ($len -eq $Expected -and (Test-FileUnlocked $Target)) { return 'Ok' }
            } elseif ($len -gt 0 -and $stable -ge 12 -and (Test-FileUnlocked $Target)) {
                return 'Ok'   # size unknown: done once it stopped growing for 3 s
            }
            if ($sinceChange.Elapsed.TotalSeconds -gt $StallSeconds) { return 'Failed' }
        } elseif ($sinceStart.Elapsed.TotalSeconds -gt $appearTimeout) {
            return 'Failed'
        }
    }
}

function Invoke-IPhoneCopy {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [int]$MaxRetries = 5,
        [int]$StallSeconds = 90,
        [switch]$ListOnly,
        [scriptblock]$Log,
        [scriptblock]$Progress,
        [scriptblock]$ShouldStop
    )
    Initialize-Run $Destination $Log $Progress $ShouldStop
    $result = [pscustomobject]@{ Total = 0; TotalBytes = 0.0; Copied = 0; Skipped = 0; Failed = @(); Stopped = $false; Elapsed = [TimeSpan]::Zero }
    $failed = New-Object System.Collections.Generic.List[string]
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Set-KeepAwake $true
    try {
        Write-Log "Looking for the iPhone..." 'Title'
        $plan = Get-IPhoneFileList
        if ($null -eq $plan) { $result.Stopped = $true; return $result }
        $result.Total = $plan.Count
        $result.TotalBytes = [double](($plan | Measure-Object Size -Sum).Sum)
        Write-Log ("Total on the phone: {0} files, {1}" -f $plan.Count, (Format-Size $result.TotalBytes)) 'Title'

        try {
            $free = ([IO.DriveInfo]([IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Destination).ProviderPath))).AvailableFreeSpace
            Write-Log ("Free space at the destination: {0}" -f (Format-Size $free)) 'Title'
            if ($free -lt $result.TotalBytes) { Write-Log "WARNING: there may not be enough free space!" 'Error' }
        } catch {}
        if ($ListOnly) { return $result }

        $bytesDone = 0.0; $bytesCopied = 0.0; $i = 0
        foreach ($group in ($plan | Group-Object Folder)) {
            $fn = $group.Name
            $destDir = Join-Path $Destination $fn
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            $index = $null   # built only when something in this folder actually needs copying

            foreach ($f in $group.Group) {
                if (Test-Stop) { $result.Stopped = $true; return $result }
                $i++
                $target = Join-Path $destDir $f.Name
                $label = "$fn\$($f.Name)"

                if (Test-AlreadyCopied $target $f.Size) {
                    $result.Skipped++; $bytesDone += $f.Size
                    Send-Progress 'Copy' $i $plan.Count $bytesDone $result.TotalBytes 0 $label
                    continue
                }

                $status = 'Failed'
                for ($try = 1; $try -le $MaxRetries; $try++) {
                    if ($null -eq $index) { $index = Get-FileIndex (Get-IPhoneSubFolder $fn) }
                    $item = $index[$f.Name]
                    if ($item) {
                        try { $status = Copy-IPhoneItem $item $destDir $target $f.Size $StallSeconds }
                        catch { $status = 'Failed'; Write-Log "  error: $($_.Exception.Message)" 'Error' }
                    } else {
                        Write-Log "  $label not found on the phone" 'Warn'
                    }
                    if ($status -ne 'Failed' -or $try -eq $MaxRetries) { break }

                    $wait = [math]::Min(5 * $try, 30)
                    Write-Log ("  [{0}/{1}] {2} failed (attempt {3}/{4}), retrying in {5}s" -f $i, $plan.Count, $label, $try, $MaxRetries, $wait) 'Warn'
                    Wait-Seconds $wait
                    $index = $null   # the phone may have reconnected - look it up again
                }

                if ($status -eq 'Stopped') { $result.Stopped = $true; return $result }
                if ($status -eq 'Ok') {
                    $result.Copied++; $bytesDone += $f.Size; $bytesCopied += $f.Size
                    Write-Log ("[{0}/{1}] OK {2} ({3})" -f $i, $plan.Count, $label, (Format-Size $f.Size)) 'Ok'
                } else {
                    $failed.Add($label)
                    Write-Log ("[{0}/{1}] FAILED {2} after {3} attempts" -f $i, $plan.Count, $label, $MaxRetries) 'Error'
                }
                $speed = if ($timer.Elapsed.TotalSeconds -gt 0) { $bytesCopied / $timer.Elapsed.TotalSeconds } else { 0 }
                Send-Progress 'Copy' $i $plan.Count $bytesDone $result.TotalBytes $speed $label
            }
        }
    } finally {
        Set-KeepAwake $false
        $result.Elapsed = $timer.Elapsed
        $result.Failed = $failed.ToArray()
        Write-Log "==================== SUMMARY ====================" 'Title'
        if ($result.Stopped) { Write-Log "Stopped. Run it again to continue where it left off." 'Warn' }
        Write-Log ("Copied now: {0}   Already there: {1}   Failed: {2}   Time: {3:hh\:mm\:ss}" -f $result.Copied, $result.Skipped, $failed.Count, $result.Elapsed) 'Title'
        $failFile = Join-Path $Destination 'iphone-copy-failed.txt'
        if ($failed.Count -gt 0) {
            $failed | Set-Content -LiteralPath $failFile -Encoding UTF8
            Write-Log "Failed files are listed in $failFile - run the copy again, only missing files will be copied." 'Warn'
        } elseif (-not $result.Stopped) {
            Remove-Item -LiteralPath $failFile -ErrorAction SilentlyContinue
            Write-Log "All files copied successfully." 'Ok'
        }
    }
    $result
}

# ---------------------------------------------------------------- verifying

function Invoke-IPhoneVerify {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [scriptblock]$Log,
        [scriptblock]$Progress,
        [scriptblock]$ShouldStop
    )
    Initialize-Run $Destination $Log $Progress $ShouldStop
    $result = [pscustomobject]@{ Total = 0; TotalBytes = 0.0; Matching = 0; Missing = @(); WrongSize = @(); Stopped = $false }
    Write-Log "Checking that every file on the iPhone is in $Destination (nothing is copied)..." 'Title'

    $plan = Get-IPhoneFileList
    if ($null -eq $plan) { $result.Stopped = $true; return $result }
    $result.Total = $plan.Count
    $result.TotalBytes = [double](($plan | Measure-Object Size -Sum).Sum)

    $missing = New-Object System.Collections.Generic.List[string]
    $wrong = New-Object System.Collections.Generic.List[string]
    $types = @{}
    $i = 0
    foreach ($f in $plan) {
        $i++
        $ext = [IO.Path]::GetExtension($f.Name).ToUpper()
        $types[$ext] = 1 + [int]$types[$ext]
        $label = "$($f.Folder)\$($f.Name)"
        $target = Join-Path (Join-Path $Destination $f.Folder) $f.Name
        if (-not (Test-Path -LiteralPath $target)) { $missing.Add($label) }
        elseif ($f.Size -gt 0 -and (Get-Item -LiteralPath $target).Length -ne $f.Size) { $wrong.Add($label) }
        else { $result.Matching++ }
        if ($i % 200 -eq 0 -or $i -eq $plan.Count) { Send-Progress 'Verify' $i $plan.Count }
    }
    $result.Missing = $missing.ToArray()
    $result.WrongSize = $wrong.ToArray()

    Write-Log "==================== RESULT ====================" 'Title'
    Write-Log ("On the phone: {0} files, {1}" -f $result.Total, (Format-Size $result.TotalBytes)) 'Title'
    Write-Log ("Matching on disk: {0}" -f $result.Matching) 'Ok'
    $lvl = if ($missing.Count) { 'Error' } else { 'Ok' }
    Write-Log ("Missing: {0}" -f $missing.Count) $lvl
    $missing | Select-Object -First 50 | ForEach-Object { Write-Log "   MISSING  $_" 'Error' }
    $lvl = if ($wrong.Count) { 'Error' } else { 'Ok' }
    Write-Log ("Wrong size (incomplete): {0}" -f $wrong.Count) $lvl
    $wrong | Select-Object -First 50 | ForEach-Object { Write-Log "   WRONG SIZE  $_" 'Error' }
    if ($missing.Count + $wrong.Count -gt 100) { Write-Log "   (only the first 50 of each are listed)" 'Warn' }
    $typeText = ($types.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "{0} {1}" -f $_.Key.TrimStart('.'), $_.Value }) -join ', '
    Write-Log "File types: $typeText   (screenshots are PNG)"
    $result
}
