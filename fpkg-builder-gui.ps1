#requires -Version 5.1
<#
    fPKG Builder - Windows GUI

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

# The publisher draws its own progress bar with carriage returns and never a
# newline, so none of it survives the pipelines between it and this window - the
# log stands still for the twenty minutes the step runs. How much of the source it
# has read is the one measure of that step visible from outside the process, and
# unlike the size of the package it is writing, it does not depend on how well the
# game happens to compress.
Add-Type -Namespace FpkgBuilder -Name Io -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
private struct IoCounters {
    public ulong ReadOperationCount;
    public ulong WriteOperationCount;
    public ulong OtherOperationCount;
    public ulong ReadTransferCount;
    public ulong WriteTransferCount;
    public ulong OtherTransferCount;
}

[DllImport("kernel32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
private static extern bool GetProcessIoCounters(IntPtr handle, out IoCounters counters);

public static long BytesRead(IntPtr handle) {
    IoCounters counters;
    if (!GetProcessIoCounters(handle, out counters)) { return 0L; }
    return (long)counters.ReadTransferCount;
}
'@

# Everything the GUI launches ships beside it.
$repoRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$builderScript = Join-Path $repoRoot 'build-fpkg.ps1'
$infoScript = Join-Path $repoRoot 'scripts\pkg-info.py'
. (Join-Path $repoRoot 'scripts\find-toolkit.ps1')

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
$script:phase = $null
$script:buildStarted = $null
$script:sampledAt = [DateTime]::MinValue
$script:gameBytes = [long]0
$script:baseStart = 0
$script:baseSpan = 100
$script:updateStart = 0
$script:updateSpan = 100
$script:activeLog = $null
$script:destination = $null

function Show-Error([string]$message) {
    [void][System.Windows.Forms.MessageBox]::Show(
        $form, $message, 'fPKG Builder',
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
$form.Text = 'fPKG Builder'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1080, 800)
$form.MinimumSize = New-Object System.Drawing.Size(880, 620)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 1
$root.RowCount = 4
$root.Padding = New-Object System.Windows.Forms.Padding(12)
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 26)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$form.Controls.Add($root)

# Each tab owns its inputs, its buttons and its log; the progress bar, Cancel and
# the status line below them are shared, because only one job runs at a time.
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
[void]$root.Controls.Add($tabs, 0, 0)

function New-TabPage([string]$text, [int]$rowCount) {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $text
    $page.UseVisualStyleBackColor = $true
    $page.Padding = New-Object System.Windows.Forms.Padding(10)
    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock = 'Fill'
    $grid.ColumnCount = 1
    $grid.RowCount = $rowCount
    for ($row = 0; $row -lt ($rowCount - 1); $row++) {
        [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    }
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$page.Controls.Add($grid)
    [void]$tabs.TabPages.Add($page)
    return $grid
}

function New-LogBox {
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = 'Both'
    $box.WordWrap = $false
    $box.Dock = 'Fill'
    $box.Font = New-Object System.Drawing.Font('Consolas', 9)
    $box.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    return $box
}

$buildGrid = New-TabPage 'Build' 4
$extractGrid = New-TabPage 'Extract' 3

$paths = New-Object System.Windows.Forms.GroupBox
$paths.Text = 'Inputs'
$paths.Dock = 'Fill'
$paths.AutoSize = $true
$paths.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 10)
[void]$buildGrid.Controls.Add($paths, 0, 0)

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
    param([int]$Row, [string]$LabelText, $Grid = $null)
    if ($null -eq $Grid) { $Grid = $pathGrid }
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

    [void]$Grid.Controls.Add($label, 0, $Row)
    [void]$Grid.Controls.Add($text, 1, $Row)
    [void]$Grid.Controls.Add($browse, 2, $Row)
    return [PSCustomObject]@{ TextBox = $text; BrowseButton = $browse }
}

$gameRow = Add-PathRow -Row 0 -LabelText 'Game folder (dump):'
$backportRow = Add-PathRow -Row 1 -LabelText 'Backport files (optional):'
$referenceRow = Add-PathRow -Row 2 -LabelText 'Output folder:'
$workRow = Add-PathRow -Row 3 -LabelText 'Work folder (optional):'
$outputRow = Add-PathRow -Row 4 -LabelText 'Name (optional):'

$txtGame = $gameRow.TextBox
$txtBackport = $backportRow.TextBox
$txtOutDir = $referenceRow.TextBox
$txtWork = $workRow.TextBox
$txtName = $outputRow.TextBox

$gameHint = New-Object System.Windows.Forms.Label
$gameHint.Text = 'Both packages land in the output folder as <name>.pkg and <name>-backport.pkg. Name defaults to the title id. Leave the backport blank to build only the base.' + [Environment]::NewLine + 'The work folder holds a copy of the game unless it is on the same drive as the dump, in which case it is linked and costs nothing. Blank uses your temp folder.'
$gameHint.AutoSize = $true
$gameHint.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 6)
$pathGrid.RowCount = 6
[void]$pathGrid.Controls.Add($gameHint, 1, 5)
$pathGrid.SetColumnSpan($gameHint, 2)

# ------------------------------------------------------------------ options
$options = New-Object System.Windows.Forms.GroupBox
$options.Text = 'Options'
$options.Dock = 'Fill'
$options.AutoSize = $true
$options.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 10)
[void]$buildGrid.Controls.Add($options, 0, 1)

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

# ------------------------------------------------------------- build actions
$buildActions = New-Object System.Windows.Forms.FlowLayoutPanel
$buildActions.Dock = 'Fill'
$buildActions.AutoSize = $true
$buildActions.FlowDirection = 'LeftToRight'
$buildActions.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
[void]$buildGrid.Controls.Add($buildActions, 0, 2)

$btnBuild = New-Object System.Windows.Forms.Button
$btnBuild.Text = 'Build'
$btnBuild.AutoSize = $true
$btnBuild.MinimumSize = New-Object System.Drawing.Size(150, 32)
[void]$buildActions.Controls.Add($btnBuild)

$btnInspect = New-Object System.Windows.Forms.Button
$btnInspect.Text = 'Inspect base PKG'
$btnInspect.AutoSize = $true
$btnInspect.MinimumSize = New-Object System.Drawing.Size(150, 32)
$btnInspect.Margin = New-Object System.Windows.Forms.Padding(8, 3, 3, 3)
[void]$buildActions.Controls.Add($btnInspect)

$btnOpenOutput = New-Object System.Windows.Forms.Button
$btnOpenOutput.Text = 'Open output folder'
$btnOpenOutput.AutoSize = $true
$btnOpenOutput.MinimumSize = New-Object System.Drawing.Size(150, 32)
$btnOpenOutput.Margin = New-Object System.Windows.Forms.Padding(8, 3, 3, 3)
[void]$buildActions.Controls.Add($btnOpenOutput)

$log = New-LogBox
[void]$buildGrid.Controls.Add($log, 0, 3)

# ------------------------------------------------------------------ extract
$extractInputs = New-Object System.Windows.Forms.GroupBox
$extractInputs.Text = 'Unpack a package'
$extractInputs.Dock = 'Fill'
$extractInputs.AutoSize = $true
$extractInputs.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 10)
[void]$extractGrid.Controls.Add($extractInputs, 0, 0)

$extractPathGrid = New-Object System.Windows.Forms.TableLayoutPanel
$extractPathGrid.Dock = 'Fill'
$extractPathGrid.AutoSize = $true
$extractPathGrid.ColumnCount = 3
$extractPathGrid.RowCount = 3
[void]$extractPathGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 215)))
[void]$extractPathGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$extractPathGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$extractInputs.Controls.Add($extractPathGrid)

$packageRow = Add-PathRow -Row 0 -LabelText 'Package (.pkg):' -Grid $extractPathGrid
$destinationRow = Add-PathRow -Row 1 -LabelText 'Unpack into:' -Grid $extractPathGrid
$txtPackage = $packageRow.TextBox
$txtDestination = $destinationRow.TextBox

$extractHint = New-Object System.Windows.Forms.Label
$extractHint.Text = 'Unpacks the package into the destination folder. Packages this tool builds open here, base and patch alike; a retail package needs a passcode this tool does not have.'
$extractHint.AutoSize = $true
$extractHint.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 6)
[void]$extractPathGrid.Controls.Add($extractHint, 1, 2)
$extractPathGrid.SetColumnSpan($extractHint, 2)

$extractActions = New-Object System.Windows.Forms.FlowLayoutPanel
$extractActions.Dock = 'Fill'
$extractActions.AutoSize = $true
$extractActions.FlowDirection = 'LeftToRight'
$extractActions.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
[void]$extractGrid.Controls.Add($extractActions, 0, 1)

$btnExtract = New-Object System.Windows.Forms.Button
$btnExtract.Text = 'Extract'
$btnExtract.AutoSize = $true
$btnExtract.MinimumSize = New-Object System.Drawing.Size(150, 32)
[void]$extractActions.Controls.Add($btnExtract)

$btnInspectPackage = New-Object System.Windows.Forms.Button
$btnInspectPackage.Text = 'Inspect package'
$btnInspectPackage.AutoSize = $true
$btnInspectPackage.MinimumSize = New-Object System.Drawing.Size(150, 32)
$btnInspectPackage.Margin = New-Object System.Windows.Forms.Padding(8, 3, 3, 3)
[void]$extractActions.Controls.Add($btnInspectPackage)

$btnOpenDestination = New-Object System.Windows.Forms.Button
$btnOpenDestination.Text = 'Open destination'
$btnOpenDestination.AutoSize = $true
$btnOpenDestination.MinimumSize = New-Object System.Drawing.Size(150, 32)
$btnOpenDestination.Margin = New-Object System.Windows.Forms.Padding(8, 3, 3, 3)
[void]$extractActions.Controls.Add($btnOpenDestination)

$extractLog = New-LogBox
[void]$extractGrid.Controls.Add($extractLog, 0, 2)

# ------------------------------------------------------------------ shared
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Dock = 'Fill'
$progressBar.Style = 'Continuous'
$progressBar.Minimum = 0
# Tenths of a percent, so the bar still creeps on a step measured in gigabytes.
$progressBar.Maximum = 1000
$progressBar.MarqueeAnimationSpeed = 30
$progressBar.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
[void]$root.Controls.Add($progressBar, 0, 1)

$actions = New-Object System.Windows.Forms.FlowLayoutPanel
$actions.Dock = 'Fill'
$actions.AutoSize = $true
$actions.FlowDirection = 'LeftToRight'
[void]$root.Controls.Add($actions, 0, 2)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'
$btnCancel.AutoSize = $true
$btnCancel.Enabled = $false
$btnCancel.MinimumSize = New-Object System.Drawing.Size(110, 32)
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
[void]$root.Controls.Add($footer, 0, 3)

# ------------------------------------------------------------------ helpers
function Append-Log([string]$line) {
    if ($null -eq $line) { return }
    # Each tab keeps its own transcript, so output follows the job that produced it
    # rather than whichever tab happens to be in front.
    $target = if ($null -eq $script:activeLog) { $log } else { $script:activeLog }
    $target.AppendText(($line -replace "`r`n", "`n" -replace "`n", [Environment]::NewLine))
    $target.AppendText([Environment]::NewLine)
}

function Format-Bytes([double]$bytes) {
    if ($bytes -ge 1GB) { return '{0:N1} GB' -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return '{0:N0} MB' -f ($bytes / 1MB) }
    return '{0:N0} KB' -f ($bytes / 1KB)
}

function Format-Span([TimeSpan]$span) {
    if ($span.TotalHours -ge 1) { return '{0}h {1:00}m' -f [int]$span.TotalHours, $span.Minutes }
    return '{0}m {1:00}s' -f [int]$span.TotalMinutes, $span.Seconds
}

function Measure-FolderBytes([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return [long]0 }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return [long]0 }
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [long]0 }
    return [long]$sum
}

function Get-FileBytes([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return [long]0 }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [long]0 }
    return [long](Get-Item -LiteralPath $path).Length
}

function Get-PublisherBytesRead {
    <#
        Bytes read so far by the publisher processes this build started. Returns -1
        when none is running, which is how the caller tells "between steps" apart
        from "just started and has read nothing yet".
    #>
    if ($null -eq $script:buildStarted) { return [long]-1 }
    $total = [long]0
    $running = $false
    foreach ($proc in @(Get-Process -Name 'prospero-pub-cmd' -ErrorAction SilentlyContinue)) {
        try {
            if ($proc.StartTime -lt $script:buildStarted) { continue }
            $total += [FpkgBuilder.Io]::BytesRead($proc.Handle)
            $running = $true
        } catch {
            continue
        }
    }
    if (-not $running) { return [long]-1 }
    return $total
}

function Set-Step {
    <#
        Total and Span are given only for the steps whose work can be measured; the
        rest run the bar as a marquee, which is all their duration is known to.
    #>
    param([string]$Label, [long]$Total = 0, [int]$Start = 0, [int]$Span = 0)
    $script:phase = @{
        Label = $Label; Total = $Total; Start = $Start; Span = $Span; Since = Get-Date
    }
    Update-Progress
}

function Update-Progress {
    if ($null -eq $script:phase) { return }
    $phase = $script:phase
    $read = if ($phase.Total -gt 0 -and $phase.Span -gt 0) { Get-PublisherBytesRead } else { [long]-1 }
    $elapsed = (Get-Date) - $phase.Since
    if ($read -lt 0) {
        if ($progressBar.Style -ne 'Marquee') { $progressBar.Style = 'Marquee' }
        $status.Text = '{0} - {1} elapsed' -f $phase.Label, (Format-Span $elapsed)
        return
    }
    if ($progressBar.Style -ne 'Continuous') { $progressBar.Style = 'Continuous' }
    # Held short of the end of the band: the step finishing is what moves it there,
    # since the total is an estimate of what the publisher will read, not a promise.
    $fraction = [Math]::Min(0.99, $read / [double]$phase.Total)
    $value = [int](($phase.Start + ($fraction * $phase.Span)) * 10)
    $progressBar.Value = [Math]::Max($progressBar.Minimum, [Math]::Min($progressBar.Maximum, $value))
    $text = '{0} - read {1} of {2} ({3}%), {4} elapsed' -f $phase.Label,
        (Format-Bytes $read), (Format-Bytes $phase.Total),
        [int]($fraction * 100), (Format-Span $elapsed)
    if ($fraction -ge 0.02 -and $elapsed.TotalSeconds -ge 20) {
        $left = [TimeSpan]::FromSeconds($elapsed.TotalSeconds * (1 - $fraction) / $fraction)
        $text += ', about {0} left' -f (Format-Span $left)
    }
    $status.Text = $text
}

function Watch-Step([string]$line) {
    if ($line -notlike '==> *') { return }
    if ($line -like '==> Building the base package*') {
        Set-Step -Label 'Building base package' -Total $script:gameBytes `
                 -Start $script:baseStart -Span $script:baseSpan
    } elseif ($line -like '==> Building delta against reference*') {
        # This step reads the whole build tree and the package it is diffing against.
        $reference = Get-FileBytes (Get-BasePath)
        $total = if ($script:gameBytes -gt 0) { $script:gameBytes + $reference } else { $reference * 2 }
        Set-Step -Label 'Building update package' -Total $total `
                 -Start $script:updateStart -Span $script:updateSpan
    } else {
        Set-Step -Label $line.Substring(4).Trim()
    }
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
    $btnExtract.Enabled = -not $busy
    $btnInspectPackage.Enabled = -not $busy
    $btnCancel.Enabled = $busy
}

function Open-Folder([string]$dir) {
    $dir = $dir.Trim()
    if ([string]::IsNullOrWhiteSpace($dir)) {
        Show-Error 'Set the folder first.'
        return
    }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Show-Error "There is no folder at $dir yet."
        return
    }
    try {
        # The folder goes in as the target rather than an argument, so a path with a
        # space in it needs no quoting and cannot be split into two.
        Start-Process -FilePath $dir -ErrorAction Stop | Out-Null
    } catch {
        Show-Error "Could not open $dir - $($_.Exception.Message)"
    }
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

function Read-PackageInfo([string]$package) {
    <# pkg-info without the log noise, for decisions rather than for reading. #>
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-PythonPath)
        $psi.Arguments = ((@($infoScript, $package) | ForEach-Object { Quote-Argument $_ }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $text = $proc.StandardOutput.ReadToEnd()
        [void]$proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { return $null }
        return Read-Json $text
    } catch {
        return $null
    }
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
    $script:activeLog = $log
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
$workRow.BrowseButton.Add_Click({
    if ($folderDialog.ShowDialog($form) -eq 'OK') { $txtWork.Text = $folderDialog.SelectedPath }
})
$outputRow.BrowseButton.Visible = $false

$packageRow.BrowseButton.Add_Click({
    if ($openPkg.ShowDialog($form) -eq 'OK') { $txtPackage.Text = $openPkg.FileName }
})
$destinationRow.BrowseButton.Add_Click({
    if ($folderDialog.ShowDialog($form) -eq 'OK') { $txtDestination.Text = $folderDialog.SelectedPath }
})

$btnInspect.Add_Click({ [void](Inspect-Reference) })
$btnOpenOutput.Add_Click({ Open-Folder $txtOutDir.Text })
$btnOpenDestination.Add_Click({ Open-Folder $txtDestination.Text })

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
                Watch-Step $line
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
    $now = Get-Date
    if (($now - $script:sampledAt).TotalMilliseconds -ge 1000) {
        $script:sampledAt = $now
        Update-Progress
    }
    if ($script:process.HasExited -and $script:stdoutEnded -and $script:stderrEnded) {
        $timer.Stop()
        $code = $script:process.ExitCode
        $script:process = $null
        $script:phase = $null
        Set-Busy $false
        # A failed build leaves the bar where it stopped; that is where to look.
        $progressBar.Style = 'Continuous'
        if ($script:cancelled) {
            $progressBar.Value = $progressBar.Minimum
        } elseif ($code -eq 0) {
            $progressBar.Value = $progressBar.Maximum
        }
        $extracting = $script:operation -eq 'Extract'
        if (-not $extracting -and ($script:cancelled -or $code -ne 0)) { Remove-WorkFolder }
        if ($script:cancelled) {
            $status.Text = 'Cancelled'
            Append-Log 'Cancelled.'
            # A half-written tree is not a package that was unpacked; say so rather
            # than leave it looking finished.
            if ($extracting -and $script:destination) {
                Append-Log "Part of the package was already written to $script:destination."
            }
        } elseif ($code -eq 0) {
            if ($extracting) {
                $status.Text = 'Package extracted'
                Append-Log ''
                Append-Log "Done. The package contents are in $script:destination."
            } else {
                $status.Text = 'Update built successfully'
                Append-Log ''
                Append-Log 'Done. Copy the update to the console and install it over the base game.'
            }
        } else {
            $status.Text = if ($extracting) { "Extract failed (exit $code)" } else { "Build failed (exit $code)" }
        }
    }
})

function Start-Job-Process {
    <# Launch a console job and hand it to the timer that drains its output. #>
    param([string]$FilePath, [string[]]$Arguments, [string]$Operation, [string]$Label,
          [long]$Total = 0)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $script:operation = $Operation
    $script:cancelled = $false
    $script:buildStarted = Get-Date
    $script:sampledAt = [DateTime]::MinValue
    $script:phase = $null
    $progressBar.Style = 'Continuous'
    $progressBar.Value = $progressBar.Minimum
    $script:process = [System.Diagnostics.Process]::Start($psi)
    $script:stdoutEnded = $false
    $script:stderrEnded = $false
    $script:stdoutTask = $script:process.StandardOutput.ReadLineAsync()
    $script:stderrTask = $script:process.StandardError.ReadLineAsync()
    Set-Busy $true
    if ($Total -gt 0) {
        Set-Step -Label $Label -Total $Total -Start 0 -Span 100
    } else {
        Set-Step -Label $Label
    }
    $timer.Start()
}

function Start-Extract {
    $package = $txtPackage.Text.Trim()
    $destination = $txtDestination.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($package)) {
        Show-Error 'Choose the package to unpack.'
        return
    }
    if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
        Show-Error "There is no package at $package"
        return
    }
    if ([string]::IsNullOrWhiteSpace($destination)) {
        Show-Error 'Choose the folder to unpack into.'
        return
    }
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        Show-Error "The destination is a file, not a folder: $destination"
        return
    }
    if ((Test-Path -LiteralPath $destination -PathType Container) -and
        (Get-ChildItem -LiteralPath $destination -Force | Select-Object -First 1)) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $form,
            "$destination is not empty. Unpacking mixes the package contents in with what is already there." +
            [Environment]::NewLine + [Environment]::NewLine + 'Carry on?',
            'fPKG Builder',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    try {
        $toolkit = Find-ToolkitRoot '' $repoRoot
    } catch {
        Show-Error $_.Exception.Message
        return
    }
    $publisher = Join-Path $toolkit 'toolchain\prospero-pub-cmd.exe'
    try {
        [void][IO.Directory]::CreateDirectory($destination)
    } catch {
        Show-Error "Could not create $destination - $($_.Exception.Message)"
        return
    }

    $script:activeLog = $extractLog
    $script:destination = $destination
    $extractLog.Clear()
    Append-Log "Unpacking $package"

    # A patch package is refused outright when a passcode is supplied ("Parsing patch
    # package with passcode is not supported"), and a base package opened without one
    # yields only its outer entries. The container kind decides which to use.
    $info = Read-PackageInfo $package
    if ($null -ne $info) {
        $title = if ($info.param -and $info.param.titleName) { $info.param.titleName } else { 'unknown title' }
        $titleId = if ($info.param -and $info.param.titleId) { $info.param.titleId } else { '?' }
        Append-Log ("{0} [{1}] - {2}" -f $title, $titleId, $info.kind)
    }
    $isPatch = ($null -ne $info) -and ($info.kind -eq 'ps5-delta')
    $passcodeArgs = if ($isPatch) { @('--no_passcode') } else { @('--passcode', ('0' * 32)) }
    if ($isPatch) {
        Append-Log 'A patch package holds only what it changes, so expect a handful of files rather than a game.'
    }
    Append-Log "into $destination"
    Append-Log ''

    # The publisher reads the package once, so its own read count measures the job.
    Start-Job-Process -FilePath $publisher -Operation 'Extract' -Label 'Extracting package' `
        -Total (Get-FileBytes $package) `
        -Arguments (@('img_extract') + $passcodeArgs + @('--no_progress_bar', $package, $destination))
}

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

    $status.Text = 'Measuring the input folders...'
    $form.Refresh()
    $script:gameBytes = Measure-FolderBytes $game
    # The two publisher runs are what the build spends its time on, so they get the
    # bar between them; a run that does only one of the two gets the whole of it.
    $script:baseStart = 0
    $script:baseSpan = if ($wantUpdate) { 70 } else { 100 }
    $script:updateStart = if ($baseExists) { 0 } else { 70 }
    $script:updateSpan = 100 - $script:updateStart

    # A named work folder is a place the user picked for having room; the build gets
    # its own subfolder there so cleaning up never touches anything else.
    $workRoot = $txtWork.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($workRoot)) { $workRoot = [IO.Path]::GetTempPath() }
    $script:workFolder = Join-Path $workRoot ("fpkg-builder-" + [Guid]::NewGuid().ToString('N'))
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

    $script:activeLog = $log
    $log.Clear()
    Append-Log $(if ($baseExists) { "Using the existing base package: $base" } else { "Building the base package from $game" })
    Append-Log $(if ($wantUpdate) { "Then the backport update from $backport" } else { 'No backport folder set - base package only.' })
    Append-Log ''

    $script:lastOutput = $dir
    Start-Job-Process -FilePath (Get-Command powershell.exe).Source -Arguments $arguments `
        -Operation 'Build' -Label 'Starting the build'
}

$btnBuild.Add_Click({ Start-Build })
$btnExtract.Add_Click({ Start-Extract })
$btnInspectPackage.Add_Click({
    $package = $txtPackage.Text.Trim()
    if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
        Show-Error 'Choose the package to inspect.'
        return
    }
    $script:activeLog = $extractLog
    [void](Invoke-Tool -FilePath (Get-PythonPath) -Arguments @($infoScript, $package) `
        -Activity 'Reading package...')
})

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
    Write-Host 'fpkg-builder-gui.ps1 loaded and constructed successfully.'
    $form.Dispose()
    exit 0
}

[void][System.Windows.Forms.Application]::Run($form)
