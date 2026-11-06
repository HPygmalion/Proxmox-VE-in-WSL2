[English](README.en.md) | 简体中文

# Proxmox VE in WSL2

在 Windows 11 的 WSL2 中运行基于 Debian 13 的 Proxmox VE 9.x。安装器自动配置 systemd、主机名解析、KVM/LXC 支持、CT/VM 的 NAT 网络和登录保活。

> **非官方实验项目**，用于个人实验、开发和迁移测试。不是裸机 PVE 的替代品，不用于生产、Ceph、HA、物理网卡直通或关键业务。软件包来自滚动更新的 PVE 9 仓库，补丁版本不锁定。

## 最简单的安装方式

1. 安装并启用 Windows 的 WSL2；需要 Windows 11、x86_64 CPU、硬件虚拟化。若未安装，在管理员终端执行 `wsl --install --no-distribution`，按提示重启。
2. 下载并解压**完整仓库**，或 `git clone https://github.com/HPygmalion/Proxmox-VE-in-WSL2.git`。
3. 双击 **`scripts/Start-PVE-Installer.cmd`**，或者在 PowerShell 运行：

```powershell
.\scripts\Install-PVE.ps1
```

4. 按提示输入两次你自己选择的 root 密码。输入不回显，密码不会随机生成、显示、写入文件或放入 WSL 进程参数。
5. 等待安装、验证、导出/导入完成。下载和软件包安装可能需要数十分钟。
6. 打开 **https://localhost:8006**，接受自签名证书提示，用 `root`、你选择的密码，并选择 PAM 认证登录。

运行账户必须是你平时使用 WSL 的 Windows 用户。一般无需整段提权；若 Windows 拒绝计划任务注册，按错误提示在**同一个 Windows 用户**的管理员终端重试保活。不要切换到其他管理员账户安装：WSL 注册属于每个 Windows 用户。

首次启用 WSL/硬件虚拟化可能需要管理员权限、BIOS/UEFI 设置和重启；脚本无法绕过这些系统要求。不要只下载 `Install-PVE.ps1`：它需要同目录的辅助脚本。

## 自动完成什么

- 检查名称、路径、磁盘空间和网络子网；已有目标发行版或非空安装目录会被拒绝，不覆盖、不删除。
- 使用全新的 `<DistroName>-src` Debian 构建发行版，不借用你已有的 `Debian`。
- 配置 WSL systemd、默认 root 用户和动态 hostname→当前 IPv4 映射。
- 安装 PVE 9、UEFI 固件、KVM/LXC 依赖，适配 WSL 的 lxcfs 启动条件。
- 启用 no-subscription 软件源，禁用安装包附带的 enterprise 订阅源。
- 创建隔离 `vmbr0` 桥、IPv4 转发、NAT、DHCP/DNS；不把 Windows 物理网卡接入网桥。
- 实际启动 QEMU 验证 KVM，创建一次性非特权 Alpine CT，验证启动、网关、外网和 DNS，再删除测试 CT。
- 将验证后的构建导出并导入为目标发行版；检查 API 与各核心服务。
- 安装 Linux 服务健康检查和 Windows 当前用户登录/每分钟重试任务。
- 仅在目标验证完成后删除安装器创建的源发行版和传输归档。

## 默认值与参数

| 参数 | 默认值 / 用途 |
|---|---|
| `-DistroName` | `PVE` |
| `-InstallPath` | `%LOCALAPPDATA%\WSL\<DistroName>`，须为空的本地目录 |
| `-Hostname` | `pve-lab`，初始化后不要随意修改 PVE 节点名 |
| `-Mirror` | `tsinghua`；也可选 `official` |
| `-NatSubnet` | `10.10.10.0/24`，仅支持合法 RFC1918 私网 `/24` |
| `-NoNat` | 不配置 guest 网络，联网由你负责 |
| `-NoSetDefault` | 保留当前默认 WSL 发行版 |
| `-SkipKeepAlive` | 明确跳过两侧保活，不保证后台存活 |
| `-AllowMissingKvm` | 允许没有 `/dev/kvm` 的 LXC-only 安装，不代表 VM 可用 |
| `-Resume` | 续跑安装器记录过的构建，保留原安装参数，不重新下载整个系统 |
| `-UpdateWsl` | 显式更新 WSL；默认不升级宿主 WSL |
| `-ForceWslShutdown` | 允许修改 `.wslconfig` 后停止所有 WSL 发行版；会中断其 guest |
| `-RootPassword` | 无人值守时传 **SecureString**；正常使用无需传参 |

```powershell
.\scripts\Install-PVE.ps1 -DistroName PVE-lab -InstallPath D:\WSL\PVE-lab -Hostname pve-lab -NatSubnet 10.20.30.0/24 -NoSetDefault
```

密码在安装前收集并通过标准输入送入 `chpasswd`。不要把真实密码写成命令行明文或保存进脚本。无人值守调用方应从其凭据存储取得 SecureString；没有终端且没有提供密码时会失败，不会替用户设置随机密码。

## CT / VM 网络

默认：

- 桥：`vmbr0`，地址/网关：`10.10.10.1/24`。
- DHCP：`10.10.10.100`–`10.10.10.200`，DNS：`10.10.10.1`。
- CT 接入 `vmbr0`，IPv4 选择 DHCP；VM 使用 virtio 网卡接入 `vmbr0`，guest 内启用 DHCP。
- 无 DHCP 的 guest 可使用未被占用的静态地址、相同网关/DNS。创建/安装 guest OS 和其应用不是安装器的职责。

如果与已有路由重叠，安装会报错并要求 `-NatSubnet` 指定其他私网。续跑不会静默重编号已有桥，须沿用最初子网。dnsmasq 只监听 guest 桥，避免占用 WSL DNS 代理的 `10.255.255.254:53`。

Windows 的 VPN、防火墙、代理或公司网络策略可能阻止 guest 出网；安装器不会关闭这些保护，也不会修改 Windows 防火墙。互联网 ICMP 被禁时联网冒烟会失败，检查网络后续跑。

## 保活与安全停止

- Linux：`pve-wsl-healthcheck.timer` 每分钟检查 hosts、核心服务、NAT 和 DNS，API 仅接受 HTTP 200/401 为就绪。不重启 `pve-guests`，不重启正在运行的 guest。
- Windows：`WSL-<DistroName>-Supervisor` 以当前用户普通权限运行 WSL anchor；登录时启动，并每分钟重试。`IgnoreNew` 避免重复实例。
- 这是**登录后的保活**，不是未登录时的 Windows 服务；无法阻止 Windows 休眠、关机或系统更新。

修复/重装当前脚本创建的保活：

```powershell
.\scripts\Enable-PVEKeepAlive.ps1 -DistroName PVE
```

如果同名任务来自旧版脚本，安装器不会覆盖。先核对旧任务归属并手动停用/移除，或显式选择另一个任务名。不要留下两个监督任务同时拉起同一发行版。

需要停止 WSL 维护时，**先停用任务**，否则一分钟后会自动拉起：

```powershell
Disable-ScheduledTask -TaskName WSL-PVE-Supervisor
```

先优雅关闭 CT/VM，再 `Stop-ScheduledTask` 和 `wsl --terminate PVE`。维护后启用任务并启动：

```powershell
Enable-ScheduledTask -TaskName WSL-PVE-Supervisor
Start-ScheduledTask -TaskName WSL-PVE-Supervisor
```

卸载本版保活（不删除 PVE/guest）：

```powershell
.\scripts\Enable-PVEKeepAlive.ps1 -DistroName PVE -Uninstall
```

## 中断、恢复与限制

失败会返回非零退出码，指出阶段；构建发行版和导出文件保留便于排查。已成功安装的目标不会被重新覆盖。续跑时使用原名称、路径、主机名、源和子网：

```powershell
.\scripts\Install-PVE.ps1 -DistroName PVE-lab -InstallPath D:\WSL\PVE-lab -Hostname pve-lab -NatSubnet 10.20.30.0/24 -NoSetDefault -Resume
```

如果导入目标已经存在但最后验证/保活失败，保留它，先在目标里诊断或单独修复保活；不要立即注销重来。对安装器记录为“已导入”的目标，`-Resume` 只续跑验证和保活，不重置密码、不重新导入；其他已有目标仍会被拒绝。

- 同机 WSL2 发行版共享内核和网络；不要同时启动两个 PVE（8006/85/3128 及桥/guest 网段会冲突）。安装测试前先停止已有 PVE 及其保活。
- `.wslconfig` 是全局设置；有其他发行版运行时，不自动全局 shutdown。新配置需要手动维护后重启，或显式 `-ForceWslShutdown`。
- WSL 使用 Microsoft 内核，不启动安装进 `/boot` 的 Proxmox 内核。
- 首次创建 WSL 依赖微软分发目录和 Debian 镜像；`--web-download` 只是一条回退路径，不保证绕过所有网络问题。
- 不声称支持 Ceph、HA、裸机桥接、PCI/GPU 直通或生产环境。

## 备份

先停用 Windows 保活、优雅关闭 guest，再终止 **指定**发行版（避免不必要地关闭所有 WSL）。确认备份目录存在：

```powershell
wsl --terminate PVE
wsl --export PVE D:\PVE-Backups\PVE-golden.tar
```

导出不等于恢复验证。PVE 的 `/etc/pve` 是运行时挂载，节点数据库保存在 `/var/lib/pve-cluster/config.db`；guest 磁盘还可能在其他存储上，须另行备份。**`wsl --unregister` 会永久删除发行版及其本地 guest 磁盘**，未确认备份前绝不要执行。

## 开发验证

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Helpers.ps1
```

```bash
bash tests/bootstrap-pve.test.sh
```

隔离测试不安装 PVE；真实 Windows/WSL 验收范围见 [VALIDATION.md](VALIDATION.md)。

## 许可证

MIT，详见 [LICENSE](LICENSE)。Proxmox VE 是 Proxmox Server Solutions GmbH 的商标，本项目独立、不隶属于 Proxmox。
