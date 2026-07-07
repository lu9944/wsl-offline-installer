#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Restart
)

$ErrorActionPreference = "Stop"

function Get-WslExePath {
    $path = Join-Path $env:WINDIR "System32\wsl.exe"
    if (Test-Path $path) {
        return $path
    }

    $sysnative = Join-Path $env:WINDIR "Sysnative\wsl.exe"
    if (Test-Path $sysnative) {
        return $sysnative
    }

    return $null
}

function Get-InstalledDistroNames {
    param(
        [string]$WslExe
    )

    if (-not $WslExe) {
        return @()
    }

    $output = @(& $WslExe --list --quiet 2>$null)
    return @($output | ForEach-Object { $_.Trim([char]0x00).Trim() } | Where-Object { $_ })
}

function Invoke-MsiUninstall {
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $entries = @()
    foreach ($root in $roots) {
        $entries += @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -like "*Windows Subsystem for Linux*"
        })
    }

    foreach ($entry in $entries) {
        $uninstallString = [string]$entry.UninstallString
        if ($uninstallString -match "\{[0-9A-Fa-f-]{36}\}") {
            $productCode = $Matches[0]
            Write-Host "Uninstalling MSI package: $($entry.DisplayName)"
            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/x", $productCode, "/passive", "/norestart") -Wait -PassThru
            if ($process.ExitCode -notin @(0, 1605, 3010)) {
                Write-Warning "MSI uninstall returned exit code $($process.ExitCode)."
            }
        }
    }
}

function Disable-WslOptionalFeature {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $feature = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction SilentlyContinue
    if ($null -eq $feature -or $feature.State -ne "Enabled") {
        return $false
    }

    Write-Host "Disabling feature: $Name"
    $result = Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart
    return [bool]$result.RestartNeeded
}

if (-not $Force) {
    Write-Host "This will unregister all WSL distributions for the current Windows user and disable WSL components." -ForegroundColor Yellow
    $answer = Read-Host "Type UNINSTALL to continue"
    if ($answer -ne "UNINSTALL") {
        Write-Host "Cancelled."
        exit 1
    }
}

$restartNeeded = $false
$wslExe = Get-WslExePath
$distros = @(Get-InstalledDistroNames -WslExe $wslExe)

if ($wslExe) {
    & $wslExe --shutdown 2>$null
}

foreach ($distro in $distros) {
    Write-Host "Unregistering distro: $distro"
    & $wslExe --unregister $distro
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Unable to unregister distro '$distro'."
    }
}

try {
    $appxPackages = @(Get-AppxPackage -AllUsers -Name "MicrosoftCorporationII.WindowsSubsystemForLinux" -ErrorAction SilentlyContinue)
    foreach ($package in $appxPackages) {
        Write-Host "Removing Appx package: $($package.PackageFullName)"
        Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction SilentlyContinue
    }

    $provisionedPackages = @(Get-AppxProvisionedPackage -Online | Where-Object {
        $_.DisplayName -eq "MicrosoftCorporationII.WindowsSubsystemForLinux"
    })
    foreach ($package in $provisionedPackages) {
        Write-Host "Removing provisioned package: $($package.PackageName)"
        Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName | Out-Null
    }
} catch {
    Write-Warning "Unable to remove WSL Appx package automatically: $($_.Exception.Message)"
}

Invoke-MsiUninstall

foreach ($feature in @("VirtualMachinePlatform", "Microsoft-Windows-Subsystem-Linux")) {
    try {
        if (Disable-WslOptionalFeature -Name $feature) {
            $restartNeeded = $true
        }
    } catch {
        Write-Warning "Unable to disable feature '$feature': $($_.Exception.Message)"
    }
}

if ($restartNeeded) {
    Write-Host ""
    Write-Host "Uninstall completed. Restart Windows to finish removing WSL components." -ForegroundColor Yellow
    if ($Restart) {
        Restart-Computer
    }
} else {
    Write-Host ""
    Write-Host "Uninstall completed." -ForegroundColor Green
}
