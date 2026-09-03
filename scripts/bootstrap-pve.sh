#!/usr/bin/env bash
set -euo pipefail

# Target: Debian 13 (Trixie) inside WSL2, systemd enabled.
# Installs Proxmox VE 9.2 with KVM, LXC, UEFI firmware, and dynamic hostname support.

log() {
    printf '\n==> %s\n' "$*"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo 'This script must run as root.' >&2
        exit 1
    fi
}

require_systemd() {
    if [[ $(ps -p 1 -o comm=) != 'systemd' ]]; then
        echo 'systemd must be enabled. Add [boot] systemd=true to /etc/wsl.conf, restart WSL, and retry.' >&2
        exit 1
    fi
}

configure_wsl() {
    log 'Configuring WSL systemd and hostname generation'
    cat >/etc/wsl.conf <<'EOF'
[boot]
systemd=true

[network]
generateHosts=false

[user]
default=root
EOF
}

configure_dynamic_hosts() {
    log 'Installing dynamic hosts helper'
    node_name=$(hostname)
    install -d -m 0755 /usr/local/lib/pve-wsl

    cat >/usr/local/lib/pve-wsl/update-hosts <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

node_name=$(hostname)
node_ip=$(ip -o -4 addr show dev eth0 scope global | awk 'NR == 1 { split($4, address, "/"); print address[1] }')
test -n "$node_ip" || { echo 'PVE WSL: eth0 has no IPv4 address' >&2; exit 1; }

temporary_file=$(mktemp /etc/hosts.XXXXXX)
trap 'rm -f "$temporary_file"' EXIT
sed '/# PVE-WSL-MANAGED$/d' /etc/hosts >"$temporary_file"
printf '%s %s.localdomain %s # PVE-WSL-MANAGED\n' "$node_ip" "$node_name" "$node_name" >>"$temporary_file"
cat "$temporary_file" >/etc/hosts
EOF

    chmod 0755 /usr/local/lib/pve-wsl/update-hosts
    /usr/local/lib/pve-wsl/update-hosts

    cat >/etc/systemd/system/pve-wsl-hosts.service <<'EOF'
[Unit]
Description=Refresh PVE hostname mapping for current WSL IPv4
Wants=network-online.target
After=network-online.target
Before=pve-cluster.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/pve-wsl/update-hosts
RemainAfterExit=yes

[Install]
RequiredBy=pve-cluster.service
EOF

    systemctl daemon-reload
    systemctl enable pve-wsl-hosts.service
}

install_pve() {
    log 'Installing prerequisites'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates wget gnupg

    log 'Installing Proxmox release key'
    wget -q https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
        -O /usr/share/keyrings/proxmox-archive-keyring.gpg

    log 'Adding Proxmox VE 9 no-subscription repository'
    cat >/etc/apt/sources.list.d/pve-install-repo.sources <<'EOF'
Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

    apt-get update

    log 'Installing Proxmox VE with UEFI firmware and services'
    echo 'postfix postfix/main_mailer_type select Local only' | debconf-set-selections
    echo "postfix postfix/mailname string $(hostname).localdomain" | debconf-set-selections
    apt-get install -y proxmox-ve pve-edk2-firmware postfix open-iscsi chrony

    log 'Enabling lxcfs for WSL2'
    install -d -m 0755 /etc/systemd/system/lxcfs.service.d
    cat >/etc/systemd/system/lxcfs.service.d/wsl.conf <<'EOF'
[Unit]
ConditionVirtualization=
ConditionVirtualization=container
EOF

    systemctl daemon-reload
    systemctl enable lxcfs
    systemctl enable --now pve-wsl-hosts.service
    systemctl restart pve-cluster pvestatd pvedaemon pveproxy lxcfs
}

set_root_password() {
    log 'Setting root password'
    until passwd root; do
        echo 'Password setup failed. Please try again.' >&2
    done
}

verify() {
    log 'Verifying PVE'
    hostname
    getent ahostsv4 "$(hostname)"
    pveversion
    systemctl is-active pve-wsl-hosts pve-cluster pvestatd pvedaemon pveproxy lxcfs
    systemctl --failed
    test -e /dev/kvm && echo 'KVM device present' || echo 'KVM device missing'
}

require_root
require_systemd
configure_wsl
configure_dynamic_hosts
install_pve
set_root_password
verify

log 'Bootstrap complete. Export/import from Windows to finalize the distro name.'
