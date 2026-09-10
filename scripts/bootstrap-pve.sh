#!/usr/bin/env bash
set -euo pipefail

# Target: Debian 13 (Trixie) inside WSL2, systemd enabled.
# Installs Proxmox VE 9.2 with KVM, LXC, UEFI firmware, and dynamic hostname support.

# Environment overrides:
#   PVE_MIRROR=tsinghua|official   (default: tsinghua)
#   PVE_SKIP_SMOKE=1               Skip the KVM/LXC smoke tests.

PVE_MIRROR="${PVE_MIRROR:-tsinghua}"
PVE_SKIP_SMOKE="${PVE_SKIP_SMOKE:-0}"
PVE_SERVICES=(pve-cluster pvestatd pvedaemon pveproxy pve-guests lxcfs)

case "$PVE_MIRROR" in
    tsinghua)
        PVE_REPO_URL='https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve'
        ;;
    official)
        PVE_REPO_URL='http://download.proxmox.com/debian/pve'
        ;;
    *)
        echo "Unsupported PVE_MIRROR: $PVE_MIRROR (expected tsinghua or official)" >&2
        exit 2
        ;;
esac

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

# Upsert key=value inside an INI section without discarding unrelated settings.
set_ini_key() {
    local file=$1 section=$2 key=$3 value=$4
    local tmp
    mkdir -p "$(dirname "$file")"
    touch "$file"
    tmp=$(mktemp "${file}.XXXXXX")

    awk -v section="$section" -v key="$key" -v value="$value" '
        BEGIN { in_section = 0; section_seen = 0; key_written = 0 }
        function flush_key() {
            if (in_section && !key_written) {
                print key "=" value
                key_written = 1
            }
        }
        /^[[:space:]]*\[/ {
            if (in_section) {
                flush_key()
            }
            in_section = ($0 == "[" section "]")
            if (in_section) {
                section_seen = 1
                key_written = 0
            }
            print
            next
        }
        {
            if (in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
                if (!key_written) {
                    print key "=" value
                    key_written = 1
                }
                next
            }
            print
        }
        END {
            if (!section_seen) {
                print ""
                print "[" section "]"
                print key "=" value
            } else if (in_section) {
                flush_key()
            }
        }
    ' "$file" > "$tmp"

    cat "$tmp" > "$file"
    rm -f "$tmp"
}

configure_wsl() {
    log 'Configuring WSL systemd, hostname and hosts generation'
    local node_name
    node_name=$(hostname)

    set_ini_key /etc/wsl.conf boot systemd true
    set_ini_key /etc/wsl.conf network generateHosts false
    set_ini_key /etc/wsl.conf network hostname "$node_name"
    set_ini_key /etc/wsl.conf user default root
}

configure_dynamic_hosts() {
    log 'Installing dynamic hosts helper'
    install -d -m 0755 /usr/local/lib/pve-wsl

    cat >/usr/local/lib/pve-wsl/update-hosts <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

node_name=$(hostname)
node_ip=$(ip -o -4 addr show dev eth0 scope global 2>/dev/null \
    | awk 'NR == 1 { split($4, address, "/"); print address[1] }')
if [[ -z "$node_ip" ]]; then
    node_ip=$(ip -o -4 addr show scope global 2>/dev/null \
        | awk 'NR == 1 { split($4, address, "/"); print address[1] }')
fi
test -n "$node_ip" || { echo 'PVE WSL: no global IPv4 address found' >&2; exit 1; }

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
    apt-get install -y ca-certificates curl wget gnupg

    log 'Installing Proxmox release key'
    wget -q https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
        -O /usr/share/keyrings/proxmox-archive-keyring.gpg

    log "Adding Proxmox VE 9 no-subscription repository ($PVE_MIRROR)"
    cat >/etc/apt/sources.list.d/pve-install-repo.sources <<EOF
Types: deb
URIs: $PVE_REPO_URL
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

    apt-get update

    log 'Installing Proxmox VE with UEFI firmware and services'
    echo 'postfix postfix/main_mailer_type select Local only' | debconf-set-selections
    echo "postfix postfix/mailname string $(hostname).localdomain" | debconf-set-selections
    apt-get install -y proxmox-ve pve-edk2-firmware postfix open-iscsi chrony
}

configure_lxcfs() {
    log 'Adapting lxcfs for WSL2'
    install -d -m 0755 /etc/systemd/system/lxcfs.service.d

    # WSL2 reports virtualization "wsl"; clearing the condition keeps the
    # stock "!container" guard from blocking lxcfs on a fresh install.
    cat >/etc/systemd/system/lxcfs.service.d/wsl.conf <<'EOF'
[Unit]
ConditionVirtualization=
EOF

    systemctl daemon-reload
}

enable_pve_services() {
    log 'Enabling and starting the Proxmox VE services'
    systemctl daemon-reload
    systemctl enable pve-wsl-hosts.service >/dev/null 2>&1 || true
    systemctl enable "${PVE_SERVICES[@]}" >/dev/null 2>&1 || true
    systemctl restart pve-wsl-hosts.service
    systemctl restart "${PVE_SERVICES[@]}"
}

set_root_password() {
    log 'Setting root password'
    until passwd root; do
        echo 'Password setup failed. Please try again.' >&2
    done
}

verify() {
    log 'Verifying Proxmox VE'
    hostname
    getent ahostsv4 "$(hostname)"
    pveversion
    systemctl is-active pve-wsl-hosts "${PVE_SERVICES[@]}"
    systemctl --failed --no-legend || true
}

verify_kvm() {
    if [[ $PVE_SKIP_SMOKE == 1 ]]; then
        log 'Skipping the KVM smoke test'
        return 0
    fi

    log 'Verifying KVM acceleration with a disposable QEMU process'
    if [[ ! -e /dev/kvm ]]; then
        die '/dev/kvm is missing. Enable nested virtualization in .wslconfig ([wsl2] nestedVirtualization=true), run "wsl --shutdown", and retry.'
    fi

    if printf '%s\n' \
        '{"execute":"qmp_capabilities"}' \
        '{"execute":"quit"}' \
        | timeout 20 qemu-system-x86_64 \
            -accel kvm \
            -machine q35 \
            -m 64 \
            -display none \
            -nodefaults \
            -S \
            -qmp stdio >/dev/null 2>&1; then
        echo 'KVM verification passed.'
    else
        die 'QEMU could not start with KVM acceleration. Check nested virtualization and /dev/kvm permissions.'
    fi
}

verify_lxc() {
    if [[ $PVE_SKIP_SMOKE == 1 ]]; then
        log 'Skipping the LXC smoke test'
        return 0
    fi

    log 'Verifying LXC with a disposable unprivileged container'
    pveam update >/dev/null 2>&1 || true

    local template
    template=$(pveam available --section system 2>/dev/null \
        | awk '$2 ~ /^alpine-/ && $3 == "amd64" { print $2 }' \
        | sort -V \
        | tail -n 1)

    if [[ -z "$template" ]]; then
        warn 'No Alpine template is available; skipping the LXC smoke test.'
        return 0
    fi

    if ! pveam download local "$template" >/dev/null 2>&1 \
        && [[ ! -f "/var/lib/vz/template/cache/$template" ]]; then
        warn "Could not download $template; skipping the LXC smoke test."
        return 0
    fi

    local vmid=99000
    while pct status "$vmid" >/dev/null 2>&1 || qm status "$vmid" >/dev/null 2>&1; do
        vmid=$((vmid + 1))
    done

    cleanup_lxc() {
        pct stop "$vmid" >/dev/null 2>&1 || true
        pct destroy "$vmid" --purge >/dev/null 2>&1 || true
    }
    trap cleanup_lxc EXIT

    pct create "$vmid" "local:vztmpl/$template" \
        --ostype alpine \
        --hostname lxc-smoke \
        --storage local \
        --rootfs local:0.5 \
        --memory 128 \
        --swap 0 \
        --cores 1 \
        --unprivileged 1 \
        --onboot 0 >/dev/null

    pct start "$vmid"
    pct status "$vmid" | grep -q 'status: running'
    pct stop "$vmid"
    pct destroy "$vmid" --purge
    trap - EXIT

    rm -f "/var/lib/vz/template/cache/$template"
    echo 'LXC verification passed.'
}

main() {
    require_root
    require_systemd
    configure_wsl
    configure_dynamic_hosts
    configure_lxcfs
    install_pve
    enable_pve_services
    set_root_password
    verify
    verify_kvm
    verify_lxc

    log 'Bootstrap complete. Export/import from Windows to finalize the distro name.'
}

main "$@"
