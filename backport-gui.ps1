#requires -Version 5.1
<#
    Backport Update Builder - Windows GUI

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
# located by build-backport-update.ps1, which discovers it at run time.
$repoRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$builderScript = Join-Path $repoRoot 'build-backport-update.ps1'
$creatorScript = Join-Path $repoRoot 'build-backport-files.ps1'
$infoScript = Join-Path $repoRoot 'scripts\pkg-info.py'

function Test-ToolkitRoot([string]$candidate) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $candidate 'scripts\create-gp5-from-folder.py') -PathType Leaf) -and
           (Test-Path -LiteralPath (Join-Path $candidate 'toolchain\prospero-pub-cmd.exe') -PathType Leaf)
}

function Find-ToolkitRoot {
    # Mirrors the discovery in build-backport-update.ps1; used here only to locate
    # build-from-folder.ps1 for the "Build base PKG" action.
    $candidates = @($env:PS5_FPKG_TOOLKIT, $repoRoot, (Join-Path $repoRoot 'fpkg converter'))
    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if (-not [string]::IsNullOrWhiteSpace($documents)) {
        $candidates += (Join-Path $documents 'PS5JB\fpkg converter')
    }
    foreach ($candidate in $candidates) {
        if (Test-ToolkitRoot $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }
    return $null
}

$script:process = $null
$script:stdoutTask = $null
$script:stderrTask = $null
$script:stdoutEnded = $true
$script:stderrEnded = $true
$script:operation = 'Build'
$script:referenceDigest = $null
$script:lastOutput = $null

function Show-Error([string]$message) {
    [void][System.Windows.Forms.MessageBox]::Show(
        $form, $message, 'Backport Update Builder',
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
$form.Text = 'Backport Update Builder'
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
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
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

$gameRow = Add-PathRow -Row 0 -LabelText 'Game folder (optional):'
$backportRow = Add-PathRow -Row 1 -LabelText 'Backport files folder:'
$referenceRow = Add-PathRow -Row 2 -LabelText 'Base PKG (installed build):'
$outputRow = Add-PathRow -Row 3 -LabelText 'Output update (.pkg):'

$txtGame = $gameRow.TextBox
$txtBackport = $backportRow.TextBox
$txtReference = $referenceRow.TextBox
$txtOutput = $outputRow.TextBox

$gameHint = New-Object System.Windows.Forms.Label
$gameHint.Text = 'Leave the game folder blank to unpack the base PKG instead - it already contains every file.'
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

# ------------------------------------------------------ create backport files
$creator = New-Object System.Windows.Forms.GroupBox
$creator.Text = 'Create backport files from decrypted binaries (optional)'
$creator.Dock = 'Fill'
$creator.AutoSize = $true
$creator.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 10)
[void]$root.Controls.Add($creator, 0, 2)

$creatorGrid = New-Object System.Windows.Forms.TableLayoutPanel
$creatorGrid.Dock = 'Fill'
$creatorGrid.AutoSize = $true
$creatorGrid.ColumnCount = 3
$creatorGrid.RowCount = 2
[void]$creatorGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 215)))
[void]$creatorGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$creatorGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$creator.Controls.Add($creatorGrid)

$lblDecrypted = New-Object System.Windows.Forms.Label
$lblDecrypted.Text = 'Decrypted binaries folder:'
$lblDecrypted.AutoSize = $true
$lblDecrypted.Anchor = 'Left'
$lblDecrypted.Margin = New-Object System.Windows.Forms.Padding(0, 8, 8, 6)
$txtDecrypted = New-Object System.Windows.Forms.TextBox
$txtDecrypted.Dock = 'Fill'
$txtDecrypted.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
$btnDecrypted = New-Object System.Windows.Forms.Button
$btnDecrypted.Text = 'Browse...'
$btnDecrypted.AutoSize = $true
$btnDecrypted.MinimumSize = New-Object System.Drawing.Size(88, 27)
$btnDecrypted.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
[void]$creatorGrid.Controls.Add($lblDecrypted, 0, 0)
[void]$creatorGrid.Controls.Add($txtDecrypted, 1, 0)
[void]$creatorGrid.Controls.Add($btnDecrypted, 2, 0)

$creatorFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$creatorFlow.Dock = 'Fill'
$creatorFlow.AutoSize = $true
$creatorFlow.WrapContents = $true
$creatorFlow.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
[void]$creatorGrid.Controls.Add($creatorFlow, 1, 1)
$creatorGrid.SetColumnSpan($creatorFlow, 2)

function Add-CreatorLabel([string]$text, [int]$leftPad = 0) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $text
    $label.AutoSize = $true
    $label.Margin = New-Object System.Windows.Forms.Padding($leftPad, 9, 6, 0)
    [void]$creatorFlow.Controls.Add($label)
}

Add-CreatorLabel 'Target firmware:'
$txtTargetFw = New-Object System.Windows.Forms.TextBox
$txtTargetFw.Width = 70
$txtTargetFw.Text = '4.03'
$txtTargetFw.Margin = New-Object System.Windows.Forms.Padding(0, 5, 4, 0)
[void]$creatorFlow.Controls.Add($txtTargetFw)

Add-CreatorLabel 'Source firmware:' 18
$txtSourceFw = New-Object System.Windows.Forms.TextBox
$txtSourceFw.Width = 70
$txtSourceFw.Margin = New-Object System.Windows.Forms.Padding(0, 5, 4, 0)
[void]$creatorFlow.Controls.Add($txtSourceFw)
Add-CreatorLabel '(blank = lowest that covers the gap)'

$btnCreateBackport = New-Object System.Windows.Forms.Button
$btnCreateBackport.Text = 'Create backport files'
$btnCreateBackport.AutoSize = $true
$btnCreateBackport.MinimumSize = New-Object System.Drawing.Size(160, 27)
$btnCreateBackport.Margin = New-Object System.Windows.Forms.Padding(18, 3, 0, 0)
[void]$creatorFlow.Controls.Add($btnCreateBackport)

# ------------------------------------------------------------------ log
$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Both'
$log.WordWrap = $false
$log.Dock = 'Fill'
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$log.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 8)
[void]$root.Controls.Add($log, 0, 3)

$actions = New-Object System.Windows.Forms.FlowLayoutPanel
$actions.Dock = 'Fill'
$actions.AutoSize = $true
$actions.FlowDirection = 'LeftToRight'
[void]$root.Controls.Add($actions, 0, 4)

$btnBuild = New-Object System.Windows.Forms.Button
$btnBuild.Text = 'Build update'
$btnBuild.AutoSize = $true
$btnBuild.MinimumSize = New-Object System.Drawing.Size(150, 32)
[void]$actions.Controls.Add($btnBuild)

$btnBuildBase = New-Object System.Windows.Forms.Button
$btnBuildBase.Text = 'Build base PKG'
$btnBuildBase.AutoSize = $true
$btnBuildBase.MinimumSize = New-Object System.Drawing.Size(150, 32)
$btnBuildBase.Margin = New-Object System.Windows.Forms.Padding(8, 3, 3, 3)
[void]$actions.Controls.Add($btnBuildBase)

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

# ------------------------------------------------------------------ helpers
function Append-Log([string]$line) {
    if ($null -eq $line) { return }
    $log.AppendText(($line -replace "`r`n", "`n" -replace "`n", [Environment]::NewLine))
    $log.AppendText([Environment]::NewLine)
}

function Set-Busy([bool]$busy) {
    $btnBuild.Enabled = -not $busy
    $btnBuildBase.Enabled = -not $busy
    $btnCreateBackport.Enabled = -not $busy
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

function Inspect-Reference {
    $reference = $txtReference.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($reference)) { Show-Error 'Choose the base PKG first.'; return $null }
    if (-not (Test-Path -LiteralPath $reference -PathType Leaf)) {
        Show-Error "Base PKG not found: $reference"; return $null
    }
    $result = Invoke-Tool -FilePath (Get-PythonPath) `
        -Arguments @($infoScript, $reference, '--next-version') -Activity 'Reading base package...'
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
    if ($openPkg.ShowDialog($form) -eq 'OK') {
        $txtReference.Text = $openPkg.FileName
        [void](Inspect-Reference)
    }
})
$outputRow.BrowseButton.Add_Click({
    if ($savePkg.ShowDialog($form) -eq 'OK') { $txtOutput.Text = $savePkg.FileName }
})

$btnDecrypted.Add_Click({
    if ($folderDialog.ShowDialog($form) -eq 'OK') { $txtDecrypted.Text = $folderDialog.SelectedPath }
})

$btnCreateBackport.Add_Click({
    $decrypted = $txtDecrypted.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($decrypted)) {
        Show-Error 'Choose the folder holding the game''s decrypted binaries.'
        return
    }
    if (-not (Test-Path -LiteralPath $decrypted -PathType Container)) {
        Show-Error "Folder not found: $decrypted"; return
    }
    $target = $txtTargetFw.Text.Trim()
    if ($target -notmatch '^\d{1,2}\.\d{2}$') {
        Show-Error 'Target firmware must look like 4.03.'; return
    }
    if ($folderDialog.ShowDialog($form) -ne 'OK') { return }
    $out = $folderDialog.SelectedPath
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $creatorScript,
                   '-DecryptedFolder', $decrypted, '-OutputFolder', $out,
                   '-TargetFirmware', $target, '-Force')
    $source = $txtSourceFw.Text.Trim()
    if (-not [string]::IsNullOrWhiteSpace($source)) { $arguments += @('-SourceFirmware', $source) }
    $log.Clear()
    $result = Invoke-Tool -FilePath (Get-Command powershell.exe).Source `
        -Arguments $arguments -Activity 'Creating backport files...'
    if ($result.ExitCode -eq 0) {
        $txtBackport.Text = $out
        Append-Log ''
        Append-Log 'Backport files created and selected. Set the base PKG and output path, then Build update.'
    } else {
        Append-Log 'Backport creation failed.'
    }
})

$btnInspect.Add_Click({ [void](Inspect-Reference) })

$btnBuildBase.Add_Click({
    # For when there is no base package yet: build one from the game dump, so the
    # base and the update can be shipped as the matched pair the console requires.
    $game = $txtGame.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($game)) {
        Show-Error 'Set the game folder first - a base package is built from the game files.'
        return
    }
    if (-not (Test-Path -LiteralPath $game -PathType Container)) {
        Show-Error "Game folder not found: $game"; return
    }
    $toolkit = Find-ToolkitRoot
    if (-not $toolkit) {
        Show-Error 'Could not locate the publishing toolkit. Set PS5_FPKG_TOOLKIT.'; return
    }
    $fromFolder = Join-Path $toolkit 'build-from-folder.ps1'
    if (-not (Test-Path -LiteralPath $fromFolder -PathType Leaf)) {
        Show-Error "Missing $fromFolder"; return
    }
    $savePkg.FileName = 'base.pkg'
    if ($savePkg.ShowDialog($form) -ne 'OK') { return }
    $target = $savePkg.FileName
    Append-Log "Building base package from $game"
    Append-Log 'This writes the full game package and takes a few minutes.'
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fromFolder,
                   '-SourceFolder', $game, '-OutputPackage', $target,
                   '-CompressionLevel', [string]$cmbCompression.SelectedItem, '-Force')
    $result = Invoke-Tool -FilePath (Get-Command powershell.exe).Source `
        -Arguments $arguments -Activity 'Building base package...'
    if ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $target -PathType Leaf)) {
        $txtReference.Text = $target
        Append-Log ''
        Append-Log 'Base package built and selected as the reference.'
        Append-Log 'Install THIS package on the console; the update only applies to this exact build.'
        [void](Inspect-Reference)
    } else {
        Append-Log 'Base package build failed.'
    }
})

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
        if ($code -eq 0) {
            $status.Text = 'Update built successfully'
            Append-Log ''
            Append-Log 'Done. Copy the update to the console and install it over the base game.'
        } else {
            $status.Text = "Build failed (exit $code)"
        }
    }
})

$btnBuild.Add_Click({
    $game = $txtGame.Text.Trim()
    $backport = $txtBackport.Text.Trim()
    $reference = $txtReference.Text.Trim()
    $output = $txtOutput.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($game) -or [string]::IsNullOrWhiteSpace($backport) -or
        [string]::IsNullOrWhiteSpace($reference) -or [string]::IsNullOrWhiteSpace($output)) {
        Show-Error 'Fill in the game folder, backport folder, base PKG and output path.'
        return
    }
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $builderScript,
        '-GameFolder', $game, '-BackportFolder', $backport,
        '-ReferencePackage', $reference, '-OutputPackage', $output,
        '-CompressionLevel', [string]$cmbCompression.SelectedItem, '-Force')
    if (-not [string]::IsNullOrWhiteSpace($txtVersion.Text)) {
        $arguments += @('-ContentVersion', $txtVersion.Text.Trim())
    }
    if ($chkKeepWork.Checked) { $arguments += '-KeepWork' }

    $log.Clear()
    Append-Log "Building update from $backport"
    Append-Log ''
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe).Source
    $psi.Arguments = (($arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $script:process = [System.Diagnostics.Process]::Start($psi)
    $script:lastOutput = $output
    $script:stdoutEnded = $false
    $script:stderrEnded = $false
    $script:stdoutTask = $script:process.StandardOutput.ReadLineAsync()
    $script:stderrTask = $script:process.StandardError.ReadLineAsync()
    Set-Busy $true
    $status.Text = 'Building...'
    $timer.Start()
})

$btnCancel.Add_Click({
    if ($null -ne $script:process -and -not $script:process.HasExited) {
        try { $script:process.Kill() } catch { }
        Append-Log 'Cancelled.'
    }
})

$form.Add_FormClosing({
    if ($null -ne $script:process -and -not $script:process.HasExited) {
        try { $script:process.Kill() } catch { }
    }
})

if ($ValidateOnly) {
    Write-Host 'backport-gui.ps1 loaded and constructed successfully.'
    $form.Dispose()
    exit 0
}

[void][System.Windows.Forms.Application]::Run($form)
