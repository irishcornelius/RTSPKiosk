<#
.SYNOPSIS
    Collects why RTSPKiosk won't start. Read-only. Run elevated, just after trying to launch the app.
.DESCRIPTION
    Writes RTSPKiosk-diagnostics.txt next to this script. The report covers account and UAC state,
    package registration, certificate trust, app-control policy, kiosk assignment, config file
    presence and permissions, crash logs and recent event log entries. It never reads the contents
    of config.json beyond checking the JSON is valid, so the camera password is not included.
#>
[CmdletBinding()]
param(
    [int]$Hours = 24,
    [string]$OutputPath
)

$ErrorActionPreference = 'Continue'
if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot 'RTSPKiosk-diagnostics.txt' }

function Section([string]$Title, [scriptblock]$Body) {
    "`n===== $Title ====="
    try { & $Body | Out-String -Width 200 } catch { "FAILED: $($_.Exception.Message)" }
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning 'Not elevated: package, assignment and permission sections will fail. Re-run as administrator.'
}

$since = (Get-Date).AddHours(-$Hours)

$report = & {
    "RTSPKiosk diagnostics, $(Get-Date -Format o)"

    Section 'Windows' {
        $os = Get-CimInstance Win32_OperatingSystem
        $current = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        "$($os.Caption), edition $($current.EditionID), version $($current.DisplayVersion), build $($current.CurrentBuild).$($current.UBR), $($env:PROCESSOR_ARCHITECTURE)"
    }

    Section 'Current account' {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        "User: $($identity.Name)  SID: $($identity.User.Value)"
        "Elevated: $($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
        "Built-in Administrator (cannot run UWP apps by default): $($identity.User.Value -like '*-500')"
    }

    Section 'UAC (UWP apps need EnableLUA = 1)' {
        $policy = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        "EnableLUA: $($policy.EnableLUA)"
        "FilterAdministratorToken: $($policy.FilterAdministratorToken)"
    }

    Section 'Sideloading and app policy' {
        Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue |
            Select-Object AllowAllTrustedApps, AllowDevelopmentWithoutDevLicense
        $appx = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx'
        if (Test-Path $appx) { Get-ItemProperty $appx }
        $store = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
        if (Test-Path $store) { Get-ItemProperty $store }
        'AppLocker packaged-app rules:'
        (Get-AppLockerPolicy -Effective -ErrorAction SilentlyContinue).RuleCollections |
            Where-Object { $_.RuleCollectionType -eq 'Appx' } |
            ForEach-Object { "  enforcement=$($_.EnforcementMode) rules=$($_.Count)" }
        $guard = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
        if ($guard) { "App Control user-mode enforcement status: $($guard.UsermodeCodeIntegrityPolicyEnforcementStatus)" }
    }

    Section 'Package registration' {
        $packages = @(Get-AppxPackage -AllUsers -Name RTSPKiosk)
        if ($packages.Count -eq 0) { 'RTSPKiosk is NOT registered for any user' }
        foreach ($package in $packages) {
            $package | Select-Object PackageFullName, PackageFamilyName, Version, Architecture, SignatureKind, Status, InstallLocation | Format-List
            'Registered users:'
            $package.PackageUserInformation | ForEach-Object { "  $($_.UserSecurityId.Username): $($_.InstallState)" }
            'Declared dependencies:'
            $package.Dependencies | ForEach-Object { "  $($_.PackageFullName)  status=$($_.Status)" }
            if ($package.InstallLocation) {
                'Files missing or unreadable at install location:'
                'RTSPKiosk.exe', 'RTSPKiosk.dll', 'FFmpegInteropX.dll', 'avformat-62.dll', 'AppxManifest.xml' |
                    Where-Object { -not (Test-Path (Join-Path $package.InstallLocation $_)) } |
                    ForEach-Object { "  $_" }
            }
        }
    }

    # Separate section: this call needs full elevation, and a failure here must not lose the above.
    Section 'Provisioned package' {
        Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'RTSPKiosk' } | Select-Object -ExpandProperty PackageName
        'End of provisioned list.'
    }

    Section 'Framework packages' {
        Get-AppxPackage -AllUsers |
            Where-Object { $_.Name -like 'Microsoft.VCLibs.140.00*' -or $_.Name -like 'Microsoft.NET.Native.*' } |
            Sort-Object Name, Architecture |
            Select-Object Name, Version, Architecture, Status | Format-Table -AutoSize
    }

    Section 'Certificate trust' {
        foreach ($store in 'TrustedPeople', 'Root') {
            Get-ChildItem "Cert:\LocalMachine\$store" | Where-Object { $_.Subject -eq 'CN=RTSPKiosk' } |
                ForEach-Object { "$store  thumbprint=$($_.Thumbprint)  expires=$($_.NotAfter)" }
        }
        'End of certificate list.'
    }

    Section 'Assigned Access' {
        Get-AssignedAccess -ErrorAction SilentlyContinue | Format-List
        'End of assignment list.'
    }

    Section 'Configuration' {
        $path = 'C:\ProgramData\RTSPKiosk\config.json'
        if (Test-Path -LiteralPath $path) {
            try { $null = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json; "$path exists, JSON valid" }
            catch { "$path exists, JSON INVALID" }
            & icacls.exe $path
        }
        else { "$path does not exist" }
    }

    Section 'App data and crash logs, per user' {
        foreach ($folder in Get-ChildItem 'C:\Users\*\AppData\Local\Packages\RTSPKiosk_*' -Directory -ErrorAction SilentlyContinue) {
            "--- $($folder.FullName)"
            "LocalState config.json present: $(Test-Path (Join-Path $folder.FullName 'LocalState\config.json'))"
            $crash = Join-Path $folder.FullName 'LocalState\crash.log'
            if (Test-Path -LiteralPath $crash) { Get-Content -LiteralPath $crash -Tail 60 }
        }
        'End of app data list.'
    }

    Section "App crash events, last $Hours hours" {
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $since } -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match 'RTSPKiosk' } |
            Select-Object -First 20 |
            ForEach-Object { "[$($_.TimeCreated)] $($_.ProviderName) id=$($_.Id)`n$($_.Message)`n" }
    }

    foreach ($log in 'Microsoft-Windows-TWinUI/Operational',
        'Microsoft-Windows-AppModel-Runtime/Admin',
        'Microsoft-Windows-AppXDeploymentServer/Operational',
        'Microsoft-Windows-AppXDeployment/Operational',
        'Microsoft-Windows-AppLocker/Packaged app-Execution',
        'Microsoft-Windows-CodeIntegrity/Operational') {
        Section "$log, last $Hours hours" {
            Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $since } -ErrorAction SilentlyContinue |
                Where-Object { $_.Message -match 'RTSPKiosk' } |
                Select-Object -First 15 |
                ForEach-Object { "[$($_.TimeCreated)] $($_.LevelDisplayName) id=$($_.Id): $($_.Message)" }
        }
    }
}

$report | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Report written to $OutputPath"
