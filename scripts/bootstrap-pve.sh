#!/usr/bin/env bash
set -euo pipefail

# Target: Debian 13 (Trixie) inside WSL2, systemd enabled.
# Installs Proxmox VE 9.2 with KVM, LXC, UEFI firmware, and dynamic hostname support.

# Environment overrides:
#   PVE_MIRROR=tsinghua|official   (default: tsinghua)
#   PVE_SKIP_SMOKE=1               Skip the KVM/LXC smoke tests.
#   PVE_SKIP_PASSWORD=1            Do not prompt for a root password (non-interactive runs).
#   PVE_NAT=1|0                    Create the vmbr0 NAT bridge + DHCP/DNS for CT/VM (default: 1).
#   PVE_NAT_SUBNET=10.10.10.0/24   Subnet of vmbr0; the gateway is the .1 address.

PVE_MIRROR="${PVE_MIRROR:-tsinghua}"
PVE_SKIP_SMOKE="${PVE_SKIP_SMOKE:-0}"
PVE_SKIP_PASSWORD="${PVE_SKIP_PASSWORD:-0}"
PVE_NAT="${PVE_NAT:-1}"
PVE_NAT_SUBNET="${PVE_NAT_SUBNET:-10.10.10.0/24}"
PVE_NAT_GATEWAY="${PVE_NAT_SUBNET%.*}.1"
PVE_ALLOW_NO_KVM="${PVE_ALLOW_NO_KVM:-0}"
# pve-guests.service refuses manual start/stop (it is pulled in by its own
# dependency chain), so it is enabled but never restarted by name.
PVE_SERVICES=(pve-cluster pvestatd pvedaemon pveproxy lxcfs)

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

warn() {
    printf '\nWARNING: %s\n' "$*" >&2
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo 'This script must run as root.' >&2
        exit 1
    fi
}

require_platform() {
    local ID= VERSION_ID=
    [[ -r /etc/os-release ]] || die 'Cannot identify this Linux distribution.'
    . /etc/os-release
    [[ $ID == debian && $VERSION_ID == 13 ]] || die 'This installer requires Debian 13 (Trixie).'
    [[ $(uname -m) == x86_64 ]] || die 'This installer requires x86_64 (amd64).'
    [[ $(uname -r) == *[Mm]icrosoft*WSL2* ]] || die 'This installer requires the Microsoft WSL2 kernel.'
    local value
    for value in "$PVE_NAT" "$PVE_SKIP_SMOKE" "$PVE_SKIP_PASSWORD" "$PVE_ALLOW_NO_KVM"; do
        [[ $value == 0 || $value == 1 ]] || die 'Boolean PVE overrides must be 0 or 1.'
    done
    if [[ $PVE_NAT == 1 ]]; then
        validate_nat_subnet
    fi
}

require_systemd() {
    local init
    read -r init </proc/1/comm
    [[ $init == systemd ]] || die 'systemd must be enabled. Add [boot] systemd=true to /etc/wsl.conf, restart WSL, and retry.'
}

# Bound transient acquisition/lock waits without interrupting dpkg mid-install.
apt_run() {
    apt-get -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
        -o DPkg::Lock::Timeout=120 -o APT::Update::Error-Mode=any "$@"
}

validate_nat_subnet() {
    local a b c
    [[ $PVE_NAT_SUBNET =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.0/24$ ]] \
        || die 'PVE_NAT_SUBNET must be a private IPv4 /24 network, for example 10.10.10.0/24.'
    a=$((10#${BASH_REMATCH[1]}))
    b=$((10#${BASH_REMATCH[2]}))
    c=$((10#${BASH_REMATCH[3]}))
    (( a <= 255 && b <= 255 && c <= 255 )) || die 'Invalid IPv4 subnet octet.'
    (( a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) )) \
        || die 'PVE_NAT_SUBNET must be within RFC1918 private address space.'
    PVE_NAT_SUBNET="$a.$b.$c.0/24"
    PVE_NAT_GATEWAY="$a.$b.$c.1"
}

# Read routes from stdin; all routing tables, including local addresses, matter.
nat_routes_conflict() {
    awk -v net="$PVE_NAT_SUBNET" '
        function ipnum(ip, a) {
            split(ip, a, ".")
            return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4]
        }
        BEGIN { split(net, n, "/"); first = ipnum(n[1]); last = first + 255 }
        /(^| )dev vmbr0( |$)/ { next }
        {
            route = $1
            if (route ~ /^(local|broadcast|unreachable|blackhole|prohibit|throw)$/) route = $2
            if (route == "default" || route !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) next
            split(route, r, "/"); bits = (r[2] == "" ? 32 : r[2] + 0)
            if (bits == 0) next
            size = 2 ^ (32 - bits); start = int(ipnum(r[1]) / size) * size
            if (start <= last && start + size - 1 >= first) { print $0; found = 1 }
        }
        END { exit !found }
    '
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
node_ip=
for attempt in {1..20}; do
    node_ip=$({ ip -o -4 addr show dev eth0 scope global 2>/dev/null || true; } \
        | awk 'NR == 1 { split($4, address, "/"); print address[1] }')
    if [[ -z "$node_ip" ]]; then
        node_ip=$(ip -o -4 addr show scope global \
            | awk '$2 != "vmbr0" && !found { split($4, address, "/"); print address[1]; found = 1 }')
    fi
    [[ -z "$node_ip" ]] || break
    sleep 1
done
test -n "$node_ip" || { echo 'PVE WSL: no global IPv4 address found' >&2; exit 1; }

temporary_file=$(mktemp /etc/hosts.XXXXXX)
trap 'rm -f "$temporary_file"' EXIT
# Remove only this node aliases, including old untagged WSL and loopback
# mappings. Preserve unrelated aliases and comments on those same lines.
awk -v node="$node_name" '
    /# PVE-WSL-MANAGED[[:space:]]*$/ { next }
    /^[[:space:]]*(#|$)/ { print; next }
    {
        comment = ""; hash = index($0, "#")
        text = $0
        if (hash) { comment = substr(text, hash); text = substr(text, 1, hash - 1) }
        count = split(text, fields, /[[:space:]]+/)
        address = ""; aliases = ""
        for (i = 1; i <= count; i++) {
            if (fields[i] == "") continue
            if (address == "") { address = fields[i]; continue }
            name = tolower(fields[i])
            if (name != tolower(node) && name != tolower(node ".localdomain")) aliases = aliases " " fields[i]
        }
        if (aliases != "") print address aliases (comment == "" ? "" : " " comment)
        else if (comment != "") print comment
    }
' /etc/hosts >"$temporary_file"
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

# The proxmox-ve package adds the enterprise repository, which needs a
# subscription and makes every later `apt-get update` fail with 401.
disable_enterprise_repos() {
    local file
    for file in /etc/apt/sources.list.d/pve-enterprise.sources \
        /etc/apt/sources.list.d/ceph.sources \
        /etc/apt/sources.list.d/ceph.list; do
        if [[ -f $file ]]; then
            mv "$file" "$file.disabled"
            log "Disabled the subscription repository: $file"
        fi
    done
}

# The Debian WSL image points its own repositories at deb.debian.org and
# security.debian.org. Those hosts are unreachable from some networks, which
# would fail the very first apt run, so the tsinghua mirror covers them too.
configure_debian_mirror() {
    [[ $PVE_MIRROR == tsinghua ]] || return 0
    local file changed=0
    for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
        [[ -f $file ]] || continue
        if grep -qE 'https?://(deb|security)\.debian\.org/' "$file"; then
            sed -i \
                -e 's|https\?://security\.debian\.org/debian-security|https://mirrors.tuna.tsinghua.edu.cn/debian-security|g' \
                -e 's|https\?://deb\.debian\.org/debian|https://mirrors.tuna.tsinghua.edu.cn/debian|g' \
                "$file"
            changed=1
        fi
    done
    [[ $changed == 0 ]] || log 'Pointed the Debian repositories at the tsinghua mirror'
    return 0
}

# The minimal Debian WSL image may lack iproute2 (used by the hosts helper) and
# the other tools below, so install them before anything depends on them.
install_base_tools() {
    log 'Installing base tools'
    export DEBIAN_FRONTEND=noninteractive
    configure_debian_mirror
    disable_enterprise_repos
    apt_run update
    apt_run install -y ca-certificates curl wget gnupg iproute2 procps
}

download_release_key() (
    # A failed download must never truncate the key used by an existing repo.
    keyring=$1
    temporary_file=$(mktemp "${keyring}.XXXXXX")
    trap 'rm -f "$temporary_file"' EXIT
    wget -q --tries=3 --timeout=30 \
        https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
        -O "$temporary_file" \
        || die 'Could not download the Proxmox archive keyring; the previous key was retained.'
    [[ -s $temporary_file ]] && gpg --batch --show-keys "$temporary_file" >/dev/null 2>&1 \
        || die 'The downloaded Proxmox keyring is invalid; the previous key was retained.'
    chmod 0644 "$temporary_file"
    mv -f "$temporary_file" "$keyring"
)

commit_initial_network_config() {
    local network_file=$1 fresh_install=$2 pending="$1.new"
    [[ -e $pending ]] || return 0
    # ifupdown2's first-install compatibility hook stages interfaces.new.
    # pvenetcommit renames it only at boot, so waiting never activates it.
    [[ $fresh_install == 1 ]] \
        || die "Pending network changes exist at $pending; apply or discard them explicitly before rerunning."
    [[ -f $pending && ! -L $pending ]] \
        || die "Unexpected pending network configuration: $pending"
    ifquery -i "$pending" --list >/dev/null \
        || die "Package-generated network configuration is invalid: $pending"
    log 'Committing validated first-install network configuration (without restarting host networking)'
    mv -- "$pending" "$network_file"
}

install_pve() {
    local fresh_install=0
    command -v pveversion >/dev/null 2>&1 || fresh_install=1
    # Never consume changes that predated this package installation.
    [[ ! -e /etc/network/interfaces.new ]] \
        || die 'Pending /etc/network/interfaces.new exists before package installation; apply or discard it first.'

    log 'Installing Proxmox release key'
    export DEBIAN_FRONTEND=noninteractive
    download_release_key /usr/share/keyrings/proxmox-archive-keyring.gpg

    log "Adding Proxmox VE 9 no-subscription repository ($PVE_MIRROR)"
    cat >/etc/apt/sources.list.d/pve-install-repo.sources <<EOF
Types: deb
URIs: $PVE_REPO_URL
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

    apt_run update

    log 'Installing Proxmox VE with UEFI firmware and services'
    echo 'postfix postfix/main_mailer_type select Local only' | debconf-set-selections
    echo "postfix postfix/mailname string $(hostname).localdomain" | debconf-set-selections
    apt_run install -y proxmox-ve pve-edk2-firmware postfix open-iscsi chrony

    # Installing proxmox-ve registers the enterprise repo; drop it so later
    # `apt-get update` runs and the PVE update timer keep working.
    disable_enterprise_repos
    apt_run update

    # ifupdown2 stages its first-install compatibility config as interfaces.new
    # and only pvenetcommit (at boot) renames it. Commit it now so the NAT step
    # reads the real configuration instead of the still-empty original file.
    commit_initial_network_config /etc/network/interfaces "$fresh_install"
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

list_network_interfaces() (
    # pvenetcommit/package startup may still be initializing this file.
    # ifquery reports an empty (valid) file as an error, not an empty list.
    network_file=$1
    diagnostics=$(mktemp)
    trap 'rm -f "$diagnostics"' EXIT
    for attempt in {1..10}; do
        if interfaces=$(ifquery -i "$network_file" --list 2>"$diagnostics"); then
            cat "$diagnostics" >&2
            printf '%s\n' "$interfaces"
            exit 0
        fi
        if [[ $(<"$diagnostics") != 'error: main exception: no ifaces found matching given allow lists' ]]; then
            cat "$diagnostics" >&2
            die "Could not parse $network_file; fix the reported error before rerunning."
        fi
        [[ $attempt == 10 ]] || sleep 1
    done
    # Only initialize an entirely empty/comment-only file. Do not overwrite
    # source directives or guess how to repair an existing configuration.
    if ! grep -Eq '^[[:space:]]*[^#[:space:]]' "$network_file"; then
        printf '\nauto lo\niface lo inet loopback\n' >>"$network_file"
        if interfaces=$(ifquery -i "$network_file" --list 2>"$diagnostics"); then
            cat "$diagnostics" >&2
            printf '%s\n' "$interfaces"
            exit 0
        fi
    fi
    cat "$diagnostics" >&2
    die "No interfaces were found in $network_file after waiting for initialization; check this file and its source directives."
)

configure_nat() {
    if [[ $PVE_NAT != 1 ]]; then
        log 'Skipping the vmbr0 NAT bridge (PVE_NAT=0)'
        return 0
    fi

    validate_nat_subnet
    log "Configuring the vmbr0 NAT bridge ($PVE_NAT_SUBNET, gateway $PVE_NAT_GATEWAY)"
    export DEBIAN_FRONTEND=noninteractive

    local routes conflicts interfaces existing address managed=0
    routes=$(ip -4 route show table all)
    if conflicts=$(printf '%s\n' "$routes" | nat_routes_conflict); then
        die "$PVE_NAT_SUBNET overlaps an existing route: $conflicts. Pick another PVE_NAT_SUBNET."
    fi

    touch /etc/network/interfaces
    if grep -q '^#PVE-WSL NAT bridge (managed by bootstrap-pve.sh)$' /etc/network/interfaces; then
        managed=1
    fi
    interfaces=$(list_network_interfaces /etc/network/interfaces) \
        || die 'Could not initialize or parse /etc/network/interfaces; see the diagnostics above.'
    existing=
    if printf '%s\n' "$interfaces" | grep -Fxq vmbr0; then
        existing=$(ifquery vmbr0) || die 'Could not read the existing vmbr0 configuration.'
    fi
    if [[ -n $existing ]]; then
        [[ $managed == 1 ]] || die 'vmbr0 is already configured outside this installer; refusing to overwrite it.'
        printf '%s\n' "$existing" | awk '$1 == "bridge-ports" && $2 == "none" && NF == 2 { found = 1 } END { exit !found }' \
            || die 'vmbr0 is no longer an isolated NAT bridge; refusing to change it.'
        address=$(printf '%s\n' "$existing" | awk '$1 == "address" { print $2 }')
        [[ $address == "$PVE_NAT_GATEWAY/24" ]] \
            || die "Existing vmbr0 uses '$address'. Refusing to renumber an existing bridge; rerun with its original PVE_NAT_SUBNET."
    elif ip link show vmbr0 >/dev/null 2>&1; then
        die 'An unmanaged vmbr0 already exists (possibly in another WSL distro); refusing to reuse it.'
    fi
    if ip link show vmbr0 >/dev/null 2>&1; then
        [[ -d /sys/class/net/vmbr0/bridge ]] || die 'vmbr0 exists but is not a Linux bridge.'
        address=$(ip -o -4 addr show dev vmbr0 scope global | awk '{ print $4 }')
        [[ -z $address || $address == "$PVE_NAT_GATEWAY/24" ]] \
            || die "Live vmbr0 has unexpected addresses '$address'; refusing to change it."
    fi

    # Install only the binary first; dnsmasq.service must not start before
    # the bridge exists and the restricted listening configuration is ready.
    apt_run install -y iptables dnsmasq-base

    install -d -m 0755 /etc/sysctl.d
    printf 'net.ipv4.ip_forward = 1\n' >/etc/sysctl.d/99-pve-wsl.conf
    sysctl -q -p /etc/sysctl.d/99-pve-wsl.conf

    if [[ -z $existing ]]; then
        cat >>/etc/network/interfaces <<EOF

auto vmbr0
iface vmbr0 inet static
    address $PVE_NAT_GATEWAY/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up iptables -t nat -C POSTROUTING -s $PVE_NAT_SUBNET ! -d $PVE_NAT_SUBNET -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $PVE_NAT_SUBNET ! -d $PVE_NAT_SUBNET -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s $PVE_NAT_SUBNET ! -d $PVE_NAT_SUBNET -j MASQUERADE 2>/dev/null || true
#PVE-WSL NAT bridge (managed by bootstrap-pve.sh)
EOF
    fi
    # Force reapplication on retries, including an existing but down or
    # partly configured link. The post-up rule uses -C to avoid duplicates.
    ifup --force vmbr0 || die 'Could not bring up vmbr0 (ifupdown2).'
    ip -o -4 addr show dev vmbr0 scope global | awk -v expected="$PVE_NAT_GATEWAY/24" '
        $4 == expected { found = 1 } END { exit !found }
    ' || die 'vmbr0 did not receive the configured gateway address.'
    iptables -t nat -C POSTROUTING -s "$PVE_NAT_SUBNET" ! -d "$PVE_NAT_SUBNET" -j MASQUERADE \
        || iptables -t nat -A POSTROUTING -s "$PVE_NAT_SUBNET" ! -d "$PVE_NAT_SUBNET" -j MASQUERADE

    # Write the dnsmasq config before installing the package: the stock
    # config binds 0.0.0.0:53, and WSL2 already listens on 10.255.255.254:53
    # (its DNS proxy), so dnsmasq must be restricted to the bridge address.
    local prefix=${PVE_NAT_SUBNET%.0/24}
    install -d -m 0755 /etc/dnsmasq.d
    cat >/etc/dnsmasq.d/pve-wsl.conf <<EOF
# Managed by bootstrap-pve.sh: DHCP + DNS for guests on the vmbr0 NAT bridge.
# subnet=$PVE_NAT_SUBNET
interface=vmbr0
except-interface=lo
bind-interfaces
listen-address=$PVE_NAT_GATEWAY
dhcp-range=$prefix.100,$prefix.200,12h
dhcp-option=option:router,$PVE_NAT_GATEWAY
dhcp-option=option:dns-server,$PVE_NAT_GATEWAY
EOF
    apt_run install -y dnsmasq

    install -d -m 0755 /etc/systemd/system/dnsmasq.service.d
    cat >/etc/systemd/system/dnsmasq.service.d/pve-wsl.conf <<'EOF'
[Unit]
After=networking.service

[Service]
Restart=on-failure
EOF
    systemctl daemon-reload
    systemctl enable dnsmasq >/dev/null
    systemctl restart dnsmasq || die 'dnsmasq failed to start; see: journalctl -u dnsmasq'
    ss -H -lun | awk -v expected="$PVE_NAT_GATEWAY:53" '$4 == expected { found = 1 } END { exit !found }' \
        || die "dnsmasq is not listening on $PVE_NAT_GATEWAY:53."
}

enable_pve_services() {
    log 'Enabling and starting the Proxmox VE services'
    systemctl daemon-reload
    systemctl enable pve-wsl-hosts.service >/dev/null
    systemctl enable "${PVE_SERVICES[@]}" pve-guests >/dev/null
    systemctl restart pve-wsl-hosts.service
    systemctl restart "${PVE_SERVICES[@]}"
}

set_root_password() {
    if [[ $PVE_SKIP_PASSWORD == 1 ]]; then
        log 'Skipping the root password prompt (PVE_SKIP_PASSWORD=1); the installer must have set it already, or run passwd root later.'
        return 0
    fi

    log 'Setting root password'
    local attempt
    for attempt in 1 2 3 4 5; do
        if passwd root; then
            return 0
        fi
        echo "Password setup failed (attempt $attempt/5). Please try again." >&2
    done
    die 'Could not set the root password. Rerun interactively, or set PVE_SKIP_PASSWORD=1 and run "passwd root" later.'
}

verify() {
    log 'Verifying Proxmox VE'
    hostname
    getent ahostsv4 "$(hostname)"
    pveversion
    local unit
    for unit in pve-wsl-hosts "${PVE_SERVICES[@]}"; do
        systemctl is-active --quiet "$unit" || die "Required service $unit is not active."
    done
    systemctl --failed --no-legend || true
}

verify_kvm() {
    if [[ $PVE_SKIP_SMOKE == 1 ]]; then
        log 'Skipping the KVM smoke test'
        return 0
    fi

    log 'Verifying KVM acceleration with a disposable QEMU process'
    if [[ ! -e /dev/kvm ]]; then
        if [[ $PVE_ALLOW_NO_KVM == 1 ]]; then
            warn '/dev/kvm is missing; continuing without KVM (LXC only).'
            return 0
        fi
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

verify_lxc() (
    # Keep trap state in this subshell, not function-local variables that
    # Bash may unwind before running an EXIT trap after errexit.
    if [[ $PVE_SKIP_SMOKE == 1 ]]; then
        log 'Skipping the LXC smoke test'
        return 0
    fi

    log 'Verifying LXC with a disposable unprivileged container'
    # pveam refreshes the Proxmox index and the community Turnkey index. The
    # Turnkey host is unreachable from some networks; a cached index that still
    # lists a template is enough for this check.
    if ! pveam update; then
        if pveam available --section system | awk '$2 ~ /^alpine-/ { found = 1 } END { exit !found }'; then
            warn 'Could not refresh the community template index; using the cached index.'
        else
            die 'Could not refresh container templates; LXC verification was not completed.'
        fi
    fi

    # Match on the file name only: the column layout of `pveam available`
    # differs between versions and also lists arm64 templates.
    template=$(pveam available --section system \
        | awk '$2 ~ /^alpine-/ && $2 ~ /_amd64[.]/ { print $2 }' \
        | sort -V \
        | tail -n 1)
    [[ -n $template ]] || die 'No Alpine amd64 template is available; LXC verification was not completed.'
    # Let pveam validate/reuse its cache; never delete a user's cached template.
    pveam download local "$template" \
        || die "Could not obtain $template; LXC verification was not completed."

    vmid=$(pvesh get /cluster/nextid) || die 'Could not allocate a smoke-test CT ID.'
    [[ $vmid =~ ^[1-9][0-9]+$ ]] || die 'Proxmox returned an invalid smoke-test CT ID.'
    created=0
    smoke_name="lxc-smoke-$vmid-$BASHPID"
    cleanup_lxc() {
        result=$?
        trap - EXIT
        # A failed create can leave a config/rootfs behind. Only claim that
        # partial CT if its unique hostname proves it belongs to this run;
        # never destroy a concurrently allocated guest after an ID race.
        if [[ $created == 0 ]] && pct config "$vmid" 2>/dev/null | grep -Fxq "hostname: $smoke_name"; then
            created=1
        fi
        if [[ $created == 1 ]]; then
            pct stop "$vmid" >/dev/null 2>&1 || true
            if ! pct destroy "$vmid" --purge >/dev/null 2>&1; then
                warn "Could not remove smoke-test CT $vmid; remove it manually."
                [[ $result != 0 ]] || result=1
            fi
        fi
        exit "$result"
    }
    trap cleanup_lxc EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    net_args=()
    if [[ $PVE_NAT == 1 ]]; then
        net_args=(--net0 "name=eth0,bridge=vmbr0,ip=${PVE_NAT_SUBNET%.0/24}.250/24,gw=$PVE_NAT_GATEWAY" --nameserver "$PVE_NAT_GATEWAY")
    fi

    pct create "$vmid" "local:vztmpl/$template" \
        --ostype alpine \
        --hostname "$smoke_name" \
        --storage local \
        --rootfs local:0.5 \
        --memory 128 \
        --swap 0 \
        --cores 1 \
        --unprivileged 1 \
        "${net_args[@]}" \
        --onboot 0 >/dev/null
    created=1

    pct start "$vmid"
    pct status "$vmid" | grep -q 'status: running' \
        || die 'The smoke-test container did not reach the running state.'

    if [[ $PVE_NAT == 1 ]]; then
        log 'Checking container networking (gateway, then the internet)'
        sleep 3
        pct exec "$vmid" -- ping -c 2 -W 3 "$PVE_NAT_GATEWAY" >/dev/null 2>&1 \
            || die "The container cannot reach the NAT gateway $PVE_NAT_GATEWAY on vmbr0."
        if pct exec "$vmid" -- ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then
            echo 'Container internet access verified.'
        else
            die 'The container reached the gateway but not 1.1.1.1; check the Windows firewall/VPN, then rerun.'
        fi
        pct exec "$vmid" -- nslookup debian.org "$PVE_NAT_GATEWAY" >/dev/null 2>&1 \
            || die 'The container could not resolve debian.org through the NAT DNS server.'
    fi

    pct stop "$vmid"
    pct destroy "$vmid" --purge
    created=0
    trap - EXIT INT TERM
    echo 'LXC verification passed.'
)

main() {
    require_root
    require_platform
    require_systemd
    install_base_tools
    configure_wsl
    configure_dynamic_hosts
    configure_lxcfs
    install_pve
    configure_nat
    enable_pve_services
    set_root_password
    verify
    verify_kvm
    verify_lxc

    log 'Bootstrap complete. Export/import from Windows to finalize the distro name.'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
