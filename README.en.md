[English](README.md) | [简体中文](README.md)

# Proxmox VE in WSL2

Run Proxmox VE 9.2 inside Windows 11 WSL2 using Debian 13 (Trixie).

> This is an unofficial, experimental setup for personal labs, development and migration testing. It is not suitable for production, Ceph, HA clusters, physical bridging, or critical workloads.

## Supported versions

- Windows 11 with WSL2
- Debian 13 (Trixie)
- Proxmox VE 9.2
- KVM and LXC are tested, but depend on Windows virtualization and WSL version.

## What this does

The installer:

1. Checks Windows virtualization and WSL2.
2. Installs or verifies Debian 13 from the WSL Store.
3. Enables WSL systemd.
4. Creates a clean PVE node with a user-chosen hostname.
5. Fixes `/etc/hosts` dynamically before `pve-cluster` starts.
6. Adds the Proxmox VE repository and installs PVE 9.2 with UEFI firmware.
7. Enables `lxcfs` for the WSL container environment.
8. Verifies PVE Web UI, KVM, and LXC basics.

The user sets the root password interactively. The repository never stores credentials.

## Quick start

Run PowerShell as Administrator and execute:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
Invoke-WebRequest -Uri https://raw.githubusercontent.com/HPygmalion/Proxmox-VE-in-WSL2/main/scripts/Install-PVE.ps1 -OutFile Install-PVE.ps1
.\Install-PVE.ps1
```

Or clone the repository and run locally:

```powershell
git clone https://github.com/HPygmalion/Proxmox-VE-in-WSL2.git
cd Proxmox-VE-in-WSL2
Set-ExecutionPolicy Bypass -Scope Process -Force
.\scripts\Install-PVE.ps1
```

Default parameters:

- WSL distro name: `PVE`
- Install location: `D:\WSL\PVE`
- PVE hostname: `HPygmalion`
- Proxmox mirror: Tsinghua `pve-no-subscription`

You can override them:

```powershell
.\scripts\Install-PVE.ps1 -DistroName PVE -InstallPath D:\WSL\PVE -Hostname pve-lab
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

## Important limitations

- WSL2 networking uses NAT. VMs and containers need separate `vmbr0` and NAT configuration.
- This setup is not equivalent to bare-metal PVE.
- Do not enable Ceph, HA, or production workloads.
- WSL kernels are provided by Microsoft, not Proxmox.
- Start/stop services may need a `wsl --shutdown` between reboots.

## Backup and restore

Export:

```powershell
wsl --shutdown
wsl --export PVE D:\PVE-Backups\PVE-golden.tar
```

Restore:

```powershell
wsl --unregister PVE
wsl --import PVE "D:\WSL\PVE" "D:\PVE-Backups\PVE-golden.tar" --version 2
wsl --set-default PVE
```

## License

MIT. See [LICENSE](LICENSE).

Proxmox VE is a trademark of Proxmox Server Solutions GmbH. This project is independent and not affiliated with Proxmox.


