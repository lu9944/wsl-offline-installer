# Prompt for the Linux distribution installation path from the user
$LinuxDistroPath = Read-Host "Please provide the path to the Linux distribution Appx file (e.g., Ubuntu.appx)"

# Identify the operating system
$osInfo = Get-WmiObject -Class Win32_OperatingSystem
$osCaption = $osInfo.Caption

Write-Host "Detected OS: $osCaption"

switch -Wildcard ($osCaption) {
    "*Windows Server 2019*" {
        Install-WindowsFeature -Name Microsoft-Windows-Subsystem-Linux
        Install-WindowsFeature -Name VirtualMachinePlatform -IncludeManagementTools
    }
    "*Windows Server 2022*" {
        Install-WindowsFeature -Name Microsoft-Windows-Subsystem-Linux
        Install-WindowsFeature -Name VirtualMachinePlatform -IncludeManagementTools
    }
    "*Windows 10*" {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
    }
    "*Windows 11*" {
        wsl --install
    }
    default {
        Write-Host "This script supports only Windows Server 2019, 2022, Windows 10 or 11." -ForegroundColor Red
        exit 1
    }
}

# Save path to a temporary script for running after reboot
$TempFile = "$env:TEMP\wsl_install_temp.ps1"

$script = @"
param (
    [string]`$LinuxDistroPath
)

# Install the Linux distribution
Add-AppxPackage -Path `"`$LinuxDistroPath`"

# Extract file name without extension
\$distroBaseName = [System.IO.Path]::GetFileNameWithoutExtension(`$LinuxDistroPath)

# Get Appx package name by matching the base file name
\$distroName = (Get-AppxPackage | Where-Object { \$_ .Name -match \$distroBaseName }).Name

if ([string]::IsNullOrWhiteSpace(\$distroName)) {
    Write-Host "Unable to determine installed distro name. Skipping WSL version setup." -ForegroundColor Yellow
} else {
    # Attempt to upgrade to WSL 2
    if (\$distroName -match "Ubuntu|Debian|Kali|openSUSE|SLES") {
        Write-Host "Upgrading \$distroName to WSL 2..."
        wsl --set-version \$distroName 2
    } else {
        Write-Host "Distro \$distroName may not support WSL 2 or is not recognized."
    }

    # Set WSL 2 as the default for new installs
    wsl --set-default-version 2
}

# Clean up
Unregister-ScheduledTask -TaskName "WSLInstallTask" -Confirm:\$false -ErrorAction SilentlyContinue
Remove-Item "`$TempFile" -Force

Write-Host "Installation complete! WSL setup is done." -ForegroundColor Green
"@

# Write the script to file
$script | Out-File -FilePath $TempFile -Encoding UTF8 -Force

# Register task to run after reboot
$action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-ExecutionPolicy Bypass -File `"$TempFile`" -LinuxDistroPath `"$LinuxDistroPath`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "WSLInstallTask" -Action $action -Trigger $trigger -Principal $principal -Force

# Restart system
Write-Host "The system will restart in 10 seconds to complete installation..." -ForegroundColor Cyan
Start-Sleep -Seconds 10
Restart-Computer
