<#
.SYNOPSIS
    Builds a signed sideload package into .\dist. Run on the build machine.
.DESCRIPTION
    Creates a self-signed certificate on first use (subject must match the Publisher in
    Package.appxmanifest) and keeps it in the current user's store for later builds.
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'ARM64')]
    [string]$Platform = 'x64'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root 'dist'
$subject = 'CN=RTSPKiosk'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' |
    Select-Object -First 1
if (-not $msbuild) { throw 'MSBuild not found. See the Build section of README.md.' }

$cert = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date) -and $_.HasPrivateKey } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
if (-not $cert) {
    Write-Host "Creating self-signed certificate $subject"
    $cert = New-SelfSignedCertificate -Type Custom -Subject $subject -KeyUsage DigitalSignature `
        -FriendlyName 'RTSPKiosk sideloading' -CertStoreLocation Cert:\CurrentUser\My `
        -NotAfter (Get-Date).AddYears(5) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
}

New-Item -ItemType Directory -Force -Path $dist | Out-Null

& $msbuild (Join-Path $root 'RTSPKiosk.sln') /restore /m /v:minimal `
    /p:Configuration=Release `
    /p:Platform=$Platform `
    /p:AppxBundle=Never `
    /p:UapAppxPackageBuildMode=SideloadOnly `
    /p:AppxPackageSigningEnabled=true `
    /p:PackageCertificateThumbprint=$($cert.Thumbprint) `
    /p:AppxPackageDir="$dist\"
if ($LASTEXITCODE -ne 0) { throw "MSBuild failed with exit code $LASTEXITCODE" }

$version = ([xml](Get-Content -Raw (Join-Path $root 'RTSPKiosk\Package.appxmanifest'))).Package.Identity.Version
& (Join-Path $PSScriptRoot 'Test-PackageDependencies.ps1') `
    -PackageFolder (Join-Path $dist "RTSPKiosk_${version}_${Platform}_Test") -Platform $Platform

Export-Certificate -Cert $cert -FilePath (Join-Path $dist 'RTSPKiosk.cer') | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'Install-Kiosk.ps1'), (Join-Path $PSScriptRoot 'Get-KioskDiagnostics.ps1') $dist -Force
Copy-Item (Join-Path $root 'config\config.sample.json') $dist -Force

Write-Host "Package ready in $dist"
