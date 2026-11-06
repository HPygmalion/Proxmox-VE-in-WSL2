English | [简体中文](README.md)

# Proxmox VE in WSL2

Run Debian 13 / Proxmox VE 9.x on Windows 11 WSL2. The installer configures systemd, hostname resolution, KVM/LXC support, guest NAT networking and login keep-alive.

> **Unofficial experimental project.** Intended for personal labs, development and migration tests, not production, Ceph, HA, physical bridging, passthrough or critical workloads. Packages follow the rolling PVE 9 repository; patch versions are not pinned.

## Quick start

1. Enable WSL2 on Windows 11 x86_64 with hardware virtualization. If needed, run `wsl --install --no-distribution` in an administrator terminal and reboot as directed.
2. Download/extract the **complete repository**, or clone it.
3. Double-click **`scripts/Start-PVE-Installer.cmd`**, or run:

```powershell
.\scripts\Install-PVE.ps1
```

4. Enter your chosen root password twice (hidden input). It is never generated, printed, saved or included in WSL command-line arguments.
5. Wait for installation, smoke checks and export/import; downloads may take tens of minutes.
6. Open **https://localhost:8006**, accept the self-signed certificate, and log in as `root` using your chosen password and PAM authentication.

Use the same Windows account that normally owns your WSL distributions. The full install generally does not need elevation. If Windows denies scheduled-task registration, retry keep-alive from an administrator PowerShell **as the same Windows user**; using another administrator account registers WSL elsewhere.

Initial WSL/BIOS enablement may need administrator rights and reboot. The installer cannot bypass these requirements. A standalone download of `Install-PVE.ps1` is not supported: sibling scripts are required.

## What is automated

- Validate names, paths, free disk space and guest subnet; refuse existing targets and nonempty install paths.
- Create a clean `<DistroName>-src` Debian build, without modifying an existing `Debian` distro.
- Configure systemd, default root user and authoritative dynamic node hostname mapping.
- Install PVE 9, UEFI firmware, KVM/LXC dependencies and the WSL lxcfs compatibility override.
- Enable no-subscription packages and disable package-provided enterprise subscription repositories.
- Create isolated `vmbr0`, IPv4 forwarding, NAT, DHCP and DNS (no physical NIC bridging).
- Start QEMU with KVM and create a disposable unprivileged Alpine CT; verify startup, gateway, internet and DNS, then remove the CT.
- Export/import the verified build, verify each core service and API, install keep-alive, then remove only the installer-owned source/transfer archive.

## Options

| Option | Default / purpose |
|---|---|
| `-DistroName` | `PVE` |
| `-InstallPath` | `%LOCALAPPDATA%\WSL\<DistroName>`; empty local directory |
| `-Hostname` | `pve-lab`; do not casually rename an initialized PVE node |
| `-Mirror` | `tsinghua` or `official` |
| `-NatSubnet` | `10.10.10.0/24`; valid RFC1918 private IPv4 `/24` only |
| `-NoNat` | Configure guest networking yourself |
| `-NoSetDefault` | Preserve the current default WSL distro |
| `-SkipKeepAlive` | Explicitly skip both keep-alive layers |
| `-AllowMissingKvm` | Allow LXC-only installation without `/dev/kvm`; does not promise working VMs |
| `-Resume` | Resume a recorded installer-owned build with the original options |
| `-UpdateWsl` | Explicitly update host WSL; no automatic host upgrade by default |
| `-ForceWslShutdown` | Allow global shutdown after editing `.wslconfig`; interrupts all WSL guests |
| `-RootPassword` | **SecureString** for unattended callers; unnecessary for normal interactive use |

```powershell
.\scripts\Install-PVE.ps1 -DistroName PVE-lab -InstallPath D:\WSL\PVE-lab -Hostname pve-lab -NatSubnet 10.20.30.0/24 -NoSetDefault
```

Password collection happens before installation. It is sent to `chpasswd` over stdin. Do not embed real plaintext passwords in command lines or scripts. Unattended callers should obtain SecureString credentials from their secret store; no terminal and no supplied password means failure, not a silently generated password.

## Guest networking

Defaults: `vmbr0`, gateway/DNS `10.10.10.1/24`, DHCP pool `10.10.10.100`–`10.10.10.200`. Connect CTs/VMs to `vmbr0`, use a virtio NIC for VMs, and enable DHCP inside the guest. Static addresses outside the pool also work if unused. Installing guest operating systems/applications is outside this installer's scope.

Conflicting routes require choosing another `-NatSubnet`. Reruns restore same-subnet state but never silently renumber an existing bridge. dnsmasq listens on the guest bridge, not WSL's DNS proxy at `10.255.255.254:53`.

Windows firewall/VPN/proxy policies can prevent internet access. The installer does not disable them. Blocked external ICMP can fail networking smoke checks; fix the network and resume.

## Keep-alive and maintenance

- Linux `pve-wsl-healthcheck.timer` checks services, hosts, NAT/DNS and API every minute. API HTTP 200/401 means ready. It never restarts `pve-guests` or running guests.
- Windows `WSL-<DistroName>-Supervisor` directly runs the WSL anchor under the current user's limited token; login and minute-retry triggers with `IgnoreNew` prevent duplicates.
- This is **after-login keep-alive**, not a pre-login Windows service. Windows sleep/reboot/shutdown still stops workloads.

Repair keep-alive installed by this version:

```powershell
.\scripts\Enable-PVEKeepAlive.ps1 -DistroName PVE
```

Old/unrelated same-name tasks are not overwritten. Inspect and remove/disable the old task first, or explicitly choose another `-TaskName`. Do not leave two supervisors for one distro.

Before maintenance, disable the task so it does not restart the distro:

```powershell
Disable-ScheduledTask -TaskName WSL-PVE-Supervisor
```

Gracefully shut down guests, stop the task, then terminate the specific distro. After maintenance:

```powershell
Enable-ScheduledTask -TaskName WSL-PVE-Supervisor
Start-ScheduledTask -TaskName WSL-PVE-Supervisor
```

Remove this version's keep-alive without deleting PVE/guests:

```powershell
.\scripts\Enable-PVEKeepAlive.ps1 -DistroName PVE -Uninstall
```

## Failure recovery and limits

Failures return nonzero and name the stage. The build/transfer archive is preserved for diagnosis. Resume a pre-import build using the original options:

```powershell
.\scripts\Install-PVE.ps1 -DistroName PVE-lab -InstallPath D:\WSL\PVE-lab -Hostname pve-lab -NatSubnet 10.20.30.0/24 -NoSetDefault -Resume
```

If target import succeeded but final validation/keep-alive failed, keep that target. For a target recorded by this installer as imported, `-Resume` retries only final validation/keep-alive without reimporting or resetting the password. All unrelated existing targets remain protected.

- WSL2 distros share host kernel/network resources: do not run two PVE distros simultaneously (ports 8006/85/3128, bridges and guest subnets collide). Stop existing PVE and its supervisor before installing a test instance.
- `.wslconfig` is global. Running distros are not implicitly shut down; perform maintenance or explicitly permit `-ForceWslShutdown`.
- The running kernel is Microsoft's, not the installed Proxmox kernel under `/boot`.
- Debian creation depends on Microsoft's distro catalog/image host. `--web-download` is a fallback, not a universal bypass for network problems.
- No Ceph/HA/physical bridging/PCI/GPU passthrough or production support is claimed.

## Backup

Disable keep-alive, gracefully stop guests, then stop the **specific** distro. Ensure the destination directory exists:

```powershell
wsl --terminate PVE
wsl --export PVE D:\PVE-Backups\PVE-golden.tar
```

Export success is not a restore test. `/etc/pve` is a runtime mount backed by `/var/lib/pve-cluster/config.db`; guest disks on other storage need separate backups. **`wsl --unregister` permanently deletes the distro and locally stored guest disks.** Never run it without verified backups.

## Development tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Helpers.ps1
```

```bash
bash tests/bootstrap-pve.test.sh
```

These isolated tests do not install PVE. See [VALIDATION.md](VALIDATION.md) for real Windows/WSL acceptance scope and remaining limits.

## License

MIT; see [LICENSE](LICENSE). Proxmox VE is a trademark of Proxmox Server Solutions GmbH. This independent project is not affiliated with Proxmox.
