<#
    Locating the publishing toolkit.

    The GP5 generator and the build scripts live in this repo, but the SDK binaries
    they drive do not: prospero-pub-cmd.exe and libScePubTools.dll are not
    redistributable, so the folder holding them is found at run time instead.

    Dot-source this from a script that needs them:

        . (Join-Path $PSScriptRoot 'scripts\find-toolkit.ps1')
        $toolkit = Find-ToolkitRoot $ToolkitRoot $PSScriptRoot
#>

function Test-ToolkitRoot([string]$candidate) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $candidate 'toolchain\prospero-pub-cmd.exe') -PathType Leaf)
}

function Find-ToolkitRoot([string]$explicit, [string]$scriptRoot) {
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($explicit)) { $candidates += $explicit }
    if (-not [string]::IsNullOrWhiteSpace($env:PS5_FPKG_TOOLKIT)) { $candidates += $env:PS5_FPKG_TOOLKIT }
    # A toolchain folder dropped into the repo itself is the simplest arrangement,
    # and .gitignore already keeps it from being committed.
    $candidates += $scriptRoot
    $candidates += (Join-Path $scriptRoot 'fpkg converter')
    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if (-not [string]::IsNullOrWhiteSpace($documents)) {
        $candidates += (Join-Path $documents 'PS5JB\fpkg converter')
    }
    foreach ($candidate in $candidates) {
        if (Test-ToolkitRoot $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }
    throw ("Could not locate the publishing toolkit (the folder holding " +
           "toolchain\prospero-pub-cmd.exe). Pass -ToolkitRoot or set " +
           "PS5_FPKG_TOOLKIT. Tried: " + ($candidates -join '; '))
}

function Find-DdsConverter([string]$toolkitRoot) {
    <#
        Only wanted when a sce_sys/pic*.dds has no matching PNG. Returning nothing is
        fine: the generator raises its own clear error if it turns out to need one.
    #>
    if ([string]::IsNullOrWhiteSpace($toolkitRoot)) { return $null }
    $candidate = Join-Path $toolkitRoot 'prospero-dds2png.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}
