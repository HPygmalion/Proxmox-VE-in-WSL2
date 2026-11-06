#!/usr/bin/env bash
# Isolated regression tests: source functions only; never invoke main or WSL.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/bootstrap-pve.sh"
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "Missing '$2' in $1"; }
assert_absent() { if grep -Fq -- "$2" "$1"; then fail "Unexpected '$2' in $1"; fi; }

# Each case is a fresh process: do not put shell functions under `if`, which
# disables errexit inside them and would hide the original EXIT-trap bug.
if [[ ${1:-} != --case ]]; then
    for case_name in platform subnet routes apt key hosts services network_init nat lxc; do
        bash "$0" --case "$case_name"
        printf 'PASS: %s\n' "$case_name"
    done
    exit 0
fi

case $2 in
platform)
    definition=$(declare -f require_platform)
    definition=${definition//\/etc\/os-release/$sandbox/os-release}
    eval "$definition"
    printf 'ID=debian\nVERSION_ID=13\n' >"$sandbox/os-release"
    uname() {
        if [[ $1 == -m ]]; then printf '%s\n' "$test_arch"; else printf '%s\n' "$test_kernel"; fi
    }
    test_arch=x86_64 test_kernel=6.6.87.2-microsoft-standard-WSL2
    require_platform
    for invalid in distro architecture kernel boolean; do
        printf 'ID=debian\nVERSION_ID=13\n' >"$sandbox/os-release"
        test_arch=x86_64 test_kernel=6.6.87.2-microsoft-standard-WSL2 PVE_NAT=1
        case $invalid in
            distro) printf 'ID=debian\nVERSION_ID=12\n' >"$sandbox/os-release" ;;
            architecture) test_arch=aarch64 ;;
            kernel) test_kernel=6.12-amd64 ;;
            boolean) PVE_NAT=yes ;;
        esac
        if (require_platform) >"$sandbox/out" 2>&1; then fail "Platform accepted $invalid"; fi
    done
    ;;
subnet)
    for value in 10.0.0.0/24 172.16.0.0/24 172.31.255.0/24 192.168.2.0/24; do
        PVE_NAT_SUBNET=$value
        validate_nat_subnet
        [[ $PVE_NAT_SUBNET == "$value" ]] || fail 'Subnet changed unexpectedly'
    done
    PVE_NAT_SUBNET=010.002.003.0/24
    validate_nat_subnet
    [[ $PVE_NAT_SUBNET == 10.2.3.0/24 && $PVE_NAT_GATEWAY == 10.2.3.1 ]] || fail 'Subnet canonicalization'
    for value in 999.10.10.0/24 10.256.0.0/24 10.0.0.1/24 10.0.0.0/16 8.8.8.0/24 172.32.0.0/24 192.169.0.0/24; do
        if (PVE_NAT_SUBNET=$value; validate_nat_subnet) >"$sandbox/out" 2>&1; then
            fail "Accepted $value"
        fi
    done
    ;;
routes)
    PVE_NAT_SUBNET=10.10.10.0/24
    for route in '10.0.0.0/8 dev eth0' '10.10.10.128/25 dev tun0' 'local 10.10.10.2 dev eth0 table local' 'blackhole 10.10.0.0/16'; do
        printf '%s\n' "$route" | nat_routes_conflict >"$sandbox/out" || fail "Missed $route"
    done
    for route in 'default via 172.20.0.1 dev eth0' '10.10.10.0/24 dev vmbr0' '10.10.11.0/24 dev eth0' 'local 10.10.10.1 dev vmbr0 table local'; do
        if printf '%s\n' "$route" | nat_routes_conflict >"$sandbox/out"; then fail "False collision: $route"; fi
    done
    ;;
apt)
    apt-get() { printf '%s\n' "$@" >"$sandbox/args"; }
    apt_run update
    for option in Acquire::Retries=3 Acquire::http::Timeout=30 Acquire::https::Timeout=30 DPkg::Lock::Timeout=120 APT::Update::Error-Mode=any update; do
        assert_contains "$sandbox/args" "$option"
    done
    ;;
key)
    printf 'old-key' >"$sandbox/keyring"
    wget() {
        while [[ $1 != -O ]]; do shift; done
        printf 'new-key' >"$2"
        return "$wget_status"
    }
    gpg() { return "$gpg_status"; }
    wget_status=1 gpg_status=0
    if (download_release_key "$sandbox/keyring") >"$sandbox/out" 2>&1; then fail 'Failed download passed'; fi
    [[ $(<"$sandbox/keyring") == old-key ]] || fail 'Failed download replaced key'
    wget_status=0 gpg_status=1
    if (download_release_key "$sandbox/keyring") >"$sandbox/out" 2>&1; then fail 'Invalid key passed'; fi
    [[ $(<"$sandbox/keyring") == old-key ]] || fail 'Invalid key replaced old key'
    wget_status=0 gpg_status=0
    download_release_key "$sandbox/keyring"
    [[ $(<"$sandbox/keyring") == new-key ]] || fail 'Valid key not installed'
    shopt -s nullglob
    leftovers=("$sandbox"/keyring.*)
    [[ ${#leftovers[@]} == 0 ]] || fail 'Temporary keyring leaked'
    ;;
hosts)
    # Extract the actual generated helper, redirect only /etc paths to fixtures.
    awk '/^    cat >\/usr\/local\/lib\/pve-wsl\/update-hosts/ { copy = 1; next } copy && /^EOF$/ { exit } copy { print }' \
        "$root/scripts/bootstrap-pve.sh" >"$sandbox/helper-original"
    helper=$(<"$sandbox/helper-original")
    helper=${helper//\/etc\//$sandbox/etc/}
    printf '%s\n' "$helper" >"$sandbox/helper"
    mkdir -p "$sandbox/etc"
    printf '%s\n' '127.0.0.1 localhost pve-lab' '172.20.1.5 pve-lab.localdomain pve-lab other # keep' \
        '::1 ip6-localhost PVE-LAB' '192.0.2.1 custom' '# comment' \
        '172.20.0.4 pve-lab.localdomain pve-lab # PVE-WSL-MANAGED' >"$sandbox/etc/hosts"
    hostname() { printf 'pve-lab\n'; }
    ip() { printf '2: eth0 inet 172.20.2.5/20 scope global eth0\n'; }
    export -f hostname ip
    bash "$sandbox/helper"
    assert_absent "$sandbox/etc/hosts" '172.20.0.4'
    assert_contains "$sandbox/etc/hosts" '172.20.1.5 other # keep'
    assert_contains "$sandbox/etc/hosts" '127.0.0.1 localhost'
    assert_contains "$sandbox/etc/hosts" '::1 ip6-localhost'
    assert_contains "$sandbox/etc/hosts" '192.0.2.1 custom'
    assert_contains "$sandbox/etc/hosts" '172.20.2.5 pve-lab.localdomain pve-lab # PVE-WSL-MANAGED'
    cp "$sandbox/etc/hosts" "$sandbox/first"
    bash "$sandbox/helper"
    cmp "$sandbox/first" "$sandbox/etc/hosts" || fail 'Hosts rerun changed content'
    ;;
services)
    hostname() { printf 'pve-lab\n'; }
    getent() { return 0; }
    pveversion() { return 0; }
    systemctl() {
        printf '%s\n' "$*" >>"$sandbox/calls"
        [[ $* != 'is-active --quiet pveproxy' ]]
    }
    if (verify) >"$sandbox/out" 2>&1; then fail 'Inactive pveproxy passed'; fi
    assert_contains "$sandbox/calls" 'is-active --quiet pveproxy'
    assert_contains "$sandbox/out" 'Required service pveproxy is not active'
    ;;
network_init)
    network_file="$sandbox/interfaces"
    sleep() { printf 'wait\n' >>"$sandbox/waits"; }
    ifquery() {
        printf 'query\n' >>"$sandbox/queries"
        if [[ $init_scenario == malformed ]]; then
            printf 'error: interfaces: line 2: invalid syntax\n' >&2
            return 1
        fi
        if [[ $init_scenario == warning ]]; then
            printf 'warning: invalid option\nerror: main exception: no ifaces found matching given allow lists\n' >&2
            return 1
        fi
        if [[ $init_scenario == delayed && $(wc -l <"$sandbox/queries") == 3 ]]; then
            printf 'auto lo\niface lo inet loopback\niface eth0 inet manual\n' >"$network_file"
        fi
        if grep -q '^iface lo inet loopback$' "$network_file"; then
            printf 'lo\n'
            return 0
        fi
        printf 'error: main exception: no ifaces found matching given allow lists\n' >&2
        return 1
    }
    for init_scenario in empty delayed malformed warning source_only; do
        : >"$network_file"
        : >"$sandbox/queries"
        : >"$sandbox/waits"
        if [[ $init_scenario == source_only ]]; then printf 'source interfaces.d/*\n' >"$network_file"; fi
        if list_network_interfaces "$network_file" >"$sandbox/out" 2>"$sandbox/errors"; then
            case $init_scenario in empty|delayed) ;; *) fail "Accepted $init_scenario interfaces" ;; esac
        else
            case $init_scenario in empty|delayed) fail "Failed $init_scenario initialization" ;; esac
        fi
        case $init_scenario in
            empty)
                [[ $(wc -l <"$sandbox/waits") == 9 ]] || fail 'Empty config wait not bounded'
                assert_contains "$network_file" 'iface lo inet loopback'
                assert_contains "$sandbox/out" 'lo'
                ;;
            delayed)
                [[ $(wc -l <"$sandbox/waits") == 2 ]] || fail 'Initialization was not retried'
                assert_contains "$network_file" 'iface eth0 inet manual'
                [[ $(grep -c '^auto lo$' "$network_file") == 1 ]] || fail 'Loopback duplicated'
                ;;
            malformed|warning)
                [[ ! -s $sandbox/waits && ! -s $network_file ]] || fail 'Parse error retried or rewritten'
                assert_contains "$sandbox/errors" 'Could not parse'
                ;;
            source_only)
                assert_absent "$network_file" 'auto lo'
                assert_contains "$sandbox/errors" 'after waiting for initialization'
                ;;
        esac
    done
    ;;
nat)
    # Rewrite absolute config paths in this function only. All host/network
    # commands are fakes; ifup simulates creating the address after a retry.
    definition=$(declare -f configure_nat)
    definition=${definition//\/etc\//$sandbox/etc/}
    definition=${definition//\/sys\//$sandbox/sys/}
    eval "$definition"
    mkdir -p "$sandbox/etc/network" "$sandbox/sys/class/net/vmbr0/bridge"
    : >"$sandbox/etc/network/interfaces"
    ip() {
        case "$*" in
            '-4 route show table all') printf '%s\n' "${route_fixture:-default via 172.20.0.1 dev eth0}" ;;
            'link show vmbr0') [[ -f $sandbox/link ]] ;;
            '-o -4 addr show dev vmbr0 scope global')
                if [[ -f $sandbox/address ]]; then printf '3: vmbr0 inet 10.10.10.1/24 scope global vmbr0\n'; fi ;;
            *) fail "Unexpected ip $*" ;;
        esac
    }
    ifquery() {
        if [[ $1 == -i && $3 == --list ]]; then
            if grep -q '^iface vmbr0 ' "$sandbox/etc/network/interfaces"; then printf 'vmbr0\n'; fi
            return 0
        fi
        grep -q '^iface vmbr0 ' "$sandbox/etc/network/interfaces" || return 1
        printf 'iface vmbr0 inet static\n    address 10.10.10.1/24\n    bridge-ports none\n'
    }
    ifup() { printf '%s\n' "$*" >>"$sandbox/ifup"; touch "$sandbox/link" "$sandbox/address"; }
    apt_run() { printf '%s\n' "$*" >>"$sandbox/apt"; }
    sysctl() { return 0; }
    systemctl() { return 0; }
    ss() { printf 'UNCONN 0 0 10.10.10.1:53 0.0.0.0:*\n'; }
    iptables() {
        if [[ $* == *' -C '* ]]; then [[ -f $sandbox/rule ]]; else
            printf '%s\n' "$*" >>"$sandbox/iptables"; touch "$sandbox/rule"
        fi
    }
    configure_nat >"$sandbox/out"
    cp "$sandbox/etc/network/interfaces" "$sandbox/first"
    rm "$sandbox/address" "$sandbox/rule"
    configure_nat >>"$sandbox/out"
    cmp "$sandbox/first" "$sandbox/etc/network/interfaces" || fail 'NAT stanza duplicated'
    [[ $(wc -l <"$sandbox/ifup") == 2 ]] || fail 'Existing bridge was not reapplied'
    assert_contains "$sandbox/iptables" '-A POSTROUTING'
    assert_contains "$sandbox/apt" 'install -y iptables dnsmasq-base'
    assert_contains "$sandbox/apt" 'install -y dnsmasq'
    PVE_NAT_SUBNET=10.20.30.0/24
    if (configure_nat) >"$sandbox/out" 2>&1; then fail 'Changed subnet was silently reused'; fi
    assert_contains "$sandbox/out" 'Refusing to renumber'
    cmp "$sandbox/first" "$sandbox/etc/network/interfaces" || fail 'Rejected subnet changed configuration'
    PVE_NAT_SUBNET=10.10.10.0/24
    route_fixture='10.0.0.0/8 dev eth0'
    if (configure_nat) >"$sandbox/out" 2>&1; then fail 'Overlapping route accepted'; fi
    assert_contains "$sandbox/out" 'overlaps an existing route'
    ;;
lxc)
    PVE_NAT=0
    pveam() {
        case $1 in
            update) [[ $scenario != metadata ]] ;;
            available) if [[ $scenario != empty ]]; then printf 'system alpine-3.22-default_amd64.tar.xz\n'; fi ;;
            download) [[ $scenario != download ]] ;;
            *) fail "Unexpected pveam $*" ;;
        esac
    }
    pvesh() { printf '123\n'; }
    sleep() { :; }
    pct() {
        printf '%s\n' "$*" >>"$sandbox/pct"
        case $1 in
            create)
                shift 2
                while [[ $1 != --hostname ]]; do shift; done
                printf 'hostname: %s\n' "$2" >"$sandbox/ct-config"
                [[ $scenario != create && $scenario != partial ]]
                ;;
            config)
                if [[ $scenario == partial ]]; then command cat "$sandbox/ct-config"; else printf 'hostname: unrelated-guest\n'; fi
                ;;
            start) [[ $scenario != start ]] ;;
            status) printf 'status: running\n' ;;
            stop) [[ $scenario != stop ]] ;;
            destroy) [[ $scenario != destroy ]] ;;
            exec)
                [[ $scenario != gateway ]] || return 1
                [[ $scenario != internet || $* != *1.1.1.1* ]] || return 1
                [[ $scenario != dns || $* != *nslookup* ]]
                ;;
            *) fail "Unexpected pct $*" ;;
        esac
    }
    export -f pveam pvesh pct sleep
    export sandbox
    for scenario in metadata empty download create partial start stop destroy gateway internet dns success; do
        : >"$sandbox/pct"
        export scenario
        PVE_NAT=0
        case $scenario in gateway|internet|dns) PVE_NAT=1 ;; esac
        export PVE_NAT
        # Start an independent shell so errexit is truly enabled in verify_lxc.
        if bash -c 'source "$1"; verify_lxc' _ "$root/scripts/bootstrap-pve.sh" >"$sandbox/out" 2>&1; then
            [[ $scenario == success ]] || fail "$scenario unexpectedly passed"
        else
            [[ $scenario != success ]] || fail 'Successful CT test failed'
        fi
        case $scenario in
            partial|start|stop|destroy|gateway|internet|dns) assert_contains "$sandbox/pct" 'destroy 123 --purge' ;;
            metadata|empty|download|create) assert_absent "$sandbox/pct" 'destroy' ;;
            success) assert_contains "$sandbox/out" 'LXC verification passed.' ;;
        esac
        assert_absent "$sandbox/out" 'unbound variable'
    done
    ;;
*) fail "Unknown case $2" ;;
esac
