# Proxmox VE in WSL2

在 Windows 11 的 WSL2 中运行 Proxmox VE 9.2，基于 Debian 13 (Trixie)。

> 这是非官方、实验性质的项目，适用于个人实验、开发和迁移测试。不适用于生产环境、Ceph、HA 集群、物理网桥或关键业务。

## 支持版本

- Windows 11 + WSL2
- Debian 13 (Trixie)
- Proxmox VE 9.2
- KVM 和 LXC 已实际验证，但依赖 Windows 虚拟化与 WSL 版本。

## 安装内容

安装脚本会：

1. 检查 Windows 虚拟化和 WSL2。
2. 安装或验证 Debian 13 WSL 发行版。
3. 启用 WSL systemd。
4. 用用户指定的主机名创建干净的 PVE 节点。
5. 在 `pve-cluster` 启动前动态修正 `/etc/hosts`。
6. 添加 Proxmox VE 仓库并安装 PVE 9.2 + UEFI 固件。
7. 启用 `lxcfs`，适配 WSL2 容器环境。
8. 验证 PVE Web UI、KVM、LXC。

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
- 安装路径：`D:\WSL\PVE`
- PVE 主机名：`HPygmalion`
- 镜像源：清华 `pve-no-subscription`

### 使用官方源

```powershell
.\scripts\Install-PVE.ps1 -Mirror official
```

### 自定义主机名和路径

```powershell
.\scripts\Install-PVE.ps1 -DistroName PVE -InstallPath D:\WSL\PVE -Hostname pve-lab -Mirror tsinghua
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
- `systemctl --failed` 无输出。
- `/dev/kvm` 存在。
- 启动一个一次性 Alpine CT 并确认可运行后删除。
- Web UI 可通过 `localhost:8006` 访问。

## 重要限制

- WSL2 的网络是 NAT。虚拟机和容器需要单独配置 `vmbr0` 和 NAT 才能联网。
- WSL2 PVE 不等价于裸机 PVE，不支持 Ceph、HA、物理网卡直通。
- WSL 内核由 Microsoft 提供，不是 PVE 内核。
- 遇到启动异常，先执行 `wsl --shutdown` 后重试。

## 备份与恢复

导出：

```powershell
wsl --shutdown
wsl --export PVE D:\PVE-Backups\PVE-golden.tar
```

恢复：

```powershell
wsl --unregister PVE
wsl --import PVE "D:\WSL\PVE" "D:\PVE-Backups\PVE-golden.tar" --version 2
wsl --set-default PVE
```

## 许可证

MIT。详见 [LICENSE](LICENSE)。

Proxmox VE 是 Proxmox Server Solutions GmbH 的商标。本项目独立，不隶属于 Proxmox。
