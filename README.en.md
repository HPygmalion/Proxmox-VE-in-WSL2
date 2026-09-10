[English](README.en.md) | [简体中文](README.md)

# Proxmox VE in WSL2

Run Proxmox VE 9.2 inside Windows 11 WSL2 using Debian 13 (Trixie).

> This is an unofficial, experimental setup for personal labs, development and migration testing. It is not suitable for production, Ceph, HA clusters, physical bridging, or critical workloads.

## Supported versions

- Windows 11 with WSL2 (hardware virtualization and `nestedVirtualization` required)
- Debian 13 (Trixie)
- Proxmox VE 9.2
- KVM and LXC are both exercised by disposable smoke tests during installation

## What this does

The installer:

1. Checks the Windows version, hardware virtualization and WSL2.
2. Ensures `[wsl2] nestedVirtualization=true` in `%USERPROFILE%\.wslconfig`.
3. Installs or reuses a Debian WSL distro and enables systemd inside it.
4. Creates a clean PVE node with the requested hostname.
5. Fixes `/etc/hosts` dynamically before `pve-cluster` starts.
6. Adds the Proxmox VE repository and installs PVE 9.2 with UEFI firmware.
7. Normalizes the `lxcfs` start condition for WSL2, then enables the PVE services.
8. Starts a disposable QEMU process with `-accel kvm` to prove KVM works.
9. Creates a disposable unprivileged Alpine CT and removes it again to prove LXC works.
10. Installs a Linux health-check timer and a Windows logon keep-alive task.

The root password is set interactively. The repository never stores or transmits credentials.

## Quick start

Run PowerShell as Administrator:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
Invoke-WebRequest -Uri https://raw.githubusercontent.com/HPygmalion/Proxmox-VE-in-WSL2/main/scripts/Install-PVE.ps1 -OutFile Install-PVE.ps1
.\Install-PVE.ps1
```

Or clone the repository:

```powershell
git clone https://github.com/HPygmalion/Proxmox-VE-in-WSL2.git
cd Proxmox-VE-in-WSL2
Set-ExecutionPolicy Bypass -Scope Process -Force
.\scripts\Install-PVE.ps1
```

### Default parameters

- WSL distro name: `PVE`
- Install location: `%LOCALAPPDATA%\WSL\PVE`
- PVE hostname: `pve-lab`
- Proxmox mirror: Tsinghua `pve-no-subscription`

### Optional parameters

```powershell
# Use the official Proxmox mirror
.\scripts\Install-PVE.ps1 -Mirror official

# Custom distro name, install path and hostname
.\scripts\Install-PVE.ps1 -DistroName PVE -InstallPath "$env:LOCALAPPDATA\WSL\PVE" -Hostname pve-lab

# Do not register the Windows keep-alive task
.\scripts\Install-PVE.ps1 -SkipKeepAlive

# Continue even when /dev/kvm is missing (LXC only)
.\scripts\Install-PVE.ps1 -AllowMissingKvm

# Also remove the source Debian distro after the import
.\scripts\Install-PVE.ps1 -RemoveSourceDebian
```

If a distro named `Debian` already exists, it is reused and kept registered by default; the installer only exports it into the new `PVE` distro.

## Autostart and keep-alive

The installer configures both sides:

- Linux: `pve-wsl-healthcheck.timer` checks `pve-cluster`, `pvestatd`, `pvedaemon`, `pveproxy`, `pve-guests` and `lxcfs` every 60 seconds, starts anything inactive, and restarts the API services if the local API is unavailable.
- Windows: the scheduled task `WSL-PVE-Supervisor` starts a hidden `wsl.exe` session at logon and restarts it if the process exits, so the WSL2 distro stays up.

Install or repair the keep-alive on an existing installation:

```powershell
.\scripts\Enable-PVEKeepAlive.ps1 -DistroName PVE
```

If `/dev/kvm` is missing, explicitly enable nested virtualization (this restarts WSL):

```powershell
.\scripts\Enable-PVEKeepAlive.ps1 -DistroName PVE -EnableNestedVirtualization
```

Remove the keep-alive:

```powershell
.\scripts\Enable-PVEKeepAlive.ps1 -DistroName PVE -Uninstall
```

## Access PVE

After installation, open:

```text
https://localhost:8006
```

Login:

- Username: `root`
- Password: set during installation
- Realm: `Linux PAM`

## Verification

The scripts verify:

- All core PVE services are `active`.
- `systemctl --failed` reports no failed units.
- QEMU can actually start with `-accel kvm` and exit cleanly.
- A disposable Alpine CT starts successfully and is then removed.
- The Web UI is reachable on `localhost:8006`.
- The Windows keep-alive scheduled task is registered and started.

## Important limitations

- WSL2 networking uses NAT. VMs and containers need separate `vmbr0` and NAT configuration.
- This setup is not equivalent to bare-metal PVE. Do not enable Ceph, HA, or production workloads.
- WSL kernels are provided by Microsoft, not Proxmox.
- KVM depends on Windows hardware virtualization and `[wsl2] nestedVirtualization=true`; `.wslconfig` changes require `wsl --shutdown` to take effect.
- If services fail to start, run `wsl --shutdown` and retry.

## Backup and restore

Export:

```powershell
wsl --shutdown
wsl --export PVE "$env:USERPROFILE\PVE-Backups\PVE-golden.tar"
```

Restore:

```powershell
wsl --unregister PVE
wsl --import PVE "$env:LOCALAPPDATA\WSL\PVE" "$env:USERPROFILE\PVE-Backups\PVE-golden.tar" --version 2
wsl --set-default PVE
```

## License

MIT. See [LICENSE](LICENSE).

Proxmox VE is a trademark of Proxmox Server Solutions GmbH. This project is independent and not affiliated with Proxmox.
