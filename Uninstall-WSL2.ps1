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
    return @($output | ForEach-Object {
        ($_ -replace "`0", "").Trim()
    } | Where-Object { $_ })
}

function Get-WslDistroRegistryInfo {
    $lxssRoot = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
    if (-not (Test-Path $lxssRoot)) {
        return @()
    }

    $infos = @()
    foreach ($key in (Get-ChildItem $lxssRoot -ErrorAction SilentlyContinue)) {
        $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        if ($props.DistributionName) {
            $infos += [PSCustomObject]@{
                Name              = [string]$props.DistributionName
                PackageFamilyName = [string]$props.PackageFamilyName
                BasePath          = [string]$props.BasePath
                RegPath           = $key.PSPath
            }
        }
    }
    return $infos
}

function Invoke-ForceDistroCleanup {
    $distroInfos = @(Get-WslDistroRegistryInfo)

    if ($distroInfos.Count -eq 0) {
        return
    }

    foreach ($info in $distroInfos) {
        Write-Host "强制移除发行版: $($info.Name)"

        if ($info.PackageFamilyName) {
            $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
                $_.PackageFamilyName -eq $info.PackageFamilyName
            })
            foreach ($pkg in $pkgs) {
                Write-Host "  正在移除 Appx 包: $($pkg.PackageFullName)"
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            }
        }

        Write-Host "  正在移除注册表项"
        Remove-Item -Path $info.RegPath -Recurse -Force -ErrorAction SilentlyContinue

        if ($info.BasePath -and (Test-Path $info.BasePath)) {
            Write-Host "  正在移除数据目录: $($info.BasePath)"
            Remove-Item -Path $info.BasePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-RemainingDistroAppx {
    $distroAppxPatterns = @(
        "CanonicalGroupLimited.Ubuntu*",
        "TheDebianProject.DebianGNULinux",
        "KaliLinux.*",
        "*SUSE*",
        "WhitewaterFoundry.*",
        "*Alpine*WSL*",
        "Oracle.*Linux*"
    )

    foreach ($pattern in $distroAppxPatterns) {
        $pkgs = @(Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue)
        foreach ($pkg in $pkgs) {
            Write-Host "正在移除发行版 Appx 包: $($pkg.PackageFullName)"
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue
        }
    }
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
            Write-Host "正在卸载 MSI 包: $($entry.DisplayName)"
            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/x", $productCode, "/passive", "/norestart") -Wait -PassThru
            if ($process.ExitCode -notin @(0, 1605, 3010)) {
                Write-Warning "MSI 卸载返回退出码 $($process.ExitCode)。"
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

    Write-Host "正在禁用功能: $Name"
    $result = Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart
    return [bool]$result.RestartNeeded
}

if (-not $Force) {
    Write-Host "此操作将注销当前 Windows 用户的所有 WSL 发行版，并禁用 WSL 组件。" -ForegroundColor Yellow
    $answer = (Read-Host "确认卸载? [y/N]").Trim()
    if ($answer -notin @("y", "Y", "yes", "Yes")) {
        Write-Host "已取消。"
        exit 1
    }
}

$restartNeeded = $false
$wslExe = Get-WslExePath

# === 阶段 1: 关闭 WSL ==============================================
if ($wslExe) {
    Write-Host "正在关闭 WSL..."
    & $wslExe --shutdown 2>$null
    Start-Sleep -Seconds 2
}

# === 阶段 2: 正常注销发行版 ========================================
$distros = @(Get-InstalledDistroNames -WslExe $wslExe)
$failedDistros = @()

foreach ($distro in $distros) {
    Write-Host "正在注销发行版: $distro"
    & $wslExe --unregister $distro 2>$null
    if ($LASTEXITCODE -ne 0) {
        $failedDistros += $distro
    }
}

# === 阶段 3: 重启 LxssManager 后重试 ================================
if ($failedDistros.Count -gt 0 -and $wslExe) {
    Write-Host ""
    Write-Host "部分发行版无法注销。正在重启 LxssManager 服务并重试..." -ForegroundColor Yellow

    try {
        Restart-Service LxssManager -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    } catch {
        Write-Warning "无法重启 LxssManager 服务。"
    }

    & $wslExe --shutdown 2>$null
    Start-Sleep -Seconds 1

    $stillFailed = @()
    foreach ($distro in $failedDistros) {
        Write-Host "重试注销: $distro"
        & $wslExe --unregister $distro 2>$null
        if ($LASTEXITCODE -ne 0) {
            $stillFailed += $distro
        }
    }
    $failedDistros = $stillFailed
}

# === 阶段 4: 强制清理 (注册表 + Appx + 数据) ========================
if ($failedDistros.Count -gt 0) {
    Write-Host ""
    Write-Host "$($failedDistros.Count) 个发行版无法通过 wsl --unregister 注销 (WSL_E_DISTRO_NOT_FOUND)。" -ForegroundColor Yellow
    Write-Host "正在通过注册表 + Appx 移除进行强制清理..." -ForegroundColor Yellow

    Invoke-ForceDistroCleanup
    Remove-RemainingDistroAppx

    Write-Host "强制清理完成。" -ForegroundColor Green
}

# === 阶段 5: 移除 WSL 框架 Appx ====================================
try {
    $appxPackages = @(Get-AppxPackage -AllUsers -Name "MicrosoftCorporationII.WindowsSubsystemForLinux" -ErrorAction SilentlyContinue)
    foreach ($package in $appxPackages) {
        Write-Host "正在移除 Appx 包: $($package.PackageFullName)"
        Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction SilentlyContinue
    }

    $provisionedPackages = @(Get-AppxProvisionedPackage -Online | Where-Object {
        $_.DisplayName -eq "MicrosoftCorporationII.WindowsSubsystemForLinux"
    })
    foreach ($package in $provisionedPackages) {
        Write-Host "正在移除预配包: $($package.PackageName)"
        Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName | Out-Null
    }
} catch {
    Write-Warning "无法自动移除 WSL Appx 包: $($_.Exception.Message)"
}

# === 阶段 6: 卸载 WSL MSI ==========================================
Invoke-MsiUninstall

# === 阶段 7: 禁用 Windows 功能 =====================================
foreach ($feature in @("VirtualMachinePlatform", "Microsoft-Windows-Subsystem-Linux")) {
    try {
        if (Disable-WslOptionalFeature -Name $feature) {
            $restartNeeded = $true
        }
    } catch {
        Write-Warning "无法禁用功能 '$feature': $($_.Exception.Message)"
    }
}

# === 阶段 8: 结果 ==================================================
if ($restartNeeded) {
    Write-Host ""
    Write-Host "卸载完成。请重启 Windows 以彻底移除 WSL 组件。" -ForegroundColor Yellow
    if ($Restart) {
        Restart-Computer
    }
} else {
    Write-Host ""
    Write-Host "卸载完成。" -ForegroundColor Green
}
