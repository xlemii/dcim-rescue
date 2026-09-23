# DCIM Rescue - window version. Start it with "DCIM Rescue.bat" (it needs -STA).
# The copy runs in a background runspace so the window stays responsive; the two sides talk
# through the synchronized $sync hashtable (log queue, progress, stop flag, result).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$corePath = Join-Path $PSScriptRoot 'iPhoneCopy.Core.ps1'
. $corePath   # on the UI thread only used for the quick "is the phone connected?" check

# ---------------------------------------------------------------- settings

$settingsFile = Join-Path $env:APPDATA 'DCIMRescue\settings.json'
$settings = $null
try { $settings = Get-Content -LiteralPath $settingsFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}

function Save-Settings {
    try {
        New-Item -ItemType Directory -Path (Split-Path $settingsFile) -Force | Out-Null
        [pscustomobject]@{ Destination = $txtDest.Text; Retries = [int]$numRetries.Value; OpenWhenDone = $chkOpen.Checked } |
            ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding UTF8
    } catch {}
}

# ---------------------------------------------------------------- state shared with the worker

$sync = [hashtable]::Synchronized(@{
    Queue    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    Progress = $null
    Running  = $false
    Stop     = $false
    Result   = $null
    Mode     = $null
})
$script:worker = $null
$script:deviceStatus = $null

# ---------------------------------------------------------------- window

$C = @{
    Accent = [Drawing.Color]::FromArgb(0, 113, 227)
    Text   = [Drawing.Color]::FromArgb(29, 29, 31)
    Muted  = [Drawing.Color]::FromArgb(110, 110, 115)
    Green  = [Drawing.Color]::FromArgb(40, 160, 70)
    Orange = [Drawing.Color]::FromArgb(230, 140, 0)
    Red    = [Drawing.Color]::FromArgb(215, 45, 45)
    LogBg  = [Drawing.Color]::FromArgb(248, 248, 250)
}
$logColors = @{ Info = $C.Muted; Ok = $C.Green; Warn = $C.Orange; Error = $C.Red; Title = $C.Accent }

$form = New-Object Windows.Forms.Form
$form.Text = 'DCIM Rescue'
$form.ClientSize = New-Object Drawing.Size(760, 600)
$form.MinimumSize = New-Object Drawing.Size(720, 560)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 9.5)
$form.BackColor = [Drawing.Color]::White
$form.ForeColor = $C.Text
try { $form.Icon = [Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path) } catch {}

function Add-Control($Control, $X, $Y, $W, $H, $Parent = $form, $Anchor = 'Top, Left') {
    $Control.Location = New-Object Drawing.Point($X, $Y)
    $Control.Size = New-Object Drawing.Size($W, $H)
    $Control.Anchor = $Anchor
    $Parent.Controls.Add($Control)
    $Control
}

$lblTitle = Add-Control (New-Object Windows.Forms.Label) 20 14 600 34
$lblTitle.Text = 'DCIM Rescue'
$lblTitle.Font = New-Object Drawing.Font('Segoe UI Semibold', 17)

$lblSub = Add-Control (New-Object Windows.Forms.Label) 22 50 700 20
$lblSub.Text = 'Copies all photos, videos and screenshots from your iPhone over USB - with checking, retries and resume.'
$lblSub.ForeColor = $C.Muted

# 1. phone
$grpPhone = Add-Control (New-Object Windows.Forms.GroupBox) 20 80 720 64 $form 'Top, Left, Right'
$grpPhone.Text = '1. Phone'
$lblDot = Add-Control (New-Object Windows.Forms.Label) 14 24 26 28 $grpPhone
$lblDot.Text = [string][char]0x25CF
$lblDot.Font = New-Object Drawing.Font('Segoe UI', 15)
$lblDevice = Add-Control (New-Object Windows.Forms.Label) 42 30 540 22 $grpPhone 'Top, Left, Right'
$btnRefresh = Add-Control (New-Object Windows.Forms.Button) 596 24 110 30 $grpPhone 'Top, Right'
$btnRefresh.Text = 'Refresh'

# 2. destination
$grpDest = Add-Control (New-Object Windows.Forms.GroupBox) 20 152 720 64 $form 'Top, Left, Right'
$grpDest.Text = '2. Save to folder'
$txtDest = Add-Control (New-Object Windows.Forms.TextBox) 16 27 566 26 $grpDest 'Top, Left, Right'
$btnBrowse = Add-Control (New-Object Windows.Forms.Button) 596 24 110 30 $grpDest 'Top, Right'
$btnBrowse.Text = 'Browse...'

# options
$lblRetries = Add-Control (New-Object Windows.Forms.Label) 22 229 110 22
$lblRetries.Text = 'Retries per file:'
$numRetries = Add-Control (New-Object Windows.Forms.NumericUpDown) 134 226 52 26
$numRetries.Minimum = 1; $numRetries.Maximum = 20; $numRetries.Value = 5
$chkOpen = Add-Control (New-Object Windows.Forms.CheckBox) 214 227 260 24
$chkOpen.Text = 'Open the folder when finished'
$chkOpen.Checked = $true

# 3. actions
$btnCopy = Add-Control (New-Object Windows.Forms.Button) 20 262 180 42
$btnCopy.Text = 'Start copying'
$btnCopy.Font = New-Object Drawing.Font('Segoe UI Semibold', 10.5)
$btnCopy.BackColor = $C.Accent
$btnCopy.ForeColor = [Drawing.Color]::White
$btnCopy.FlatStyle = 'Flat'
$btnCopy.FlatAppearance.BorderSize = 0
$btnVerify = Add-Control (New-Object Windows.Forms.Button) 210 262 150 42
$btnVerify.Text = 'Check the copy'
$btnStop = Add-Control (New-Object Windows.Forms.Button) 370 262 100 42
$btnStop.Text = 'Stop'
$btnStop.Enabled = $false
$btnOpen = Add-Control (New-Object Windows.Forms.Button) 600 262 140 42 $form 'Top, Right'
$btnOpen.Text = 'Open folder'

$progressBar = Add-Control (New-Object Windows.Forms.ProgressBar) 20 318 720 20 $form 'Top, Left, Right'
$progressBar.Maximum = 1000
$progressBar.MarqueeAnimationSpeed = 30
$lblStatus = Add-Control (New-Object Windows.Forms.Label) 20 344 720 22 $form 'Top, Left, Right'
$lblStatus.Text = 'Ready. Unlock your iPhone, then press "Start copying".'

$rtbLog = Add-Control (New-Object Windows.Forms.RichTextBox) 20 372 720 212 $form 'Top, Bottom, Left, Right'
$rtbLog.ReadOnly = $true
$rtbLog.BackColor = $C.LogBg
$rtbLog.BorderStyle = 'FixedSingle'
$rtbLog.Font = New-Object Drawing.Font('Consolas', 9)
$rtbLog.HideSelection = $false

$toolTip = New-Object Windows.Forms.ToolTip
$toolTip.SetToolTip($btnCopy, 'Copies everything that is not in the folder yet. Safe to run again - finished files are skipped.')
$toolTip.SetToolTip($btnVerify, 'Compares every file on the phone with the folder (name and size). Copies nothing.')
$toolTip.SetToolTip($numRetries, 'How many times to retry a file that fails (e.g. the phone locked or the cable wiggled).')

$txtDest.Text = if ($settings -and $settings.Destination) { $settings.Destination } else { Join-Path ([Environment]::GetFolderPath('MyPictures')) 'iPhone' }
if ($settings -and $settings.Retries) { $numRetries.Value = [math]::Min(20, [math]::Max(1, [int]$settings.Retries)) }
if ($settings -and $null -ne $settings.OpenWhenDone) { $chkOpen.Checked = [bool]$settings.OpenWhenDone }

# ---------------------------------------------------------------- UI helpers

function Add-LogLine([string]$Line, [string]$Level) {
    $rtbLog.SelectionStart = $rtbLog.TextLength
    $rtbLog.SelectionLength = 0
    $rtbLog.SelectionColor = if ($logColors[$Level]) { $logColors[$Level] } else { $C.Muted }
    $rtbLog.AppendText($Line + "`r`n")
}

function Update-DeviceStatus {
    $state = Get-IPhoneState
    switch ($state.Status) {
        'Ready'  { $lblDot.ForeColor = $C.Green;  $lblDevice.Text = "$($state.Name) is connected and unlocked - ready to copy." }
        'Locked' { $lblDot.ForeColor = $C.Orange; $lblDevice.Text = "$($state.Name) found, but photos are hidden. Unlock the phone and tap 'Trust'." }
        default  { $lblDot.ForeColor = $C.Red;    $lblDevice.Text = "No iPhone found. Connect the cable (and install 'Apple Devices' from Microsoft Store)." }
    }
    $script:deviceStatus = $state.Status
}

function Set-Busy([bool]$Busy) {
    foreach ($ctl in @($btnCopy, $btnVerify, $btnBrowse, $btnRefresh, $txtDest, $numRetries)) { $ctl.Enabled = -not $Busy }
    $btnStop.Enabled = $Busy
    $btnCopy.BackColor = if ($Busy) { [Drawing.Color]::FromArgb(160, 190, 230) } else { $C.Accent }
}

function Start-Worker([string]$Mode) {
    $dest = $txtDest.Text.Trim()
    if (-not $dest) { [Windows.Forms.MessageBox]::Show('Choose a folder to save the photos to.', 'DCIM Rescue') | Out-Null; return }
    try { New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop | Out-Null }
    catch { [Windows.Forms.MessageBox]::Show("Can't use this folder:`n$($_.Exception.Message)", 'DCIM Rescue', 'OK', 'Error') | Out-Null; return }
    Save-Settings

    $sync.Stop = $false; $sync.Running = $true; $sync.Result = $null; $sync.Progress = $null; $sync.Mode = $Mode
    $rtbLog.Clear()
    Set-Busy $true
    $progressBar.Style = 'Marquee'
    $lblStatus.Text = 'Connecting to the iPhone...'

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'   # Shell.Application COM needs STA
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($CorePath, $Mode, $Destination, $Retries)
        try {
            . $CorePath
            $log = { param($line, $level) $sync.Queue.Enqueue(@($line, $level)) }
            $progress = { param($p) $sync.Progress = $p }
            $stop = { $sync.Stop }
            if ($Mode -eq 'Verify') {
                $sync.Result = Invoke-IPhoneVerify -Destination $Destination -Log $log -Progress $progress -ShouldStop $stop
            } else {
                $sync.Result = Invoke-IPhoneCopy -Destination $Destination -MaxRetries $Retries -Log $log -Progress $progress -ShouldStop $stop
            }
        } catch {
            $sync.Queue.Enqueue(@("Unexpected error: $($_.Exception.Message)", 'Error'))
        } finally {
            $sync.Running = $false
        }
    }).AddArgument($corePath).AddArgument($Mode).AddArgument($dest).AddArgument([int]$numRetries.Value)
    $script:worker = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}

function Complete-Worker {
    $entry = $null
    while ($sync.Queue.TryDequeue([ref]$entry)) { Add-LogLine $entry[0] $entry[1] }
    try { $script:worker.PS.EndInvoke($script:worker.Handle) | Out-Null } catch {}
    $script:worker.PS.Dispose(); $script:worker.RS.Dispose()
    $script:worker = $null
    Set-Busy $false
    $progressBar.Style = 'Continuous'

    $r = @($sync.Result)[-1]
    $dest = $txtDest.Text.Trim()
    if (-not $r) { $lblStatus.Text = 'Stopped because of an error - see the log below.'; return }
    if ($r.Stopped) { $lblStatus.Text = 'Stopped. Press "Start copying" to continue where it left off.'; return }

    if ($sync.Mode -eq 'Copy') {
        $progressBar.Value = 1000
        if ($r.Failed.Count -eq 0) {
            $lblStatus.Text = "Done! All $($r.Total) files are in the folder ($(Format-Size $r.TotalBytes))."
            [Windows.Forms.MessageBox]::Show("Done!`n`nFiles on the phone: $($r.Total) ($(Format-Size $r.TotalBytes))`nCopied now: $($r.Copied)`nAlready there: $($r.Skipped)`nFailed: 0", 'DCIM Rescue', 'OK', 'Information') | Out-Null
        } else {
            $lblStatus.Text = "$($r.Failed.Count) files failed. Press ""Start copying"" again - only missing files will be copied."
            [Windows.Forms.MessageBox]::Show("$($r.Failed.Count) files could not be copied even after retries.`n`nMake sure the phone stays unlocked and press ""Start copying"" again - only the missing files will be copied.", 'DCIM Rescue', 'OK', 'Warning') | Out-Null
        }
        if ($chkOpen.Checked) { Start-Process explorer.exe $dest }
    } else {
        $bad = $r.Missing.Count + $r.WrongSize.Count
        $progressBar.Value = 1000
        if ($bad -eq 0) {
            $lblStatus.Text = "Everything matches: all $($r.Total) files from the phone are in the folder."
            [Windows.Forms.MessageBox]::Show("Everything matches!`n`nAll $($r.Total) files from the phone ($(Format-Size $r.TotalBytes)) are in the folder with the correct size.", 'DCIM Rescue', 'OK', 'Information') | Out-Null
        } else {
            $lblStatus.Text = "$bad files are missing or incomplete. Press ""Start copying"" to fix them."
            [Windows.Forms.MessageBox]::Show("$($r.Missing.Count) files are missing and $($r.WrongSize.Count) are incomplete.`n`nPress ""Start copying"" - it will copy only those.", 'DCIM Rescue', 'OK', 'Warning') | Out-Null
        }
    }
}

# ---------------------------------------------------------------- events

$btnRefresh.Add_Click({ Update-DeviceStatus })

$btnBrowse.Add_Click({
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Where should the photos and videos be saved?'
    $dlg.ShowNewFolderButton = $true
    if (Test-Path -LiteralPath $txtDest.Text) { $dlg.SelectedPath = $txtDest.Text }
    if ($dlg.ShowDialog($form) -eq 'OK') { $txtDest.Text = $dlg.SelectedPath; Save-Settings }
})

$btnCopy.Add_Click({ Start-Worker 'Copy' })
$btnVerify.Add_Click({ Start-Worker 'Verify' })

$btnStop.Add_Click({
    $sync.Stop = $true
    $btnStop.Enabled = $false
    $lblStatus.Text = 'Stopping...'
})

$btnOpen.Add_Click({
    $dest = $txtDest.Text.Trim()
    if (Test-Path -LiteralPath $dest) { Start-Process explorer.exe $dest }
    else { [Windows.Forms.MessageBox]::Show('This folder does not exist yet - it is created when copying starts.', 'DCIM Rescue') | Out-Null }
})

# pumps log lines and progress from the worker into the window
$uiTimer = New-Object Windows.Forms.Timer
$uiTimer.Interval = 250
$uiTimer.Add_Tick({
    $entry = $null; $n = 0
    while ($n -lt 400 -and $sync.Queue.TryDequeue([ref]$entry)) { Add-LogLine $entry[0] $entry[1]; $n++ }
    if ($n -gt 0) { $rtbLog.ScrollToCaret() }

    $p = $sync.Progress
    if ($p -and $script:worker -and -not $sync.Stop) {
        switch ($p.Phase) {
            'Scan' {
                $progressBar.Style = 'Marquee'
                $lblStatus.Text = "Reading the list of files on the phone... folder $($p.Index) of $($p.Total)"
            }
            'Copy' {
                $progressBar.Style = 'Continuous'
                if ($p.TotalBytes -gt 0) { $progressBar.Value = [int][math]::Min(1000, 1000 * $p.BytesDone / $p.TotalBytes) }
                $eta = if ($p.Eta) { 'about ' + $p.Eta.ToString('hh\:mm\:ss') + ' left' } else { 'estimating time...' }
                $lblStatus.Text = "{0} / {1} files   |   {2} of {3}   |   {4:N1} MB/s   |   {5}" -f $p.Index, $p.Total, (Format-Size $p.BytesDone), (Format-Size $p.TotalBytes), ($p.Speed / 1MB), $eta
            }
            'Verify' {
                $progressBar.Style = 'Continuous'
                $progressBar.Value = [int](1000 * $p.Index / [math]::Max(1, $p.Total))
                $lblStatus.Text = "Comparing file $($p.Index) of $($p.Total)..."
            }
        }
    }
    if ($script:worker -and -not $sync.Running) { Complete-Worker }
})

# re-checks the phone every few seconds while idle and not ready yet
$deviceTimer = New-Object Windows.Forms.Timer
$deviceTimer.Interval = 4000
$deviceTimer.Add_Tick({ if (-not $script:worker -and $script:deviceStatus -ne 'Ready') { Update-DeviceStatus } })

$form.Add_Shown({ Update-DeviceStatus; $uiTimer.Start(); $deviceTimer.Start() })

$form.Add_FormClosing({
    param($s, $e)
    if ($script:worker) {
        $answer = [Windows.Forms.MessageBox]::Show("Copying is still running. Stop it and close?`n`nYou can continue later - finished files are skipped.", 'DCIM Rescue', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { $e.Cancel = $true; return }
        $sync.Stop = $true
    }
    Save-Settings
})

[void]$form.ShowDialog()
$uiTimer.Stop(); $deviceTimer.Stop()
$form.Dispose()
