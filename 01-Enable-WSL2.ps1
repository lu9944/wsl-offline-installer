#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$Restart
)

$ErrorActionPreference = "Stop"

function Enable-WslOptionalFeature {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $feature = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction SilentlyContinue
    if ($null -eq $feature) {
        throw "Windows optional feature '$Name' is not available on this system."
    }

    if ($feature.State -eq "Enabled") {
        Write-Host "Feature already enabled: $Name"
        return $false
    }

    Write-Host "Enabling feature: $Name"
    $result = Enable-WindowsOptionalFeature -Online -FeatureName $Name -All -NoRestart
    return [bool]$result.RestartNeeded
}

function Assert-VirtualizationFirmwareEnabled {
    $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
    if ($processors.Count -eq 0) {
        Write-Warning "Unable to determine CPU virtualization firmware status."
        return
    }

    $disabledProcessors = @($processors | Where-Object { -not $_.VirtualizationFirmwareEnabled })
    if ($disabledProcessors.Count -gt 0) {
        Write-Error "CPU virtualization is disabled in firmware. Enable Intel VT-x or AMD-V in BIOS/UEFI before installing WSL 2."
        exit 1
    }

    Write-Host "CPU virtualization is enabled in firmware."
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
Write-Host "Detected OS: $($os.Caption) $($os.Version)"
Assert-VirtualizationFirmwareEnabled

$restartNeeded = $false
$features = @(
    "Microsoft-Windows-Subsystem-Linux",
    "VirtualMachinePlatform"
)

foreach ($feature in $features) {
    try {
        if (Enable-WslOptionalFeature -Name $feature) {
            $restartNeeded = $true
        }
    } catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

try {
    bcdedit /set hypervisorlaunchtype auto | Out-Null
    Write-Host "Hypervisor launch type set to auto."
} catch {
    Write-Warning "Unable to set hypervisor launch type automatically: $($_.Exception.Message)"
}


if ($restartNeeded) {
    Write-Host ""
    Write-Host "Step 1 completed. Restart Windows, then run 02-Install-WSL2-And-Distro.ps1." -ForegroundColor Yellow
    if ($Restart) {
        Restart-Computer
    }
} else {
    Write-Host ""
    Write-Host "Step 1 completed. No restart was requested by Windows. Run 02-Install-WSL2-And-Distro.ps1 next." -ForegroundColor Green
}
