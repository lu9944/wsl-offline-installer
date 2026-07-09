[CmdletBinding()]
param(
    [string]$DistroName = "Ubuntu-24.04",
    [string]$InstallRoot,
    [string]$ImagePath,
    [string]$WslInstallerPath,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Get-ScriptRoot {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }

    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-PackageFile {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $matches = @()
    foreach ($pattern in $Patterns) {
        $matches += @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)
    }

    $matches = @($matches | Sort-Object -Property LastWriteTimeUtc -Descending)
    if ($matches.Count -eq 0) {
        throw "找不到 $Description。预期路径之一: $($Patterns -join ', ')"
    }

    return $matches[0].FullName
}

function Get-WslExePath {
    $path = Join-Path $env:WINDIR "System32\wsl.exe"
    if (Test-Path $path) {
        return $path
    }

    $sysnative = Join-Path $env:WINDIR "Sysnative\wsl.exe"
    if (Test-Path $sysnative) {
        return $sysnative
    }

    throw "未找到 wsl.exe。请先运行 01-Enable-WSL2.ps1，如提示重启请先重启。"
}

function Install-WslPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()

    switch ($extension) {
        ".msi" {
            Write-Host "正在安装 WSL 包: $Path"
            $arguments = @("/i", "`"$Path`"", "/passive", "/norestart")
            if (Test-IsAdministrator) {
                $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru
            } else {
                $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Verb RunAs -Wait -PassThru
            }

            if ($process.ExitCode -notin @(0, 3010)) {
                throw "WSL MSI 安装程序失败，退出码 $($process.ExitCode)。"
            }
        }
        ".msixbundle" {
            Write-Host "正在安装 WSL 包: $Path"
            Add-AppxPackage -Path $Path -ForceApplicationShutdown
        }
        ".appxbundle" {
            Write-Host "正在安装 WSL 包: $Path"
            Add-AppxPackage -Path $Path -ForceApplicationShutdown
        }
        default {
            throw "不支持的 WSL 安装包格式: $extension"
        }
    }
}

function Expand-GzipImage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not $Path.EndsWith(".gz", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path
    }

    $targetName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $targetPath = Join-Path $env:TEMP $targetName

    if (Test-Path $targetPath) {
        Remove-Item -Path $targetPath -Force
    }

    Write-Host "正在解压 gzip 镜像到临时 tar 文件: $targetPath"
    $inputStream = [System.IO.File]::OpenRead($Path)
    try {
        $gzipStream = [System.IO.Compression.GzipStream]::new($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $outputStream = [System.IO.File]::Create($targetPath)
            try {
                $gzipStream.CopyTo($outputStream)
            } finally {
                $outputStream.Dispose()
            }
        } finally {
            $gzipStream.Dispose()
        }
    } finally {
        $inputStream.Dispose()
    }

    return $targetPath
}

function Get-InstalledDistroNames {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslExe
    )

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
& $wslExe --set-default-version 2
if ($LASTEXITCODE -ne 0) {
    throw "无法将 WSL 2 设置为默认版本。请确认第一步已完成，并在需要时重启了 Windows。"
}

$existingDistros = @(Get-InstalledDistroNames -WslExe $wslExe)
if ($existingDistros -contains $DistroName) {
    if (-not $Force) {
        Write-Host "发行版 '$DistroName' 已安装。使用 -Force 参数可注销并重新导入。" -ForegroundColor Yellow
        & $wslExe --set-version $DistroName 2
        & $wslExe --set-default $DistroName
        exit 0
    }

    Write-Host "正在注销已存在的发行版: $DistroName"
    & $wslExe --unregister $DistroName
    if ($LASTEXITCODE -ne 0) {
        throw "无法注销已存在的发行版 '$DistroName'。"
    }
}

# === 确定安装位置 ==================================================
if (-not $InstallRoot) {
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

        if (-not $userInput) {
            $InstallRoot = $defaultRoot
            break
        }

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

        $InstallRoot = $userInput
        break
    }
}

$freeGB = Get-DiskFreeGB -Path $InstallRoot
if ($null -ne $freeGB) {
    Write-Host "安装位置: $InstallRoot  (剩余 $freeGB GB)" -ForegroundColor Green
    if ($freeGB -lt 5) {
        Write-Warning "目标盘空间不足 (剩余 $freeGB GB)。WSL 发行版会快速增大。"
    }
} else {
    Write-Host "安装位置: $InstallRoot" -ForegroundColor Green
}

$distroInstallPath = Join-Path $InstallRoot $DistroName
New-Item -ItemType Directory -Path $distroInstallPath -Force | Out-Null

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

& $wslExe --set-default $DistroName
& $wslExe --shutdown

Write-Host ""
Write-Host "安装完成。使用以下命令启动 Linux: wsl -d $DistroName" -ForegroundColor Green
