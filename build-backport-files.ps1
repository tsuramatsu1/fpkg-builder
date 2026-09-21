#requires -Version 5.1
<#
.SYNOPSIS
Create a backport file set from a game's decrypted binaries.

.DESCRIPTION
Runs the three stages of a backport against a copy of the decrypted tree and
writes a folder that build-backport-update.ps1 can package:

  1. SDK downgrade  - rewrite the SDK version fields so an older firmware accepts
                      the binaries. Never raises a version; a binary already built
                      against an older SDK is left alone.
  2. fakelib        - resolve every import against the target firmware and copy the
                      smallest closed set of libraries from a newer firmware that
                      covers what is missing.
  3. fake-sign      - wrap each patched ELF in a PS5 SELF container, which is what
                      shipped backports use.

Signing happens after the downgrade: signing wraps the ELF and the SDK fields live
in segment data that is copied through untouched.

The engine is the ps5-backport repo (scripts, import/export databases and the unp
firmware trees). It is large and not redistributable, so it lives outside this repo
and is discovered at run time.

.EXAMPLE
.\build-backport-files.ps1 -DecryptedFolder .\PPSA12345-app\decrypted `
    -OutputFolder .\wukong-backport -TargetFirmware 4.03 -SourceFirmware 10.01
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DecryptedFolder,
    [Parameter(Mandatory = $true)][string]$OutputFolder,
    [Parameter(Mandatory = $true)][string]$TargetFirmware,
    [string]$SourceFirmware,
    [int]$Sdk,
    [string]$BackportRepo,
    [string]$WorkFolder,
    [string]$Python = 'python',
    [switch]$NoFakelib,
    [switch]$KeepWork,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Resolve-InputPath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $path }
    if ([IO.Path]::IsPathRooted($path)) { return [IO.Path]::GetFullPath($path) }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $path))
}

function Write-Step([string]$message) { Write-Host "==> $message" }
function Write-Note([string]$message) { Write-Host "    $message" }

function Test-BackportRepo([string]$candidate) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }
    foreach ($needed in @('ps5_sdk_downgrade.py', 'make_fself_ps5.py',
                          'analyze_prx_compatibility.py', 'import_export_db')) {
        if (-not (Test-Path -LiteralPath (Join-Path $candidate $needed))) { return $false }
    }
    return $true
}

function Find-BackportRepo([string]$explicit) {
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($explicit)) { $candidates += $explicit }
    if (-not [string]::IsNullOrWhiteSpace($env:PS5_BACKPORT_REPO)) { $candidates += $env:PS5_BACKPORT_REPO }
    $candidates += (Join-Path (Split-Path -Parent $PSScriptRoot) 'ps5-backport')
    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if (-not [string]::IsNullOrWhiteSpace($documents)) {
        $candidates += (Join-Path $documents 'Repos\ps5-backport')
    }
    foreach ($candidate in $candidates) {
        if (Test-BackportRepo $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }
    throw ("Could not locate the ps5-backport repo (needs ps5_sdk_downgrade.py, " +
           "make_fself_ps5.py, analyze_prx_compatibility.py and import_export_db). " +
           "Pass -BackportRepo or set PS5_BACKPORT_REPO. Tried: " + ($candidates -join '; '))
}

$repo = Find-BackportRepo $BackportRepo
$decrypted = Resolve-InputPath $DecryptedFolder
$output = Resolve-InputPath $OutputFolder

if (-not (Test-Path -LiteralPath $decrypted -PathType Container)) {
    throw "DecryptedFolder does not exist or is not a directory: $decrypted"
}
if ((Test-Path -LiteralPath $output) -and -not $Force) {
    throw "OutputFolder already exists: $output (use -Force to replace it)"
}
if ($TargetFirmware -notmatch '^\d{1,2}\.\d{2}$') {
    throw "TargetFirmware must look like 4.03, not '$TargetFirmware'."
}

# --sdk 4 targets firmware 4.xx and everything above it, so the major version of
# the target firmware selects the pair.
if (-not $PSBoundParameters.ContainsKey('Sdk') -or $Sdk -le 0) {
    $Sdk = [int]($TargetFirmware.Split('.')[0])
}
if ($Sdk -lt 1 -or $Sdk -gt 10) { throw "Derived SDK index $Sdk is outside 1..10; pass -Sdk." }

# The tools need real ELFs. A dump root holds SELFs and produces nothing but
# "not an ELF file" warnings, so check before doing any work.
$elfCount = 0
$selfCount = 0
Get-ChildItem -LiteralPath $decrypted -Recurse -File | ForEach-Object {
    $magic = [byte[]](Get-Content -LiteralPath $_.FullName -Encoding Byte -TotalCount 4 -ErrorAction SilentlyContinue)
    if ($null -eq $magic -or $magic.Length -lt 4) { return }
    if ($magic[0] -eq 0x7F -and $magic[1] -eq 0x45 -and $magic[2] -eq 0x4C -and $magic[3] -eq 0x46) {
        $elfCount++
    } elseif (($magic[0] -eq 0x54 -and $magic[1] -eq 0x14) -or ($magic[0] -eq 0x4F -and $magic[1] -eq 0x15)) {
        $selfCount++
    }
}
Write-Step "Input"
Write-Note "decrypted tree : $decrypted"
Write-Note "ELF files      : $elfCount"
if ($elfCount -eq 0) {
    throw ("No decrypted ELFs found ($selfCount SELF containers seen). These tools need " +
           "real ELFs (7F 45 4C 46); point at the dump's decrypted/ subfolder.")
}
if ($selfCount -gt 0) {
    Write-Warning "$selfCount SELF container(s) in the tree will be ignored; only ELFs are processed."
}
Write-Note "backport repo  : $repo"
Write-Note "target firmware: $TargetFirmware (--sdk $Sdk)"

if ([string]::IsNullOrWhiteSpace($WorkFolder)) {
    $WorkFolder = Join-Path ([IO.Path]::GetTempPath()) ("backport-files-" + [Guid]::NewGuid().ToString('N'))
}
$work = Resolve-InputPath $WorkFolder
$staging = Join-Path $work 'staging'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $staging | Out-Null
if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
New-Item -ItemType Directory -Force -Path $output | Out-Null

$exitCode = 1
try {
    Write-Step "Staging a copy of the decrypted tree"
    $robo = Start-Process -FilePath 'robocopy.exe' `
        -ArgumentList @($decrypted, $staging, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/MT:16') `
        -NoNewWindow -Wait -PassThru
    if ($robo.ExitCode -ge 8) { throw "robocopy failed with exit code $($robo.ExitCode)" }
    Write-Note $staging

    Write-Step "Stage 1 - SDK downgrade to --sdk $Sdk"
    & $Python (Join-Path $repo 'ps5_sdk_downgrade.py') $staging --sdk $Sdk --no-backup 2>&1 |
        ForEach-Object { Write-Note $_ }
    if ($LASTEXITCODE -ne 0) { throw "ps5_sdk_downgrade.py failed with exit code $LASTEXITCODE" }

    if (-not $NoFakelib) {
        Write-Step "Stage 2 - resolving imports against firmware $TargetFirmware"
        $fakelib = Join-Path $output 'fakelib'
        $report = Join-Path $work 'compatibility.json'
        $analyzerArgs = @((Join-Path $repo 'analyze_prx_compatibility.py'), $staging,
                          '--target-firmware', $TargetFirmware,
                          '--firmware-root', (Join-Path $repo 'unp'),
                          '--output', $report, '--no-html',
                          '--copy-to', $fakelib, '--overwrite')
        if ([string]::IsNullOrWhiteSpace($SourceFirmware)) {
            $analyzerArgs += '--find-minimum-firmware'
            Write-Note 'No -SourceFirmware given; searching for the earliest firmware that covers the gap.'
        } else {
            $analyzerArgs += @('--source-firmware', $SourceFirmware)
        }
        # Run from the repo root so the default import_export_db and aerolib.csv resolve.
        Push-Location $repo
        try {
            & $Python @analyzerArgs 2>&1 | ForEach-Object { Write-Note $_ }
            $analyzerExit = $LASTEXITCODE
        } finally { Pop-Location }
        if ($analyzerExit -ne 0) {
            Write-Warning "analyze_prx_compatibility.py exited with $analyzerExit; check the report at $report"
        }
        if (Test-Path -LiteralPath $fakelib -PathType Container) {
            $libs = @(Get-ChildItem -LiteralPath $fakelib -File)
            Write-Note "fakelib: $($libs.Count) library(ies)"
            foreach ($lib in $libs) { Write-Note ("  " + $lib.Name) }
            if ($libs.Count -gt 2) {
                Write-Warning ("The analyzer's list is a superset. A shipped 4.xx backport of a " +
                               "comparable title needs only libSceAgc + libSceAgcDriver. Consider " +
                               "starting with those and adding only what the klog demands - every " +
                               "sideloaded library downgrades a working system library.")
            }
        }
    } else {
        Write-Note 'Skipping fakelib (-NoFakelib).'
    }

    Write-Step "Stage 3 - fake-signing into PS5 SELF containers"
    $signer = Join-Path $repo 'make_fself_ps5.py'
    $signed = 0
    Get-ChildItem -LiteralPath $staging -Recurse -File | ForEach-Object {
        $magic = [byte[]](Get-Content -LiteralPath $_.FullName -Encoding Byte -TotalCount 4 -ErrorAction SilentlyContinue)
        if ($null -eq $magic -or $magic.Length -lt 4) { return }
        if (-not ($magic[0] -eq 0x7F -and $magic[1] -eq 0x45 -and $magic[2] -eq 0x4C -and $magic[3] -eq 0x46)) { return }
        $relative = $_.FullName.Substring($staging.Length).TrimStart('\', '/')
        # Drop the .esbak/.bak suffixes a backup leaves behind so the output lands
        # at the path the game actually loads.
        $target = Join-Path $output ($relative -replace '\.(esbak|bak)$', '')
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        & $Python $signer $_.FullName $target 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "make_fself_ps5.py failed for $relative"
        } else {
            $signed++
            Write-Note ("+ " + ($relative -replace '\.(esbak|bak)$', ''))
        }
    }
    if ($signed -eq 0) { throw 'Nothing was signed; no ELFs survived the downgrade stage.' }

    Write-Step "Result"
    Write-Note "$signed binary(ies) signed into $output"
    Write-Note 'sce_module/libc.prx is NOT produced here: a real backport substitutes the'
    Write-Note 'target SDK build of libc, which is an SDK module and not part of a firmware'
    Write-Note 'tree. Copy it from a released backport of a comparable title.'
    Write-Host ''
    Write-Host "Backport files: $output"
    Write-Host "Package them with: build-backport-update.ps1 -BackportFolder `"$output`" ..."
    $exitCode = 0
}
finally {
    if ($KeepWork) {
        Write-Note "Work folder retained: $work"
    } elseif (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
