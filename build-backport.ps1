#requires -Version 5.1
<#
.SYNOPSIS
Build a backport update package: a small delta that installs on top of an
already-installed base game instead of replacing it.

.DESCRIPTION
Overlays a backport file set onto a copy of the game tree, then builds a compact
patch against the exact base package the console installed from.  The result
carries only the changed files; every unchanged file is referenced from the base
image.

The base package is this tool's own artefact: -BasePackage names where it lives, and
it is built from -GameFolder when missing and reused when present.  So a backport
built in a later run references the very package this tool produced, which is the one
the console has to install.  -BackportFolder is optional - a dump that already has the
backport merged in needs only the base package.

Three constraints are enforced here because each one costs an install attempt:

 * The reference package must be byte-identical to the one the console
   installed.  A delta records the reference digest (FIH header +0x30) and the
   console refuses a mismatch with CE-107891-6 / 0x80b21165 DigestErr.  Toolkit
   output is NOT reproducible, so rebuilding a "same" base produces a different
   digest - always reference the real file.
 * contentVersion must be strictly greater than the base's, or the publisher
   refuses outright.
 * sce_sys/about is a reserved node; a backport's own right.sprx cannot ship and
   is dropped with a warning.

.EXAMPLE
Build only the base package (a dump that already has the backport merged in):

.\build-backport.ps1 -GameFolder .\PPSA12345-app -BasePackage .\game.pkg

.EXAMPLE
Build the backport update later, against the base package built above:

.\build-backport.ps1 `
    -GameFolder .\PPSA12345-app `
    -BackportFolder '.\my backport files' `
    -BasePackage .\game.pkg `
    -OutputPackage .\game-backport.pkg
#>

[CmdletBinding()]
param(
    [string]$GameFolder,
    [string]$BackportFolder,
    [Parameter(Mandatory = $true)][string]$BasePackage,
    [string]$OutputPackage,
    [switch]$RebuildBase,
    [string]$ContentVersion,
    [ValidateRange(-4, 9)][int]$CompressionLevel = 7,
    [string]$WorkFolder,
    [string]$ToolkitRoot,
    [string]$Python = 'python',
    [switch]$KeepWork,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$here = [IO.Path]::GetFullPath($PSScriptRoot)

function Test-ToolkitRoot([string]$candidate) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $candidate 'scripts\create-gp5-from-folder.py') -PathType Leaf) -and
           (Test-Path -LiteralPath (Join-Path $candidate 'toolchain\prospero-pub-cmd.exe') -PathType Leaf)
}

function Find-ToolkitRoot([string]$explicit, [string]$scriptRoot) {
    # The plaintext publishing toolkit ships large SDK binaries and lives outside
    # this repo, so its location is discovered rather than assumed.
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($explicit)) { $candidates += $explicit }
    if (-not [string]::IsNullOrWhiteSpace($env:PS5_FPKG_TOOLKIT)) { $candidates += $env:PS5_FPKG_TOOLKIT }
    $candidates += $scriptRoot
    $candidates += (Join-Path $scriptRoot 'fpkg converter')
    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if (-not [string]::IsNullOrWhiteSpace($documents)) {
        $candidates += (Join-Path $documents 'PS5JB\fpkg converter')
    }
    foreach ($candidate in $candidates) {
        if (Test-ToolkitRoot $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }
    throw ("Could not locate the plaintext publishing toolkit (the folder holding " +
           "scripts\create-gp5-from-folder.py and toolchain\prospero-pub-cmd.exe). " +
           "Pass -ToolkitRoot or set PS5_FPKG_TOOLKIT. Tried: " + ($candidates -join '; '))
}

$toolkit = Find-ToolkitRoot $ToolkitRoot $here
$gp5Script = Join-Path $toolkit 'scripts\create-gp5-from-folder.py'
$publisher = Join-Path $toolkit 'toolchain\prospero-pub-cmd.exe'
# These two ship with this repo, so they sit next to this script.
$infoScript = Join-Path $here 'scripts\pkg-info.py'
$metricScript = Join-Path $here 'scripts\pkg-metric.py'

function Resolve-InputPath([string]$path) {
    # [IO.Path]::GetFullPath resolves against the process working directory, which
    # Set-Location does not change. Anchor relative paths to the PowerShell location
    # instead so they mean what the caller sees.
    if ([string]::IsNullOrWhiteSpace($path)) { return $path }
    if ([IO.Path]::IsPathRooted($path)) { return [IO.Path]::GetFullPath($path) }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $path))
}

function New-LinkedTree([string]$source, [string]$destination) {
    <#
        Mirror a tree using hard links instead of copying the bytes. The build only
        ever replaces whole files, so the links are read-only in practice - but every
        writer in this script must delete a link before writing, or it would write
        through the link into the caller's source tree.

        Hard links cannot cross volumes; the caller checks that first.
    #>
    $sourceRoot = $source.TrimEnd('\', '/')
    $linked = 0
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Get-ChildItem -LiteralPath $sourceRoot -Recurse -Directory | ForEach-Object {
        $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
        New-Item -ItemType Directory -Force -Path (Join-Path $destination $relative) | Out-Null
    }
    Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
        $target = Join-Path $destination $relative
        New-Item -ItemType HardLink -Path $target -Value $_.FullName -ErrorAction Stop | Out-Null
        $linked++
    }
    return $linked
}

function Set-BuildTreeFile {
    <#
        Replace a file in the build tree. Removes the existing entry first so a hard
        link is broken rather than written through into the source tree.
    #>
    param([string]$Path, [string]$FromFile, [string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    if ($PSBoundParameters.ContainsKey('FromFile')) {
        Copy-Item -LiteralPath $FromFile -Destination $Path -Force
    } else {
        [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
    }
}

function Write-Step([string]$message) { Write-Host "==> $message" }
function Write-Note([string]$message) { Write-Host "    $message" }
function Write-Warn([string]$message) { Write-Warning $message }

function Invoke-Json {
    param([string[]]$Arguments)
    $raw = & $Python @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "pkg-info failed: $($raw -join [Environment]::NewLine)"
    }
    # Strip any stray non-JSON leading output before parsing.
    $text = ($raw | Out-String)
    $start = $text.IndexOf('{')
    if ($start -lt 0) { throw "pkg-info produced no JSON: $text" }
    return $text.Substring($start) | ConvertFrom-Json
}

foreach ($required in @($gp5Script, $infoScript, $metricScript, $publisher)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Toolkit component missing: $required"
    }
}

$game = if ([string]::IsNullOrWhiteSpace($GameFolder)) { $null } else { Resolve-InputPath $GameFolder }
$backport = Resolve-InputPath $BackportFolder
$base = Resolve-InputPath $BasePackage
$output = Resolve-InputPath $OutputPackage

# The base package is this tool's own artefact, not something you go and find. It is
# built from the game folder when it is missing and reused when it is already there,
# so building the backport separately references the very package that was built
# here - which is what the console has to install.
$buildUpdate = -not [string]::IsNullOrWhiteSpace($BackportFolder)
$baseExists = (Test-Path -LiteralPath $base -PathType Leaf) -and -not $RebuildBase
$createBase = -not $baseExists

if ([IO.Path]::GetExtension($base) -ine '.pkg') {
    throw 'BasePackage must be a .pkg path.'
}
if ($createBase -and -not $game) {
    throw ("The base package does not exist yet, so it has to be built: -GameFolder is " +
           "required. (Pass an existing $base to reuse it instead.)")
}
if ($game -and -not (Test-Path -LiteralPath $game -PathType Container)) {
    throw "GameFolder does not exist or is not a directory: $game"
}
if ($buildUpdate -and -not (Test-Path -LiteralPath $backport -PathType Container)) {
    throw "BackportFolder does not exist or is not a directory: $backport"
}
if ($buildUpdate) {
    if ([string]::IsNullOrWhiteSpace($OutputPackage)) {
        throw '-OutputPackage is required when -BackportFolder is given (it is where the update goes).'
    }
    if ([IO.Path]::GetExtension($output) -ine '.pkg') {
        throw 'OutputPackage must be a .pkg path.'
    }
    if ($base -ieq $output) {
        throw 'BasePackage and OutputPackage must be different files.'
    }
    if ((Test-Path -LiteralPath $output) -and -not $Force) {
        throw "Output already exists: $output (use -Force to replace it)"
    }
} elseif (-not $createBase) {
    throw ("Nothing to do: the base package already exists and no -BackportFolder was " +
           "given. Pass -RebuildBase to rebuild it, or a backport folder to build an update.")
}

# ------------------------------------------------------------- base package
if ($createBase) {
    $fromFolder = Join-Path $toolkit 'build-from-folder.ps1'
    if (-not (Test-Path -LiteralPath $fromFolder -PathType Leaf)) {
        throw "Building the base package needs the toolkit's build-from-folder.ps1: $fromFolder"
    }
    Write-Step "Building the base package from the game folder (no backport)"
    Write-Note "source : $game"
    Write-Note "output : $base"
    Write-Note 'This is a full game package and takes a while.'
    # Built from the untouched source folder. The backport is overlaid later, into a
    # work tree, so the base deliberately contains the unmodified game.
    $buildArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fromFolder,
                   '-SourceFolder', $game, '-OutputPackage', $base,
                   '-CompressionLevel', [string]$CompressionLevel)
    if ($Force -or $RebuildBase) { $buildArgs += '-Force' }
    & (Get-Command powershell.exe).Source @buildArgs 2>&1 | ForEach-Object { Write-Note $_ }
    if ($LASTEXITCODE -ne 0) { throw "Base package build failed with exit code $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath $base -PathType Leaf)) {
        throw "The base build reported success but produced nothing at $base"
    }
    Write-Note ("base package: {0:N0} bytes" -f (Get-Item -LiteralPath $base).Length)

    if (-not $buildUpdate) {
        Write-Host ''
        Write-Host "Created base package: $base"
        Write-Host 'No backport folder was given, so no update was built.'
        Write-Host 'Run again with a backport folder to build the update against this package.'
        exit 0
    }
} else {
    Write-Step "Using the existing base package"
    Write-Note $base
    Write-Note ("{0:N0} bytes" -f (Get-Item -LiteralPath $base).Length)
}

$reference = $base

# ---------------------------------------------------------------- reference
Write-Step "Inspecting reference package"
$refInfo = Invoke-Json @($infoScript, $reference, '--next-version')
if ($refInfo.kind -ne 'ps5') {
    throw ("The base package is not a PS5 package (kind=$($refInfo.kind), magic bytes " +
           "differ). A delta must reference a full FIH package, not another delta.")
}
if (-not $refInfo.param) {
    throw 'The base package has no readable param.json; it may be a retail (encrypted) package.'
}
$baseVersion = $refInfo.param.contentVersion
Write-Note "title      : $($refInfo.param.titleName) [$($refInfo.param.titleId)]"
Write-Note "contentId  : $($refInfo.param.contentId)"
Write-Note "version    : $baseVersion"
Write-Note "digest     : $($refInfo.digest)"
Write-Note 'The console must have installed THIS package. A delta against any other'
Write-Note 'build of the same game fails with CE-107891-6 (0x80b21165 DigestErr).'

if ([string]::IsNullOrWhiteSpace($ContentVersion)) {
    $ContentVersion = $refInfo.nextContentVersion
    if ([string]::IsNullOrWhiteSpace($ContentVersion)) {
        throw "Could not derive a contentVersion from '$baseVersion'; pass -ContentVersion."
    }
    Write-Note "new version: $ContentVersion (auto)"
} else {
    Write-Note "new version: $ContentVersion"
}
if ([string]::Compare($ContentVersion, $baseVersion, $true) -le 0) {
    throw ("ContentVersion '$ContentVersion' must be strictly greater than the base " +
           "'$baseVersion'; the publisher refuses otherwise.")
}

# --------------------------------------------------------------- work folder
if ([string]::IsNullOrWhiteSpace($WorkFolder)) {
    $WorkFolder = Join-Path ([IO.Path]::GetTempPath()) ("backport-" + [Guid]::NewGuid().ToString('N'))
}
$work = Resolve-InputPath $WorkFolder
$overlay = Join-Path $work 'app'
if (Test-Path -LiteralPath $work) {
    if (-not $Force) { throw "Work folder already exists: $work (use -Force)" }
    Remove-Item -LiteralPath $work -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $work | Out-Null

$exitCode = 1
try {
    if ($game) {
        # Link rather than copy when possible: the build tree is only ever read from
        # and whole-file replaced, so duplicating a multi-GB dump buys nothing.
        $sameVolume = [IO.Path]::GetPathRoot($game) -ieq [IO.Path]::GetPathRoot($work)
        $linked = $false
        if ($sameVolume) {
            Write-Step "Linking game folder into work tree"
            Write-Note $overlay
            try {
                $count = New-LinkedTree $game $overlay
                Write-Note "$count file(s) hard-linked; no data copied."
                $linked = $true
            } catch {
                Write-Warn "Hard-linking failed ($($_.Exception.Message)); falling back to a copy."
                Remove-Item -LiteralPath $overlay -Recurse -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Note "Game folder and work folder are on different volumes; copying."
            Write-Note "Use -WorkFolder on the same drive as the game to link instead."
        }
        if (-not $linked) {
            Write-Step "Copying game folder to work tree"
            Write-Note $overlay
            $robo = Start-Process -FilePath 'robocopy.exe' `
                -ArgumentList @($game, $overlay, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/MT:16') `
                -NoNewWindow -Wait -PassThru
            # robocopy uses a bitmask: < 8 means success, >= 8 is a real failure.
            if ($robo.ExitCode -ge 8) { throw "robocopy failed with exit code $($robo.ExitCode)" }
        }
    } else {
        # No game folder supplied: the reference package already contains every file
        # the GP5 must describe, so unpack it and use that as the build tree.
        Write-Step "Extracting base package to work tree (no game folder supplied)"
        Write-Note $overlay
        New-Item -ItemType Directory -Force -Path $overlay | Out-Null
        & $publisher img_extract --passcode ('0' * 32) --no_progress_bar $reference $overlay 2>&1 |
            ForEach-Object { Write-Note $_ }
        if ($LASTEXITCODE -ne 0) { throw "img_extract failed with exit code $LASTEXITCODE" }
    }

    # The builder regenerates the PlayGo language payloads, so a copy carried in
    # from an extracted package collides with the generated one and the publisher
    # rejects the GP5 with: invalid attribute value dst_path="playgo-languages/...".
    # Removing links only unlinks them; the source tree keeps its own entries.
    $languages = Join-Path $overlay 'playgo-languages'
    if (Test-Path -LiteralPath $languages) {
        Remove-Item -LiteralPath $languages -Recurse -Force
        Write-Note 'Removed playgo-languages/ (regenerated by the builder)'
    }

    $keystone = Join-Path $overlay 'sce_sys\keystone'
    if (-not (Test-Path -LiteralPath $keystone -PathType Leaf) -or
        (Get-Item -LiteralPath $keystone).Length -ne 96) {
        throw "This toolchain requires a 96-byte sce_sys\keystone in the build tree"
    }

    Write-Step "Overlaying backport files"
    # Backport files always sit at the game root, so the folder handed in must be the
    # one whose children are eboot.bin / sce_module / fakelib. Releases are often
    # wrapped in an outer folder; overlaying that would bury everything one level
    # deep inside the game root, and every file would silently land in the wrong place.
    $backportRoot = $backport
    while ($true) {
        $entries = @(Get-ChildItem -LiteralPath $backportRoot -Force)
        $files = @($entries | Where-Object { -not $_.PSIsContainer })
        $dirs = @($entries | Where-Object { $_.PSIsContainer })
        if ($files.Count -eq 0 -and $dirs.Count -eq 1) {
            $backportRoot = $dirs[0].FullName
            Write-Note "Descended into wrapper folder: $($dirs[0].Name)"
            continue
        }
        break
    }

    $skippedAbout = @()
    $applied = @()
    $newPaths = @()
    Get-ChildItem -LiteralPath $backportRoot -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($backportRoot.Length).TrimStart('\', '/')
        # .esbak files are the applier tool's own backups of what it replaced.
        if ($_.Extension -ieq '.esbak') { return }
        # The publisher rejects a GP5 containing sce_sys/about: reserved node.
        if ($relative -replace '/', '\' -like 'sce_sys\about\*') {
            $skippedAbout += $relative
            return
        }
        $target = Join-Path $overlay $relative
        $replaces = Test-Path -LiteralPath $target -PathType Leaf
        Set-BuildTreeFile -Path $target -FromFile $_.FullName
        $applied += $relative
        if (-not $replaces) { $newPaths += $relative }
        Write-Note (("+ {0}" -f $relative) + $(if ($replaces) { "" } else { "   (new)" }))
    }
    if ($applied.Count -eq 0) { throw "No backport files found under $backportRoot" }
    Write-Note ("{0} file(s): {1} replacing game files, {2} new" -f
                $applied.Count, ($applied.Count - $newPaths.Count), $newPaths.Count)
    # A backport replaces game binaries. If nothing matched, the tree is almost
    # certainly rooted at the wrong level and the files would land where nothing
    # loads them.
    if ($newPaths.Count -eq $applied.Count) {
        Write-Warn ("None of the backport files replace anything in the game. The backport " +
                    "folder is probably rooted at the wrong level - its contents must sit at " +
                    "the game root (eboot.bin, sce_module/, fakelib/ ...).")
    }
    foreach ($item in $skippedAbout) {
        Write-Warn "Not shipped (sce_sys/about is a reserved node the SDK regenerates): $item"
    }

    Write-Step "Setting contentVersion to $ContentVersion"
    $paramPath = Join-Path $overlay 'sce_sys\param.json'
    if (-not (Test-Path -LiteralPath $paramPath -PathType Leaf)) {
        throw "Missing $paramPath"
    }
    $paramText = Get-Content -LiteralPath $paramPath -Raw -Encoding UTF8
    $patched = [regex]::Replace(
        $paramText,
        '("contentVersion"\s*:\s*")[^"]*(")',
        { param($m) $m.Groups[1].Value + $ContentVersion + $m.Groups[2].Value },
        1)
    if ($patched -eq $paramText) {
        throw "Could not set contentVersion in $paramPath"
    }
    Set-BuildTreeFile -Path $paramPath -Content $patched

    Write-Step "Generating GP5"
    $gp5 = Join-Path $work 'project.gp5'
    & $Python $gp5Script $overlay $gp5 `
        --passcode ('0' * 32) --absolute-paths --keep-keystone 2>&1 |
        ForEach-Object { Write-Note $_ }
    if ($LASTEXITCODE -ne 0) { throw "GP5 creation failed with exit code $LASTEXITCODE" }

    Write-Step "Building delta against reference (compression $CompressionLevel)"
    $partial = Join-Path $work 'update.partial.pkg'
    & $publisher img_create --oformat nwonly --compression_level $CompressionLevel `
        --ref_pkg_path $reference $gp5 $partial 2>&1 |
        ForEach-Object { Write-Note $_ }
    if ($LASTEXITCODE -ne 0) { throw "img_create failed with exit code $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath $partial -PathType Leaf)) {
        throw "Publisher did not produce $partial"
    }

    $outputDirectory = Split-Path -Parent $output
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    }
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
    Move-Item -LiteralPath $partial -Destination $output

    $metric = "$partial.naps_metric.json"
    $finalMetric = "$output.naps_metric.json"
    if (Test-Path -LiteralPath $metric) {
        if (Test-Path -LiteralPath $finalMetric) { Remove-Item -LiteralPath $finalMetric -Force }
        Move-Item -LiteralPath $metric -Destination $finalMetric
    }

    Write-Step "Verifying the delta references the base"
    $check = Invoke-Json @($infoScript, $output, '--no-param', '--contains-digest', $refInfo.digest)
    Write-Note "container  : $($check.magic -replace '[^\x20-\x7e]','?') ($($check.kind))"
    Write-Note ("size       : {0:N0} bytes" -f $check.size)
    Write-Note "references base digest: $($check.digestOccurrences) occurrence(s)"
    if ($check.kind -ne 'ps5-delta') {
        Write-Warn "Expected a delta container; got '$($check.kind)'. This may install as a full app and replace the title."
    }
    if ($check.digestOccurrences -lt 1) {
        throw ('The built package does not reference the base digest. It would fail on ' +
               'console with CE-107891-6. Check that the base package is the installed image.')
    }

    if (Test-Path -LiteralPath $finalMetric) {
        Write-Step "Files carried by this update"
        & $Python $metricScript $finalMetric 2>&1 | ForEach-Object { Write-Note $_ }
    }

    Write-Host ''
    if ($createBase) {
        Write-Host "Created base package:   $base"
        Write-Host "Created update package: $output"
        Write-Host ''
        Write-Host 'Install the base package on the console, then the update over it.'
        Write-Host 'They are a matched pair: the update applies only to this base build.'
    } else {
        Write-Host "Created update package: $output"
    }
    $exitCode = 0
}
finally {
    if ($KeepWork) {
        Write-Note "Work folder retained: $work"
    } elseif (Test-Path -LiteralPath $work) {
        # The publisher also drops a multi-GB .remastered.pkg companion in here;
        # removing the work tree discards it along with the GP5 and overlay copy.
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
