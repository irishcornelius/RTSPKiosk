<#
.SYNOPSIS
    Fails if a framework bundled with a built package is older than the package requires.
.DESCRIPTION
    LTSC has no Store to supply a newer framework, and provisioning doesn't check versions, so
    a mismatch installs cleanly and then fails at launch with 0x80073CF3. Catch it at build time.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageFolder,

    [Parameter(Mandatory)]
    [ValidateSet('x64', 'ARM64')]
    [string]$Platform
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-Manifest([string]$Path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $reader = New-Object IO.StreamReader($zip.GetEntry('AppxManifest.xml').Open())
        try { [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $zip.Dispose() }
}

$package = Get-ChildItem -LiteralPath $PackageFolder -File |
    Where-Object { $_.Extension -in '.msix', '.appx' } |
    Select-Object -First 1
if (-not $package) { throw "No package found in $PackageFolder" }

$bundled = @{}
Get-ChildItem -LiteralPath (Join-Path $PackageFolder "Dependencies\$Platform") -File -Filter *.appx | ForEach-Object {
    $identity = (Read-Manifest $_.FullName).Package.Identity
    $bundled[$identity.Name] = [version]$identity.Version
}

$problems = @()
foreach ($dependency in @((Read-Manifest $package.FullName).Package.Dependencies.PackageDependency)) {
    $required = [version]$dependency.MinVersion
    if (-not $bundled.ContainsKey($dependency.Name)) {
        Write-Warning "$($dependency.Name) >= $required is not bundled; the device must already have it."
    }
    elseif ($bundled[$dependency.Name] -lt $required) {
        $problems += "$($dependency.Name): requires $required, bundled $($bundled[$dependency.Name])"
    }
    else {
        Write-Host "OK $($dependency.Name): requires $required, bundled $($bundled[$dependency.Name])"
    }
}

if ($problems) { throw "Bundled frameworks can't satisfy $($package.Name):`n$($problems -join "`n")" }
