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
        throw "Windows 可选功能 '$Name' 在此系统上不可用。"
    }

    if ($feature.State -eq "Enabled") {
        Write-Host "功能已启用: $Name"
        return $false
    }

    Write-Host "正在启用功能: $Name"
    $result = Enable-WindowsOptionalFeature -Online -FeatureName $Name -All -NoRestart
    return [bool]$result.RestartNeeded
}

function Assert-VirtualizationFirmwareEnabled {
    $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
    if ($processors.Count -eq 0) {
        Write-Warning "无法确定 CPU 虚拟化固件状态。"
        return
    }

    $disabledProcessors = @($processors | Where-Object { -not $_.VirtualizationFirmwareEnabled })
    if ($disabledProcessors.Count -gt 0) {
        Write-Error "CPU 虚拟化已在固件中禁用。请在 BIOS/UEFI 中启用 Intel VT-x 或 AMD-V 后再安装 WSL 2。"
        exit 1
    }

    Write-Host "CPU 虚拟化已在固件中启用。"
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
Write-Host "检测到操作系统: $($os.Caption) $($os.Version)"
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
    Write-Host "Hypervisor 启动类型已设置为 auto。"
} catch {
    Write-Warning "无法自动设置 hypervisor 启动类型: $($_.Exception.Message)"
}


if ($restartNeeded) {
    Write-Host ""
    Write-Host "第一步完成。请重启 Windows，然后运行 02-Install-WSL2-And-Distro.ps1。" -ForegroundColor Yellow
    if ($Restart) {
        Restart-Computer
    }
} else {
    Write-Host ""
    Write-Host "第一步完成。Windows 未要求重启，请直接运行 02-Install-WSL2-And-Distro.ps1。" -ForegroundColor Green
}
