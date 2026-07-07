# WSL2 Offline Installer

This repository builds a release-ready offline WSL2 installer package with GitHub Actions.
The generated zip contains:

- WSL2 installer package from the latest `microsoft/WSL` release.
- Ubuntu 24.04 WSL rootfs image.
- Two explicit install scripts for machines that require a reboot between feature enablement and distro import.
- An uninstall script that unregisters WSL distributions and disables WSL components.

## Build the Release Package

The workflow is defined in `.github/workflows/build-offline-package.yml`.

Manual build:

1. Open **Actions**.
2. Run **Build offline WSL2 package**.
3. Download the generated artifact.

Release build:

1. Create or publish a GitHub Release.
2. The workflow runs on the `release.published` event.
3. The generated zip is uploaded to that release.

Manual release upload:

1. Run the workflow manually.
2. Set `release_tag` to an existing release tag.
3. The generated zip is uploaded to that release.

The default package uses Ubuntu 24.04 x64. Workflow inputs can override the distro name, rootfs URL, package name, and WSL architecture.

## Offline Install

Download the release zip on a machine with internet access, move it to the offline Windows machine, and extract it.

Step 1, run as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\01-Enable-WSL2.ps1
```

If Windows asks for a restart, restart before running Step 2.

Step 2, run from the extracted package directory:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\02-Install-WSL2-And-Distro.ps1
```

The script installs the bundled WSL package, imports the bundled Linux rootfs as `Ubuntu-24.04`, sets WSL2 as the default version, and sets the imported distro as the default distro.

Start Linux after installation:

```powershell
wsl -d Ubuntu-24.04
```

To replace an existing distro with the same name:

```powershell
.\02-Install-WSL2-And-Distro.ps1 -Force
```

## Uninstall

Run as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Uninstall-WSL2.ps1
```

The script unregisters all WSL distributions for the current Windows user, removes the installed WSL package when it can be found, and disables `VirtualMachinePlatform` and `Microsoft-Windows-Subsystem-Linux`.

Use `-Force` to skip the confirmation prompt and `-Restart` to restart automatically when Windows requires it.

## Package Layout

```text
01-Enable-WSL2.ps1
02-Install-WSL2-And-Distro.ps1
Uninstall-WSL2.ps1
packages/
  wsl.*.msi
images/
  *.rootfs.tar.gz
manifest.json
SHA256SUMS
```

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
