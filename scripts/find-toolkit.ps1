<#
    Locating the publishing toolchain.

    It ships in this repo, under toolchain\. Nothing outside this folder is ever
    searched: a second copy elsewhere on the machine is almost certainly a
    different SDK build, and since a package's digest is what the console checks,
    silently falling back to one would be worse than failing outright.

    -ToolkitRoot or PS5_FPKG_TOOLKIT override it for anyone who would rather keep
    the binaries out of their checkout.

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
    $candidates += $scriptRoot
    foreach ($candidate in $candidates) {
        if (Test-ToolkitRoot $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }
    throw ("No publishing toolchain found. Expected toolchain\prospero-pub-cmd.exe " +
           "beside this repo's scripts. Tried: " + ($candidates -join '; '))
}

function Find-DdsConverter([string]$toolkitRoot) {
    <#
        Only wanted when a sce_sys/pic*.dds has no matching PNG. Returning nothing is
        fine: the generator raises its own clear error if it turns out to need one.

        The root is checked as well, because a folder handed over with -ToolkitRoot
        may still use the older layout that kept the converter beside toolchain\.
    #>
    if ([string]::IsNullOrWhiteSpace($toolkitRoot)) { return $null }
    foreach ($candidate in @((Join-Path $toolkitRoot 'toolchain\prospero-dds2png.exe'),
                             (Join-Path $toolkitRoot 'prospero-dds2png.exe'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}
