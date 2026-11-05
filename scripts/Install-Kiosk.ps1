<#
.SYNOPSIS
    Installs RTSPKiosk on the kiosk device. Run elevated, from the copied dist folder.
.DESCRIPTION
    1. Trusts the signing certificate.
    2. Provisions the app and its framework dependencies for all users. LTSC has no Store
       to supply the dependencies, so they must come from the package folder.
    3. Deploys config.json to C:\ProgramData\RTSPKiosk, readable only by Administrators,
       SYSTEM, the kiosk account and the app itself.
    4. With -EnableKiosk, assigns the app to the account as its single-app kiosk.
.EXAMPLE
    .\Install-Kiosk.ps1 -KioskUser kiosk -ConfigPath .\config.json -EnableKiosk
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$KioskUser,

    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [string]$PackageRoot,

    [switch]$EnableKiosk
)

$ErrorActionPreference = 'Stop'
if (-not $PackageRoot) { $PackageRoot = $PSScriptRoot }

function Get-AppContainerSid([string]$PackageFamilyName) {
    if (-not ('RTSPKiosk.Native' -as [type])) {
        Add-Type -Namespace RTSPKiosk -Name Native -MemberDefinition @'
[DllImport("userenv.dll", CharSet = CharSet.Unicode)]
public static extern int DeriveAppContainerSidFromAppContainerName(string name, out IntPtr sid);
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool ConvertSidToStringSid(IntPtr sid, out IntPtr text);
[DllImport("advapi32.dll")]
public static extern IntPtr FreeSid(IntPtr sid);
[DllImport("kernel32.dll")]
public static extern IntPtr LocalFree(IntPtr mem);
'@
    }

    $sid = [IntPtr]::Zero
    $text = [IntPtr]::Zero
    $hr = [RTSPKiosk.Native]::DeriveAppContainerSidFromAppContainerName($PackageFamilyName, [ref]$sid)
    if ($hr -ne 0) { throw ('Could not derive the app SID (0x{0:X8})' -f $hr) }
    try {
        if (-not [RTSPKiosk.Native]::ConvertSidToStringSid($sid, [ref]$text)) {
            throw 'Could not format the app SID'
        }
        return [Runtime.InteropServices.Marshal]::PtrToStringUni($text)
    }
    finally {
        [void][RTSPKiosk.Native]::FreeSid($sid)
        if ($text -ne [IntPtr]::Zero) { [void][RTSPKiosk.Native]::LocalFree($text) }
    }
}

# Validate everything checkable before changing the machine.
$account = (New-Object Security.Principal.NTAccount($KioskUser)).Translate([Security.Principal.SecurityIdentifier])

# Held in memory because step 3 recreates the folder, which may be where -ConfigPath points.
$configBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ConfigPath).ProviderPath)
$settings = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
if ($settings.url -notmatch '^rtsps?://') { throw "$ConfigPath must set `"url`" to an rtsp:// address" }

$architecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x64' }
$package = Get-ChildItem -LiteralPath $PackageRoot -Recurse -File |
    Where-Object { $_.Extension -in '.msix', '.appx' -and $_.BaseName -like "RTSPKiosk_*_$architecture" } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if (-not $package) { throw "No $architecture RTSPKiosk package found under $PackageRoot" }

$certificate = Join-Path $PackageRoot 'RTSPKiosk.cer'
if (-not (Test-Path -LiteralPath $certificate)) { throw "Missing $certificate" }

Write-Host '1/4 Trusting the signing certificate'
Import-Certificate -FilePath $certificate -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null

Write-Host "2/4 Provisioning $($package.Name)"
$dependencyDir = Join-Path $package.DirectoryName "Dependencies\$architecture"
$dependencies = @(Get-ChildItem -LiteralPath $dependencyDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.appx', '.msix' } |
    ForEach-Object { $_.FullName })
if ($dependencies.Count -eq 0) { throw "No framework dependencies found in $dependencyDir" }
Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'RTSPKiosk' } |
    ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName | Out-Null }
Add-AppxProvisionedPackage -Online -PackagePath $package.FullName -DependencyPackagePath $dependencies -SkipLicense | Out-Null

$provisioned = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'RTSPKiosk' } | Select-Object -First 1
if (-not $provisioned) { throw 'RTSPKiosk is not provisioned' }
$familyName = $provisioned.PackageName -replace '^([^_]+)_.*__(.+)$', '$1_$2'
$appUserModelId = "$familyName!App"

Write-Host '3/4 Deploying the configuration'
$folder = 'C:\ProgramData\RTSPKiosk'
$target = Join-Path $folder 'config.json'
Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $folder | Out-Null

# A sandboxed app is checked twice: both the user and the package SID need access.
# Set this before copying the file in, so the file inherits it. Applying these grants to an
# existing file with /T instead leaves it with an empty ACL: the flags don't apply to files.
$appSid = Get-AppContainerSid $familyName
& icacls.exe $folder /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' `
    "*$($account.Value):(OI)(CI)RX" "*${appSid}:(OI)(CI)RX" /Q
if ($LASTEXITCODE -ne 0) { throw "icacls failed with exit code $LASTEXITCODE" }
[IO.File]::WriteAllBytes($target, $configBytes)

if ($EnableKiosk) {
    Write-Host "4/4 Assigning the kiosk to $KioskUser"
    Set-AssignedAccess -AppUserModelId $appUserModelId -UserName $KioskUser
}
else {
    Write-Host '4/4 Skipped kiosk assignment (use -EnableKiosk, or Settings > Accounts > Other users > Kiosk)'
}

Write-Host "Done. AppUserModelId: $appUserModelId"
