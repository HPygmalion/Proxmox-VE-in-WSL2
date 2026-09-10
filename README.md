[English](README.en.md) | 简体中文

# Proxmox VE in WSL2

在 Windows 11 的 WSL2 中运行 Proxmox VE 9.2，基于 Debian 13 (Trixie)。

> 这是非官方、实验性质的项目，适用于个人实验、开发和迁移测试。不适用于生产环境、Ceph、HA 集群、物理网桥或关键业务。

## 支持版本

- Windows 11 + WSL2（需要硬件虚拟化和 `nestedVirtualization`）
- Debian 13 (Trixie)
- Proxmox VE 9.2
- KVM 与 LXC 会在安装时用一次性测试实际验证

## 安装内容

安装脚本会：

1. 检查 Windows 版本、硬件虚拟化和 WSL2。
2. 在 `%USERPROFILE%\.wslconfig` 中确保 `[wsl2] nestedVirtualization=true`。
3. 安装或复用 Debian WSL 发行版，并在其中启用 systemd。
4. 用指定主机名初始化干净的 PVE 节点。
5. 在 `pve-cluster` 启动前动态修正 `/etc/hosts`。
6. 添加 Proxmox VE 仓库并安装 PVE 9.2 + UEFI 固件。
7. 固定 `lxcfs` 的 WSL2 启动条件，启用并启动 PVE 服务。
8. 用 QEMU + `/dev/kvm` 实际启动一次来验证 KVM。
9. 用最新的 Alpine 模板创建一次性非特权 CT，启动成功后删除，验证 LXC。
10. 安装 Linux 侧健康检查 timer 和 Windows 登录自启动保活任务。

用户在安装过程中自行设置 root 密码。仓库不会存储或传输任何凭据。

## 快速开始

以管理员身份打开 PowerShell：

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
Invoke-WebRequest -Uri https://raw.githubusercontent.com/HPygmalion/Proxmox-VE-in-WSL2/main/scripts/Install-PVE.ps1 -OutFile Install-PVE.ps1
.\Install-PVE.ps1
```

或克隆仓库运行：

```powershell
git clone https://github.com/HPygmalion/Proxmox-VE-in-WSL2.git
cd Proxmox-VE-in-WSL2
Set-ExecutionPolicy Bypass -Scope Process -Force
.\scripts\Install-PVE.ps1
```

### 默认参数

- WSL 发行版名：`PVE`
- 安装路径：`%LOCALAPPDATA%\WSL\PVE`
- PVE 主机名：`pve-lab`
- 镜像源：清华 `pve-no-subscription`

### 可选参数

```powershell
# 使用官方源
.\scripts\Install-PVE.ps1 -Mirror official

# 自定义主机名和安装路径
.\scripts\Install-PVE.ps1 -DistroName PVE -InstallPath "$env:LOCALAPPDATA\WSL\PVE" -Hostname pve-lab

# 不安装 Windows 侧保活任务
.\scripts\Install-PVE.ps1 -SkipKeepAlive

# 即使 /dev/kvm 缺失也继续安装（只跑 LXC）
.\scripts\Install-PVE.ps1 -AllowMissingKvm

# 删除安装过程中使用的 Debian 源发行版
.\scripts\Install-PVE.ps1 -RemoveSourceDebian
```

如果本机已有名为 `Debian` 的发行版，脚本默认会保留它，只把它导出为新的 `PVE` 发行版。

## 自动启动与保活

安装脚本会同时配置两侧：

- Linux 侧：`pve-wsl-healthcheck.timer` 每 60 秒检查 `pve-cluster`、`pvestatd`、`pvedaemon`、`pveproxy`、`pve-guests`、`lxcfs`，必要时启动服务；API 不可用时重启 API 服务。
- Windows 侧：计划任务 `WSL-PVE-Supervisor` 在登录后启动隐藏的 `wsl.exe` 会话，保持 WSL2 发行版运行；进程退出后自动重启。

单独安装或修复保活：

```powershell
.\scripts\Enable-PVEKeepAlive.ps1 -DistroName PVE
```

已有安装如果缺少 `/dev/kvm`，可以显式打开嵌套虚拟化（会重启 WSL）：

```powershell
.\scripts\Enable-PVEKeepAlive.ps1 -DistroName PVE -EnableNestedVirtualization
```

卸载保活：

```powershell
.\scripts\Enable-PVEKeepAlive.ps1 -DistroName PVE -Uninstall
```

## 访问 PVE Web UI

安装完成后打开：

```text
https://localhost:8006
```

- 用户名：`root`
- 密码：安装过程中设置的密码
- 认证领域：`Linux PAM`

## 验证结果

脚本会验证：

- PVE 所有核心服务 `active`。
- `systemctl --failed` 无失败单元。
- QEMU 能以 `-accel kvm` 实际启动并正常退出。
- 启动一个一次性 Alpine CT 并确认可运行后删除。
- Web UI 可通过 `localhost:8006` 访问。
- Windows 保活计划任务已注册并启动。

## 重要限制

- WSL2 的网络是 NAT。虚拟机和容器需要单独配置 `vmbr0` 和 NAT 才能联网。
- WSL2 PVE 不等价于裸机 PVE，不支持 Ceph、HA、物理网卡直通。
- WSL 内核由 Microsoft 提供，不是 PVE 内核。
- KVM 依赖 Windows 硬件虚拟化和 `[wsl2] nestedVirtualization=true`；修改 `.wslconfig` 后需要 `wsl --shutdown` 才能生效。
- 遇到启动异常，先执行 `wsl --shutdown` 后重试。

## 备份与恢复

导出：

```powershell
wsl --shutdown
wsl --export PVE "$env:USERPROFILE\PVE-Backups\PVE-golden.tar"
```

恢复：

```powershell
wsl --unregister PVE
wsl --import PVE "$env:LOCALAPPDATA\WSL\PVE" "$env:USERPROFILE\PVE-Backups\PVE-golden.tar" --version 2
wsl --set-default PVE
```

## 许可证

MIT。详见 [LICENSE](LICENSE)。

Proxmox VE 是 Proxmox Server Solutions GmbH 的商标。本项目独立，不隶属于 Proxmox。
