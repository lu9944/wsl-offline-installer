[CmdletBinding()]
param(
    [switch]$Restart
)

$ErrorActionPreference = "Stop"
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$step1 = Join-Path $scriptRoot "01-Enable-WSL2.ps1"

Write-Host "This project now installs WSL2 offline with two explicit steps:" -ForegroundColor Yellow
Write-Host "  1. Run 01-Enable-WSL2.ps1 as Administrator."
Write-Host "  2. Restart if requested, then run 02-Install-WSL2-And-Distro.ps1."
Write-Host ""

if (-not (Test-Path $step1)) {
    throw "Cannot find $step1"
}

& $step1 -Restart:$Restart
