[CmdletBinding()]
param(
    [string]$DistroName = "Ubuntu-24.04",
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "WSL"),
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
        throw "Cannot find $Description. Expected one of: $($Patterns -join ', ')"
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

    throw "wsl.exe was not found. Run 01-Enable-WSL2.ps1 first and restart Windows if requested."
}

function Install-WslPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()

    switch ($extension) {
        ".msi" {
            Write-Host "Installing WSL package: $Path"
            $arguments = @("/i", "`"$Path`"", "/passive", "/norestart")
            if (Test-IsAdministrator) {
                $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru
            } else {
                $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Verb RunAs -Wait -PassThru
            }

            if ($process.ExitCode -notin @(0, 3010)) {
                throw "WSL MSI installer failed with exit code $($process.ExitCode)."
            }
        }
        ".msixbundle" {
            Write-Host "Installing WSL package: $Path"
            Add-AppxPackage -Path $Path -ForceApplicationShutdown
        }
        ".appxbundle" {
            Write-Host "Installing WSL package: $Path"
            Add-AppxPackage -Path $Path -ForceApplicationShutdown
        }
        default {
            throw "Unsupported WSL installer extension: $extension"
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

    Write-Host "Expanding gzip image to temporary tar: $targetPath"
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
    return @($output | ForEach-Object { $_.Trim([char]0x00).Trim() } | Where-Object { $_ })
}

$scriptRoot = Get-ScriptRoot

if (-not $WslInstallerPath) {
    $WslInstallerPath = Resolve-PackageFile -Description "WSL installer package" -Patterns @(
        (Join-Path $scriptRoot "packages\wsl*.msi"),
        (Join-Path $scriptRoot "packages\Microsoft.WSL*.msixbundle"),
        (Join-Path $scriptRoot "packages\*.msixbundle"),
        (Join-Path $scriptRoot "packages\*.appxbundle")
    )
}

if (-not $ImagePath) {
    $ImagePath = Resolve-PackageFile -Description "Linux rootfs image" -Patterns @(
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
    throw "Unable to set WSL 2 as the default version. Confirm that Step 1 completed and Windows was restarted if required."
}

$existingDistros = @(Get-InstalledDistroNames -WslExe $wslExe)
if ($existingDistros -contains $DistroName) {
    if (-not $Force) {
        Write-Host "Distro '$DistroName' is already installed. Use -Force to unregister and import it again." -ForegroundColor Yellow
        & $wslExe --set-version $DistroName 2
        & $wslExe --set-default $DistroName
        exit 0
    }

    Write-Host "Unregistering existing distro: $DistroName"
    & $wslExe --unregister $DistroName
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to unregister existing distro '$DistroName'."
    }
}

$distroInstallPath = Join-Path $InstallRoot $DistroName
New-Item -ItemType Directory -Path $distroInstallPath -Force | Out-Null

$imageForImport = Expand-GzipImage -Path $ImagePath
$removeExpandedImage = $imageForImport -ne $ImagePath

try {
    Write-Host "Importing distro '$DistroName' to $distroInstallPath"
    & $wslExe --import $DistroName $distroInstallPath $imageForImport --version 2
    if ($LASTEXITCODE -ne 0) {
        throw "WSL import failed with exit code $LASTEXITCODE."
    }
} finally {
    if ($removeExpandedImage -and (Test-Path $imageForImport)) {
        Remove-Item -Path $imageForImport -Force
    }
}

& $wslExe --set-default $DistroName
& $wslExe --shutdown

Write-Host ""
Write-Host "Installation complete. Start Linux with: wsl -d $DistroName" -ForegroundColor Green
