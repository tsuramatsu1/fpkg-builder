#requires -Version 5.1
<#
    PS5 Backport Builder - Windows GUI

    Builds a small update package that installs on top of an already-installed
    base game, carrying only the backport files.

    The base PKG must be the exact package the console installed; the build
    verifies the finished update references its digest before you install it.
#>

param(
    [switch]$ValidateOnly
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Everything the GUI launches ships beside it; the publishing toolkit itself is
# located by build-backport.ps1, which discovers it at run time.
$repoRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$builderScript = Join-Path $repoRoot 'build-backport.ps1'
$infoScript = Join-Path $repoRoot 'scripts\pkg-info.py'

$script:process = $null
$script:stdoutTask = $null
$script:stderrTask = $null
$script:stdoutEnded = $true
$script:stderrEnded = $true
$script:operation = 'Build'
$script:referenceDigest = $null
$script:lastOutput = $null
$script:workFolder = $null
$script:cancelled = $false

function Show-Error([string]$message) {
    [void][System.Windows.Forms.MessageBox]::Show(
        $form, $message, 'PS5 Backport Builder',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error)
}

function Quote-Argument([string]$value) {
    if ($null -eq $value -or $value.Length -eq 0) { return '""' }
    if ($value -notmatch '[\s"]') { return $value }
    $escaped = [regex]::Replace($value, '(\\*)"', {
        param($match) $match.Groups[1].Value + $match.Groups[1].Value + '\"' })
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

# ------------------------------------------------------------------ layout
$form = New-Object System.Windows.Forms.Form
$form.Text = 'PS5 Backport Builder'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1080, 800)
$form.MinimumSize = New-Object System.Drawing.Size(880, 620)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 1
$root.RowCount = 5
$root.Padding = New-Object System.Windows.Forms.Padding(12)
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$form.Controls.Add($root)

$paths = New-Object System.Windows.Forms.GroupBox
$paths.Text = 'Inputs'
$paths.Dock = 'Fill'
$paths.AutoSize = $true
$paths.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 10)
[void]$root.Controls.Add($paths, 0, 0)

$pathGrid = New-Object System.Windows.Forms.TableLayoutPanel
$pathGrid.Dock = 'Fill'
$pathGrid.AutoSize = $true
$pathGrid.ColumnCount = 3
$pathGrid.RowCount = 4
[void]$pathGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 215)))
[void]$pathGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$pathGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$paths.Controls.Add($pathGrid)

function Add-PathRow {
    param([int]$Row, [string]$LabelText)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $LabelText
    $label.AutoSize = $true
    $label.Anchor = 'Left'
    $label.Margin = New-Object System.Windows.Forms.Padding(0, 8, 8, 6)

    $text = New-Object System.Windows.Forms.TextBox
    $text.Dock = 'Fill'
    $text.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)

    $browse = New-Object System.Windows.Forms.Button
    $browse.Text = 'Browse...'
    $browse.AutoSize = $true
    $browse.MinimumSize = New-Object System.Drawing.Size(88, 27)
    $browse.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)

    [void]$pathGrid.Controls.Add($label, 0, $Row)
    [void]$pathGrid.Controls.Add($text, 1, $Row)
    [void]$pathGrid.Controls.Add($browse, 2, $Row)
    return [PSCustomObject]@{ TextBox = $text; BrowseButton = $browse }
}

$gameRow = Add-PathRow -Row 0 -LabelText 'Game folder (dump):'
$backportRow = Add-PathRow -Row 1 -LabelText 'Backport files (optional):'
$referenceRow = Add-PathRow -Row 2 -LabelText 'Output folder:'
$outputRow = Add-PathRow -Row 3 -LabelText 'Name (optional):'

$txtGame = $gameRow.TextBox
$txtBackport = $backportRow.TextBox
$txtOutDir = $referenceRow.TextBox
$txtName = $outputRow.TextBox

$gameHint = New-Object System.Windows.Forms.Label
$gameHint.Text = 'Both packages land in the output folder as <name>.pkg and <name>-backport.pkg. Name defaults to the title id. Leave the backport blank to build only the base.'
$gameHint.AutoSize = $true
$gameHint.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 6)
$pathGrid.RowCount = 5
[void]$pathGrid.Controls.Add($gameHint, 1, 4)
$pathGrid.SetColumnSpan($gameHint, 2)

# ------------------------------------------------------------------ options
$options = New-Object System.Windows.Forms.GroupBox
$options.Text = 'Options'
$options.Dock = 'Fill'
$options.AutoSize = $true
$options.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 10)
[void]$root.Controls.Add($options, 0, 1)

$optionFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$optionFlow.Dock = 'Fill'
$optionFlow.AutoSize = $true
$optionFlow.WrapContents = $true
[void]$options.Controls.Add($optionFlow)

function Add-Label([string]$text, [int]$leftPad = 0) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $text
    $label.AutoSize = $true
    $label.Margin = New-Object System.Windows.Forms.Padding($leftPad, 9, 6, 0)
    [void]$optionFlow.Controls.Add($label)
    return $label
}

[void](Add-Label 'New contentVersion:')
$txtVersion = New-Object System.Windows.Forms.TextBox
$txtVersion.Width = 110
$txtVersion.Margin = New-Object System.Windows.Forms.Padding(0, 5, 4, 0)
[void]$optionFlow.Controls.Add($txtVersion)
$lblVersionHint = Add-Label '(blank = auto-bump from the base)'

[void](Add-Label 'Compression:' 24)
$cmbCompression = New-Object System.Windows.Forms.ComboBox
$cmbCompression.DropDownStyle = 'DropDownList'
$cmbCompression.Width = 70
$cmbCompression.Margin = New-Object System.Windows.Forms.Padding(0, 5, 4, 0)
foreach ($level in -4..9) { [void]$cmbCompression.Items.Add($level) }
$cmbCompression.SelectedItem = 7
[void]$optionFlow.Controls.Add($cmbCompression)

$chkKeepWork = New-Object System.Windows.Forms.CheckBox
$chkKeepWork.Text = 'Keep work folder'
$chkKeepWork.AutoSize = $true
$chkKeepWork.Margin = New-Object System.Windows.Forms.Padding(24, 7, 0, 0)
[void]$optionFlow.Controls.Add($chkKeepWork)

# ------------------------------------------------------------------ log
$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Both'
$log.WordWrap = $false
$log.Dock = 'Fill'
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$log.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 8)
[void]$root.Controls.Add($log, 0, 2)

$actions = New-Object System.Windows.Forms.FlowLayoutPanel
$actions.Dock = 'Fill'
$actions.AutoSize = $true
$actions.FlowDirection = 'LeftToRight'
[void]$root.Controls.Add($actions, 0, 3)

$btnBuild = New-Object System.Windows.Forms.Button
$btnBuild.Text = 'Build'
$btnBuild.AutoSize = $true
$btnBuild.MinimumSize = New-Object System.Drawing.Size(150, 32)
[void]$actions.Controls.Add($btnBuild)

$btnInspect = New-Object System.Windows.Forms.Button
$btnInspect.Text = 'Inspect base PKG'
$btnInspect.AutoSize = $true
$btnInspect.MinimumSize = New-Object System.Drawing.Size(150, 32)
$btnInspect.Margin = New-Object System.Windows.Forms.Padding(8, 3, 3, 3)
[void]$actions.Controls.Add($btnInspect)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'
$btnCancel.AutoSize = $true
$btnCancel.Enabled = $false
$btnCancel.MinimumSize = New-Object System.Drawing.Size(110, 32)
$btnCancel.Margin = New-Object System.Windows.Forms.Padding(8, 3, 3, 3)
[void]$actions.Controls.Add($btnCancel)

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Ready'
$status.AutoSize = $true
$status.Margin = New-Object System.Windows.Forms.Padding(16, 11, 0, 0)
[void]$actions.Controls.Add($status)

# ------------------------------------------------------------------ footer
$footer = New-Object System.Windows.Forms.Label
$footer.Text = 'Drakmor and Tsuramatsu'
$footer.AutoSize = $true
$footer.Anchor = 'Right'
$footer.ForeColor = [System.Drawing.SystemColors]::GrayText
$footer.Margin = New-Object System.Windows.Forms.Padding(0, 8, 2, 0)
[void]$root.Controls.Add($footer, 0, 4)

# ------------------------------------------------------------------ helpers
function Append-Log([string]$line) {
    if ($null -eq $line) { return }
    $log.AppendText(($line -replace "`r`n", "`n" -replace "`n", [Environment]::NewLine))
    $log.AppendText([Environment]::NewLine)
}

function Remove-WorkFolder {
    if ([string]::IsNullOrWhiteSpace($script:workFolder)) { return }
    if (-not (Test-Path -LiteralPath $script:workFolder)) { $script:workFolder = $null; return }
    try {
        $bytes = (Get-ChildItem -LiteralPath $script:workFolder -Recurse -File -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum
        Remove-Item -LiteralPath $script:workFolder -Recurse -Force -ErrorAction Stop
        if ($bytes) { Append-Log ("Removed work folder ({0:N0} bytes reclaimed)." -f $bytes) }
    } catch {
        Append-Log "Could not remove the work folder: $script:workFolder"
    }
    $script:workFolder = $null
}

function Set-Busy([bool]$busy) {
    $btnBuild.Enabled = -not $busy
    $btnInspect.Enabled = -not $busy
    $btnCancel.Enabled = $busy
}

function Get-PythonPath {
    $candidate = (Get-Command python -ErrorAction SilentlyContinue)
    if ($candidate) { return $candidate.Source }
    return 'python'
}

function Invoke-Tool {
    <# Run a console tool synchronously and stream its output into the log. #>
    param([string]$FilePath, [string[]]$Arguments, [string]$Activity)
    $status.Text = $Activity
    Set-Busy $true
    $form.Refresh()
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = (($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd()
        $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        foreach ($line in ($out -split "`r?`n")) { if ($line) { Append-Log $line } }
        foreach ($line in ($err -split "`r?`n")) { if ($line) { Append-Log $line } }
        return [PSCustomObject]@{ ExitCode = $proc.ExitCode; StdOut = $out }
    } finally {
        Set-Busy $false
        $status.Text = 'Ready'
    }
}

function Read-Json([string]$text) {
    $start = $text.IndexOf('{')
    if ($start -lt 0) { return $null }
    try { return $text.Substring($start) | ConvertFrom-Json } catch { return $null }
}

function Get-BasePath {
    $dir = $txtOutDir.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($dir)) { return $null }
    $name = $txtName.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        $game = $txtGame.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($game)) { return $null }
        $param = Join-Path $game 'sce_sys\param.json'
        if (Test-Path -LiteralPath $param -PathType Leaf) {
            try { $name = (Get-Content -LiteralPath $param -Raw -Encoding UTF8 | ConvertFrom-Json).titleId } catch { }
        }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = Split-Path -Leaf $game }
    }
    return (Join-Path $dir ($name + '.pkg'))
}

function Inspect-Reference {
    $base = Get-BasePath
    if ([string]::IsNullOrWhiteSpace($base)) {
        Show-Error 'Set the output folder, and either a name or a game folder to take it from.'
        return $null
    }
    if (-not (Test-Path -LiteralPath $base -PathType Leaf)) {
        Append-Log "No base package yet at $base - it will be built."
        return $null
    }
    $result = Invoke-Tool -FilePath (Get-PythonPath) `
        -Arguments @($infoScript, $base, '--next-version') -Activity 'Reading base package...'
    if ($result.ExitCode -ne 0) { return $null }
    $info = Read-Json $result.StdOut
    if (-not $info) { Show-Error 'Could not parse package information.'; return $null }
    $script:referenceDigest = $info.digest
    if ([string]::IsNullOrWhiteSpace($txtVersion.Text) -and $info.nextContentVersion) {
        $lblVersionHint.Text = "(blank = auto: $($info.nextContentVersion))"
    }
    return $info
}

# ------------------------------------------------------------------ browsing
$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$openPkg = New-Object System.Windows.Forms.OpenFileDialog
$openPkg.Filter = 'PKG package (*.pkg)|*.pkg|All files (*.*)|*.*'
$openPkg.CheckFileExists = $true
$savePkg = New-Object System.Windows.Forms.SaveFileDialog
$savePkg.Filter = 'PKG package (*.pkg)|*.pkg'
$savePkg.OverwritePrompt = $false

$gameRow.BrowseButton.Add_Click({
    if ($folderDialog.ShowDialog($form) -eq 'OK') { $txtGame.Text = $folderDialog.SelectedPath }
})
$backportRow.BrowseButton.Add_Click({
    if ($folderDialog.ShowDialog($form) -eq 'OK') { $txtBackport.Text = $folderDialog.SelectedPath }
})
$referenceRow.BrowseButton.Add_Click({
    if ($folderDialog.ShowDialog($form) -eq 'OK') { $txtOutDir.Text = $folderDialog.SelectedPath }
})
$outputRow.BrowseButton.Visible = $false

$btnInspect.Add_Click({ [void](Inspect-Reference) })

# ------------------------------------------------------------------ build
function Pump-Output {
    foreach ($pair in @(@('stdoutTask', 'stdoutEnded'), @('stderrTask', 'stderrEnded'))) {
        $taskName = $pair[0]; $endedName = $pair[1]
        $task = Get-Variable -Name $taskName -Scope Script -ValueOnly
        if ($null -eq $task) { continue }
        if ($task.IsCompleted) {
            $line = $task.Result
            if ($null -eq $line) {
                Set-Variable -Name $endedName -Scope Script -Value $true
                Set-Variable -Name $taskName -Scope Script -Value $null
            } else {
                Append-Log $line
                $stream = if ($taskName -eq 'stdoutTask') {
                    $script:process.StandardOutput
                } else {
                    $script:process.StandardError
                }
                Set-Variable -Name $taskName -Scope Script -Value $stream.ReadLineAsync()
            }
        }
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 120
$timer.Add_Tick({
    if ($null -eq $script:process) { return }
    Pump-Output
    if ($script:process.HasExited -and $script:stdoutEnded -and $script:stderrEnded) {
        $timer.Stop()
        $code = $script:process.ExitCode
        $script:process = $null
        Set-Busy $false
        if ($script:cancelled -or $code -ne 0) { Remove-WorkFolder }
        if ($script:cancelled) {
            $status.Text = 'Cancelled'
            Append-Log 'Cancelled.'
        } elseif ($code -eq 0) {
            $status.Text = 'Update built successfully'
            Append-Log ''
            Append-Log 'Done. Copy the update to the console and install it over the base game.'
        } else {
            $status.Text = "Build failed (exit $code)"
        }
    }
})

function Start-Build {
    $game = $txtGame.Text.Trim()
    $backport = $txtBackport.Text.Trim()
    $dir = $txtOutDir.Text.Trim()
    $name = $txtName.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($dir)) {
        Show-Error 'Choose the output folder. Both packages are written there.'
        return
    }
    $base = Get-BasePath
    if ([string]::IsNullOrWhiteSpace($base)) {
        Show-Error 'Set a name, or a game folder to take the name from.'
        return
    }
    $baseExists = Test-Path -LiteralPath $base -PathType Leaf
    if (-not $baseExists -and [string]::IsNullOrWhiteSpace($game)) {
        Show-Error "No base package at $base yet, so the game folder is needed to build it."
        return
    }
    $wantUpdate = -not [string]::IsNullOrWhiteSpace($backport)
    if (-not $wantUpdate -and $baseExists) {
        Show-Error 'Nothing to do: the base package already exists and no backport folder is set.'
        return
    }

    $script:workFolder = Join-Path ([IO.Path]::GetTempPath()) ("backport-builder-" + [Guid]::NewGuid().ToString('N'))
    $script:cancelled = $false
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $builderScript,
        '-OutputFolder', $dir,
        '-WorkFolder', $script:workFolder,
        '-CompressionLevel', [string]$cmbCompression.SelectedItem, '-Force')
    if (-not [string]::IsNullOrWhiteSpace($game)) { $arguments += @('-GameFolder', $game) }
    if (-not [string]::IsNullOrWhiteSpace($name)) { $arguments += @('-Name', $name) }
    if ($wantUpdate) { $arguments += @('-BackportFolder', $backport) }
    if (-not [string]::IsNullOrWhiteSpace($txtVersion.Text)) {
        $arguments += @('-ContentVersion', $txtVersion.Text.Trim())
    }
    if ($chkKeepWork.Checked) { $arguments += '-KeepWork' }

    $log.Clear()
    Append-Log $(if ($baseExists) { "Using the existing base package: $base" } else { "Building the base package from $game" })
    Append-Log $(if ($wantUpdate) { "Then the backport update from $backport" } else { 'No backport folder set - base package only.' })
    Append-Log ''

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe).Source
    $psi.Arguments = (($arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $script:process = [System.Diagnostics.Process]::Start($psi)
    $script:lastOutput = $dir
    $script:stdoutEnded = $false
    $script:stderrEnded = $false
    $script:stdoutTask = $script:process.StandardOutput.ReadLineAsync()
    $script:stderrTask = $script:process.StandardError.ReadLineAsync()
    Set-Busy $true
    $status.Text = 'Building...'
    $timer.Start()
}

$btnBuild.Add_Click({ Start-Build })

$btnCancel.Add_Click({
    if ($null -eq $script:process -or $script:process.HasExited) { return }
    $script:cancelled = $true
    $btnCancel.Enabled = $false
    $status.Text = 'Cancelling...'
    Append-Log 'Cancelling - stopping the publisher and its child processes...'
    # taskkill /T walks the process tree. Process.Kill() on .NET Framework stops only
    # the powershell wrapper and leaves prospero-pub-cmd.exe running to completion.
    try {
        Start-Process -FilePath 'taskkill.exe' `
            -ArgumentList @('/PID', [string]$script:process.Id, '/T', '/F') `
            -NoNewWindow -Wait -ErrorAction Stop | Out-Null
    } catch {
        try { $script:process.Kill() } catch { }
    }
})

$form.Add_FormClosing({
    if ($null -ne $script:process -and -not $script:process.HasExited) {
        try { $script:process.Kill() } catch { }
    }
})

if ($ValidateOnly) {
    Write-Host 'backport-builder-gui.ps1 loaded and constructed successfully.'
    $form.Dispose()
    exit 0
}

[void][System.Windows.Forms.Application]::Run($form)
