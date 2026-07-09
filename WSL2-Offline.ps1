#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet("Install","Uninstall","Check")]
    [string]$Action,
    [string]$DistroName = "Ubuntu-24.04",
    [string]$InstallRoot,
    [string]$ImagePath,
    [string]$WslInstallerPath,
    [switch]$Force,
    [switch]$Restart
)

$ErrorActionPreference = "Stop"

# ==================================================================
#  共用函数
# ==================================================================

function Get-ScriptRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Get-WslExePath {
    $path = Join-Path $env:WINDIR "System32\wsl.exe"
    if (Test-Path $path) { return $path }
    $sysnative = Join-Path $env:WINDIR "Sysnative\wsl.exe"
    if (Test-Path $sysnative) { return $sysnative }
    return $null
}

function Get-InstalledDistroNames {
    param([string]$WslExe)
    if (-not $WslExe) { return @() }
    $output = @(& $WslExe --list --quiet 2>$null)
    return @($output | ForEach-Object {
        ($_ -replace "`0", "").Trim()
    } | Where-Object { $_ })
}

function Get-DiskFreeGB {
    param([string]$Path)
    try {
        $qualified = Split-Path -Qualifier $Path -ErrorAction SilentlyContinue
        if (-not $qualified) { return $null }
        $driveName = $qualified -replace '[:\\]', ''
        $psd = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        if ($psd -and $psd.Free) {
            return [math]::Round($psd.Free / 1GB, 1)
        }
    } catch {}
    return $null
}

function Resolve-PackageFile {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )
    $files = @()
    foreach ($pattern in $Patterns) {
        $files += @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)
    }
    $files = @($files | Sort-Object -Property LastWriteTimeUtc -Descending)
    if ($files.Count -eq 0) {
        throw "找不到$Description。预期路径之一: $($Patterns -join ', ')"
    }
    return $files[0].FullName
}

function Expand-GzipImage {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not $Path.EndsWith(".gz", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path
    }
    $targetName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $targetPath = Join-Path $env:TEMP $targetName
    if (Test-Path $targetPath) { Remove-Item -Path $targetPath -Force }
    Write-Host "正在解压 gzip 镜像到临时 tar 文件: $targetPath"
    $inputStream = [System.IO.File]::OpenRead($Path)
    try {
        $gzipStream = [System.IO.Compression.GzipStream]::new($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $outputStream = [System.IO.File]::Create($targetPath)
            try { $gzipStream.CopyTo($outputStream) }
            finally { $outputStream.Dispose() }
        } finally { $gzipStream.Dispose() }
    } finally { $inputStream.Dispose() }
    return $targetPath
}

# ==================================================================
#  安装相关函数
# ==================================================================

function Assert-VirtualizationFirmwareEnabled {
    $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
    if ($processors.Count -eq 0) {
        Write-Warning "无法确定 CPU 虚拟化固件状态。"
        return
    }
    $disabled = @($processors | Where-Object { -not $_.VirtualizationFirmwareEnabled })
    if ($disabled.Count -gt 0) {
        Write-Error "CPU 虚拟化已在固件中禁用。请在 BIOS/UEFI 中启用 Intel VT-x 或 AMD-V 后再安装 WSL 2。"
        exit 1
    }
    Write-Host "[OK] CPU 虚拟化已在固件中启用。" -ForegroundColor Green
}

function Test-WslFeaturesEnabled {
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -ErrorAction SilentlyContinue
    $vmFeature  = Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -ErrorAction SilentlyContinue
    return ($wslFeature -and $wslFeature.State -eq "Enabled" -and
            $vmFeature  -and $vmFeature.State  -eq "Enabled")
}

function Install-WslPackage {
    param([Parameter(Mandatory = $true)][string]$Path)
    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($extension) {
        ".msi" {
            Write-Host "正在安装 WSL 包: $Path"
            $arguments = @("/i", "`"$Path`"", "/passive", "/norestart")
            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru
            if ($process.ExitCode -notin @(0, 3010)) {
                throw "WSL MSI 安装程序失败，退出码 $($process.ExitCode)。"
            }
        }
        ".msixbundle" { Write-Host "正在安装 WSL 包: $Path"; Add-AppxPackage -Path $Path -ForceApplicationShutdown }
        ".appxbundle" { Write-Host "正在安装 WSL 包: $Path"; Add-AppxPackage -Path $Path -ForceApplicationShutdown }
        default { throw "不支持的 WSL 安装包格式: $extension" }
    }
}

function Select-InstallLocation {
    param([string]$Preset)

    if ($Preset) { return $Preset }

    $defaultRoot = Join-Path $env:LOCALAPPDATA "WSL"

    Write-Host ""
    Write-Host "选择发行版安装位置" -ForegroundColor Cyan
    Write-Host "  默认路径: $defaultRoot"
    $defaultFree = Get-DiskFreeGB -Path $defaultRoot
    if ($null -ne $defaultFree) {
        Write-Host "  剩余空间: $defaultFree GB" -ForegroundColor Gray
    }
    Write-Host ""

    while ($true) {
        $userInput = (Read-Host "输入自定义路径，或按回车使用默认路径").Trim()

        if (-not $userInput) { return $defaultRoot }

        if ($userInput -notmatch '^[A-Za-z]:[\\/]') {
            Write-Host "  格式无效，请使用完整路径，例如 D:\WSL" -ForegroundColor Red
            continue
        }

        $driveLetter = $userInput[0]
        $drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
        if (-not $drive) {
            Write-Host "  盘符 ${driveLetter}:\ 在此系统上不存在。" -ForegroundColor Red
            continue
        }

        try {
            $testParent = Split-Path -Parent $userInput
            if (-not $testParent) { $testParent = $userInput }
            $leaf = Split-Path -Leaf $userInput
            $probePath = Join-Path $testParent ($leaf + ".wslwriteprobe")
            New-Item -ItemType Directory -Path $probePath -Force -ErrorAction Stop | Out-Null
            Remove-Item -Path $probePath -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Host "  无法在此路径创建目录: $($_.Exception.Message)" -ForegroundColor Red
            continue
        }

        return $userInput
    }
}

function Invoke-WslInstall {
    Write-Host ""
    Write-Host "========== 开始安装 WSL2 ==========" -ForegroundColor Cyan

    # --- 检测环境 ---
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    Write-Host "检测到操作系统: $($os.Caption) $($os.Version)"
    Assert-VirtualizationFirmwareEnabled

    # --- 启用 Windows 功能 ---
    $needReboot = $false

    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -ErrorAction SilentlyContinue
    if ($wslFeature.State -ne "Enabled") {
        Write-Host "正在启用功能: Microsoft-Windows-Subsystem-Linux"
        $result = Enable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -All -NoRestart
        if ($result.RestartNeeded) { $needReboot = $true }
    } else {
        Write-Host "[OK] 功能已启用: Microsoft-Windows-Subsystem-Linux" -ForegroundColor Green
    }

    $vmFeature = Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -ErrorAction SilentlyContinue
    if ($vmFeature.State -ne "Enabled") {
        Write-Host "正在启用功能: VirtualMachinePlatform"
        $result = Enable-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -All -NoRestart
        if ($result.RestartNeeded) { $needReboot = $true }
    } else {
        Write-Host "[OK] 功能已启用: VirtualMachinePlatform" -ForegroundColor Green
    }

    try {
        bcdedit /set hypervisorlaunchtype auto | Out-Null
        Write-Host "[OK] Hypervisor 启动类型已设置为 auto。" -ForegroundColor Green
    } catch {
        Write-Warning "无法自动设置 hypervisor 启动类型: $($_.Exception.Message)"
    }

    # --- 如果需要重启 ---
    if ($needReboot) {
        Write-Host ""
        Write-Host "已启用 WSL 功能，需要重启 Windows 才能继续。" -ForegroundColor Yellow
        Write-Host "重启后请再次运行本脚本，将自动继续安装发行版。" -ForegroundColor Yellow
        Write-Host ""
        if ($Restart) {
            Restart-Computer -Force
        }
        $rebootNow = (Read-Host "立即重启? [y/N]").Trim()
        if ($rebootNow -in @("y","Y","yes","Yes")) {
            Restart-Computer -Force
        }
        return
    }

    # --- 功能已就绪，继续安装 WSL 内核 + 发行版 ---
    Write-Host ""
    Write-Host "WSL 功能已就绪，继续安装..." -ForegroundColor Cyan

    $scriptRoot = Get-ScriptRoot

    if (-not $WslInstallerPath) {
        $WslInstallerPath = Resolve-PackageFile -Description "WSL 安装包" -Patterns @(
            (Join-Path $scriptRoot "packages\wsl*.msi"),
            (Join-Path $scriptRoot "packages\Microsoft.WSL*.msixbundle"),
            (Join-Path $scriptRoot "packages\*.msixbundle"),
            (Join-Path $scriptRoot "packages\*.appxbundle")
        )
    }

    if (-not $ImagePath) {
        $ImagePath = Resolve-PackageFile -Description "Linux rootfs 镜像" -Patterns @(
            (Join-Path $scriptRoot "images\*.rootfs.tar"),
            (Join-Path $scriptRoot "images\*.rootfs.tar.gz"),
            (Join-Path $scriptRoot "images\*.tar"),
            (Join-Path $scriptRoot "images\*.tar.gz")
        )
    }

    Install-WslPackage -Path $WslInstallerPath

    $wslExe = Get-WslExePath
    if (-not $wslExe) {
        throw "WSL 内核安装后仍未找到 wsl.exe。请重启后再次运行本脚本。"
    }

    & $wslExe --set-default-version 2 2>$null

    # --- 检查同名发行版 ---
    $existingDistros = @(Get-InstalledDistroNames -WslExe $wslExe)
    if ($existingDistros -contains $DistroName) {
        if (-not $Force) {
            Write-Host "发行版 '$DistroName' 已安装。使用 -Force 参数可注销并重新导入。" -ForegroundColor Yellow
            & $wslExe --set-version $DistroName 2 2>$null
            & $wslExe --set-default $DistroName 2>$null
            Write-Host ""
            Write-Host "安装完成。使用以下命令启动 Linux: wsl -d $DistroName" -ForegroundColor Green
            return
        }
        Write-Host "正在注销已存在的发行版: $DistroName"
        & $wslExe --unregister $DistroName 2>$null
    }

    # --- 选择安装位置 ---
    $resolvedRoot = Select-InstallLocation -Preset $InstallRoot

    $freeGB = Get-DiskFreeGB -Path $resolvedRoot
    if ($null -ne $freeGB) {
        Write-Host "安装位置: $resolvedRoot  (剩余 $freeGB GB)" -ForegroundColor Green
        if ($freeGB -lt 5) {
            Write-Warning "目标盘空间不足 (剩余 $freeGB GB)。WSL 发行版会快速增大。"
        }
    } else {
        Write-Host "安装位置: $resolvedRoot" -ForegroundColor Green
    }

    $distroInstallPath = Join-Path $resolvedRoot $DistroName
    New-Item -ItemType Directory -Path $distroInstallPath -Force | Out-Null

    # --- 导入发行版 ---
    $imageForImport = Expand-GzipImage -Path $ImagePath
    $removeExpandedImage = $imageForImport -ne $ImagePath

    try {
        Write-Host "正在导入发行版 '$DistroName' 到 $distroInstallPath"
        & $wslExe --import $DistroName $distroInstallPath $imageForImport --version 2
        if ($LASTEXITCODE -ne 0) {
            throw "WSL 导入失败，退出码 $LASTEXITCODE。"
        }
    } finally {
        if ($removeExpandedImage -and (Test-Path $imageForImport)) {
            Remove-Item -Path $imageForImport -Force
        }
    }

    & $wslExe --set-default $DistroName 2>$null
    & $wslExe --shutdown 2>$null

    Write-Host ""
    Write-Host "========== 安装完成 ==========" -ForegroundColor Green
    Write-Host "使用以下命令启动 Linux: wsl -d $DistroName" -ForegroundColor Green
}

# ==================================================================
#  卸载相关函数
# ==================================================================

function Get-WslDistroRegistryInfo {
    $lxssRoot = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
    if (-not (Test-Path $lxssRoot)) { return @() }
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
    foreach ($info in @(Get-WslDistroRegistryInfo)) {
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
    $patterns = @(
        "CanonicalGroupLimited.Ubuntu*",
        "TheDebianProject.DebianGNULinux",
        "KaliLinux.*",
        "*SUSE*",
        "WhitewaterFoundry.*",
        "*Alpine*WSL*",
        "Oracle.*Linux*"
    )
    foreach ($pattern in $patterns) {
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
            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/x",$productCode,"/passive","/norestart") -Wait -PassThru
            if ($process.ExitCode -notin @(0,1605,3010)) {
                Write-Warning "MSI 卸载返回退出码 $($process.ExitCode)。"
            }
        }
    }
}

function Invoke-WslUninstall {
    Write-Host ""
    Write-Host "========== 开始卸载 WSL2 ==========" -ForegroundColor Cyan

    if (-not $Force) {
        Write-Host "此操作将注销所有 WSL 发行版，移除 WSL 组件并禁用 Windows 功能。" -ForegroundColor Yellow
        $answer = (Read-Host "确认卸载? [y/N]").Trim()
        if ($answer -notin @("y","Y","yes","Yes")) {
            Write-Host "已取消。"
            return
        }
    }

    $restartNeeded = $false
    $wslExe = Get-WslExePath

    # --- 阶段 1: 关闭 WSL ---
    if ($wslExe) {
        Write-Host "[1/7] 正在关闭 WSL..."
        & $wslExe --shutdown 2>$null
        Start-Sleep -Seconds 2
    } else {
        Write-Host "[1/7] wsl.exe 不存在，跳过关闭。" -ForegroundColor Gray
    }

    # --- 阶段 2: 正常注销发行版 ---
    $distros = @(Get-InstalledDistroNames -WslExe $wslExe)
    $failedDistros = @()
    if ($distros.Count -eq 0) {
        Write-Host "[2/7] 无已安装发行版，跳过注销。" -ForegroundColor Gray
    } else {
        foreach ($distro in $distros) {
            Write-Host "[2/7] 正在注销发行版: $distro"
            & $wslExe --unregister $distro 2>$null
            if ($LASTEXITCODE -ne 0) { $failedDistros += $distro }
        }
    }

    # --- 阶段 3: 重启 LxssManager 后重试 ---
    if ($failedDistros.Count -gt 0 -and $wslExe) {
        Write-Host "[3/7] 部分发行版无法注销。正在重启 LxssManager 服务并重试..." -ForegroundColor Yellow
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
            Write-Host "[3/7] 重试注销: $distro"
            & $wslExe --unregister $distro 2>$null
            if ($LASTEXITCODE -ne 0) { $stillFailed += $distro }
        }
        $failedDistros = $stillFailed
    } elseif ($failedDistros.Count -eq 0) {
        Write-Host "[3/7] 无需重试。" -ForegroundColor Gray
    }

    # --- 阶段 4: 强制清理 ---
    if ($failedDistros.Count -gt 0) {
        Write-Host "[4/7] $($failedDistros.Count) 个发行版无法通过 wsl --unregister 注销。" -ForegroundColor Yellow
        Write-Host "      正在通过注册表 + Appx 移除进行强制清理..." -ForegroundColor Yellow
        Invoke-ForceDistroCleanup
        Remove-RemainingDistroAppx
        Write-Host "[4/7] 强制清理完成。" -ForegroundColor Green
    } else {
        Write-Host "[4/7] 无需强制清理。" -ForegroundColor Gray
    }

    # --- 阶段 5: 移除 WSL 框架 Appx ---
    $foundAppx = $false
    try {
        $appxPackages = @(Get-AppxPackage -AllUsers -Name "MicrosoftCorporationII.WindowsSubsystemForLinux" -ErrorAction SilentlyContinue)
        foreach ($package in $appxPackages) {
            $foundAppx = $true
            Write-Host "[5/7] 正在移除 Appx 包: $($package.PackageFullName)"
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction SilentlyContinue
        }
        $provisionedPackages = @(Get-AppxProvisionedPackage -Online | Where-Object {
            $_.DisplayName -eq "MicrosoftCorporationII.WindowsSubsystemForLinux"
        })
        foreach ($package in $provisionedPackages) {
            $foundAppx = $true
            Write-Host "[5/7] 正在移除预配包: $($package.PackageName)"
            Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName | Out-Null
        }
    } catch {
        Write-Warning "[5/7] 无法自动移除 WSL Appx 包: $($_.Exception.Message)"
    }
    if (-not $foundAppx) {
        Write-Host "[5/7] 未找到 WSL 框架 Appx 包，跳过。" -ForegroundColor Gray
    }

    # --- 阶段 6: 卸载 WSL MSI ---
    $msiEntries = @()
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($root in $roots) {
        $msiEntries += @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -like "*Windows Subsystem for Linux*"
        })
    }
    if ($msiEntries.Count -eq 0) {
        Write-Host "[6/7] 未找到 WSL MSI 包，跳过。" -ForegroundColor Gray
    } else {
        foreach ($entry in $msiEntries) {
            $uninstallString = [string]$entry.UninstallString
            if ($uninstallString -match "\{[0-9A-Fa-f-]{36}\}") {
                $productCode = $Matches[0]
                Write-Host "[6/7] 正在卸载 MSI 包: $($entry.DisplayName)"
                $process = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/x",$productCode,"/passive","/norestart") -Wait -PassThru
                if ($process.ExitCode -notin @(0,1605,3010)) {
                    Write-Warning "[6/7] MSI 卸载返回退出码 $($process.ExitCode)。"
                }
            }
        }
    }

    # --- 阶段 7: 禁用 Windows 功能 ---
    foreach ($featureName in @("VirtualMachinePlatform","Microsoft-Windows-Subsystem-Linux")) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction SilentlyContinue
        if ($null -eq $feature -or $feature.State -ne "Enabled") {
            Write-Host "[7/7] 功能未启用，跳过: $featureName" -ForegroundColor Gray
            continue
        }
        Write-Host "[7/7] 正在禁用功能: $featureName"
        $result = Disable-WindowsOptionalFeature -Online -FeatureName $featureName -NoRestart
        if ($result.RestartNeeded) { $restartNeeded = $true }
    }

    # --- 结果 ---
    Write-Host ""
    if ($restartNeeded) {
        Write-Host "========== 卸载完成 ==========" -ForegroundColor Yellow
        Write-Host "请重启 Windows 以彻底移除 WSL 组件。" -ForegroundColor Yellow
        if ($Restart) { Restart-Computer }
    } else {
        Write-Host "========== 卸载完成 ==========" -ForegroundColor Green
    }
}

# ==================================================================
#  环境检测函数
# ==================================================================

function Invoke-EnvironmentCheck {
    Write-Host ""
    Write-Host "========== WSL2 环境检测 ==========" -ForegroundColor Cyan
    Write-Host ""

    # 操作系统
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    Write-Host "[操作系统]   $($os.Caption) $($os.Version)"

    # CPU 虚拟化
    $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
    if ($processors.Count -gt 0) {
        $vtOk = ($processors | Where-Object { -not $_.VirtualizationFirmwareEnabled }).Count -eq 0
        if ($vtOk) {
            Write-Host "[CPU虚拟化]  已启用" -ForegroundColor Green
        } else {
            Write-Host "[CPU虚拟化]  未启用 (需在 BIOS/UEFI 中开启 Intel VT-x 或 AMD-V)" -ForegroundColor Red
        }
    } else {
        Write-Host "[CPU虚拟化]  无法检测" -ForegroundColor Yellow
    }

    # Windows 功能
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -ErrorAction SilentlyContinue
    $vmFeature  = Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -ErrorAction SilentlyContinue

    $wslState = if ($wslFeature) { $wslFeature.State } else { "未知" }
    $vmState  = if ($vmFeature)  { $vmFeature.State }  else { "未知" }
    $wslColor = if ($wslState -eq "Enabled") { "Green" } else { "Gray" }
    $vmColor  = if ($vmState  -eq "Enabled") { "Green" } else { "Gray" }
    Write-Host "[WSL功能]    Microsoft-Windows-Subsystem-Linux : $wslState" -ForegroundColor $wslColor
    Write-Host "[VM功能]     VirtualMachinePlatform : $vmState" -ForegroundColor $vmColor

    # wsl.exe & 发行版
    $wslExe = Get-WslExePath
    if ($wslExe) {
        $wslVersion = (& $wslExe --version 2>$null | Select-Object -First 1)
        $wslVersion = ($wslVersion -replace "`0","").Trim()
        if ($wslVersion) {
            Write-Host "[WSL版本]    $wslVersion" -ForegroundColor Green
        } else {
            Write-Host "[WSL版本]    wsl.exe 存在但无法获取版本 (可能需要重启)" -ForegroundColor Yellow
        }

        $distros = @(Get-InstalledDistroNames -WslExe $wslExe)
        if ($distros.Count -gt 0) {
            Write-Host "[已装发行版] $($distros.Count) 个:" -ForegroundColor Green
            foreach ($d in $distros) { Write-Host "               - $d" }
        } else {
            Write-Host "[已装发行版] 无"
        }
    } else {
        Write-Host "[wsl.exe]    未找到 (WSL 功能可能未启用或未重启)" -ForegroundColor Gray
    }

    # 离线安装包
    $scriptRoot = Get-ScriptRoot
    $msiFiles = @(Get-ChildItem -Path (Join-Path $scriptRoot "packages\wsl*.msi") -ErrorAction SilentlyContinue)
    $imageFiles = @(Get-ChildItem -Path (Join-Path $scriptRoot "images\*.tar*") -ErrorAction SilentlyContinue)
    $msiStatus = if ($msiFiles.Count -gt 0)   { "$($msiFiles[0].Name)" }       else { "未找到" }
    $imgStatus = if ($imageFiles.Count -gt 0) { "$($imageFiles[0].Name)" }     else { "未找到" }
    $msiColor  = if ($msiFiles.Count -gt 0)   { "Green" }                      else { "Gray" }
    $imgColor  = if ($imageFiles.Count -gt 0) { "Green" }                      else { "Gray" }
    Write-Host "[WSL安装包]  $msiStatus" -ForegroundColor $msiColor
    Write-Host "[发行版镜像] $imgStatus" -ForegroundColor $imgColor

    # 磁盘空间
    $defaultRoot = Join-Path $env:LOCALAPPDATA "WSL"
    $freeGB = Get-DiskFreeGB -Path $defaultRoot
    if ($null -ne $freeGB) {
        $freeColor = if ($freeGB -ge 5) { "Green" } else { "Red" }
        Write-Host "[磁盘空间]   C: 盘剩余 $freeGB GB (默认安装路径: $defaultRoot)" -ForegroundColor $freeColor
    }

    # 综合判断
    Write-Host ""
    $featuresReady = ($wslState -eq "Enabled" -and $vmState -eq "Enabled")
    if ($featuresReady -and $wslExe -and $distros.Count -gt 0) {
        Write-Host "结论: WSL2 已安装并正常运行。" -ForegroundColor Green
    } elseif ($featuresReady -and $wslExe) {
        $pkgReady = ($msiFiles.Count -gt 0 -and $imageFiles.Count -gt 0)
        if ($pkgReady) {
            Write-Host "结论: WSL 功能已就绪，可以直接安装发行版。" -ForegroundColor Green
        } else {
            Write-Host "结论: WSL 功能已就绪，但缺少离线安装包。" -ForegroundColor Yellow
        }
    } elseif (-not $featuresReady) {
        $pkgReady = ($msiFiles.Count -gt 0 -and $imageFiles.Count -gt 0)
        if ($pkgReady) {
            Write-Host "结论: 需要启用 WSL 功能后重启，离线安装包已就绪。" -ForegroundColor Yellow
        } else {
            Write-Host "结论: WSL 尚未配置，请先确保离线安装包存在。" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "===================================" -ForegroundColor Cyan
}

# ==================================================================
#  主菜单
# ==================================================================

function Show-Menu {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "             WSL2 离线安装管理工具" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] 安装 WSL2  (启用功能 -> 安装内核 -> 导入发行版)"
    Write-Host "  [2] 卸载 WSL2  (注销发行版 -> 移除组件 -> 禁用功能)"
    Write-Host "  [3] 检测环境   (查看当前 WSL 状态和安装包情况)"
    Write-Host ""
    Write-Host "  [0] 退出"
    Write-Host ""

    while ($true) {
        $choice = (Read-Host "请选择操作").Trim()
        switch ($choice) {
            "1" { return "Install" }
            "2" { return "Uninstall" }
            "3" { return "Check" }
            "0" { return "Exit" }
            default { Write-Host "  无效选择，请输入 0-3" -ForegroundColor Red }
        }
    }
}

# ==================================================================
#  入口
# ==================================================================

$resolvedAction = $Action
if (-not $resolvedAction) {
    $resolvedAction = Show-Menu
}

switch ($resolvedAction) {
    "Install"   { Invoke-WslInstall }
    "Uninstall" { Invoke-WslUninstall }
    "Check"     { Invoke-EnvironmentCheck }
    "Exit"      { Write-Host "已退出。" }
}
