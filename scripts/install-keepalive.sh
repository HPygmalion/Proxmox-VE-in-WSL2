#!/usr/bin/env bash
set -euo pipefail
install -d -m 0755 /usr/local/sbin /etc/systemd/system
cat >/usr/local/sbin/pve-anchor <<'EOF'
#!/bin/sh
exec /usr/bin/sleep infinity
EOF
chmod 0755 /usr/local/sbin/pve-anchor
cat >/usr/local/sbin/pve-healthcheck <<'EOF'
#!/usr/bin/env bash
set -u
# Serialize manual checks and timer invocations; never stop running guests.
exec 9>/run/pve-healthcheck.lock
flock -n 9 || exit 0
failed=0
report_failure() { logger -t pve-healthcheck "$*"; failed=1; }
if [[ -x /usr/local/lib/pve-wsl/update-hosts ]]; then
    /usr/local/lib/pve-wsl/update-hosts || report_failure 'Could not update hostname mapping'
fi
for service in pve-cluster lxcfs pvestatd pvedaemon pveproxy; do
    if ! systemctl is-active --quiet "$service"; then
        logger -t pve-healthcheck "Starting inactive service: $service"
        systemctl start "$service" || report_failure "Could not start $service"
    fi
done
# pve-guests is deliberately not restarted: that could affect running guests.
if [[ -f /etc/dnsmasq.d/pve-wsl.conf ]]; then
    sysctl -qw net.ipv4.ip_forward=1 || report_failure 'Could not enable forwarding'
    if ! ip link show vmbr0 >/dev/null 2>&1; then
        ifup --force vmbr0 || report_failure 'Could not restore vmbr0'
    fi
    subnet=$(sed -n 's/^# subnet=//p' /etc/dnsmasq.d/pve-wsl.conf)
    if [[ $subnet =~ ^([0-9]{1,3}\.){3}0/24$ ]]; then
        if ! iptables -t nat -C POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE 2>/dev/null; then
            iptables -t nat -A POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE || report_failure 'Could not restore NAT'
        fi
    else
        report_failure 'Invalid or missing managed NAT subnet'
    fi
    systemctl is-active --quiet dnsmasq || systemctl start dnsmasq || report_failure 'Could not start dnsmasq'
fi
code=$(curl -sk --connect-timeout 3 --max-time 8 -o /dev/null -w '%{http_code}' https://127.0.0.1:8006/api2/json/version) || code=000
case "$code" in
    200|401) ;;
    *)
        logger -t pve-healthcheck "API unhealthy (HTTP $code); restarting API services"
        systemctl restart pvedaemon pveproxy || report_failure 'Could not restart API services'
        ready=0
        for attempt in 1 2 3 4 5; do
            code=$(curl -sk --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' https://127.0.0.1:8006/api2/json/version) || code=000
            case "$code" in 200|401) ready=1; break ;; esac
            sleep 2
        done
        [[ $ready == 1 ]] || report_failure "API still unavailable after recovery (HTTP $code)"
        ;;
esac
exit "$failed"
EOF
chmod 0755 /usr/local/sbin/pve-healthcheck
cat >/etc/systemd/system/pve-wsl-healthcheck.service <<'EOF'
[Unit]
Description=Check Proxmox VE services, NAT and API without stopping guests
Wants=network-online.target
After=network-online.target pve-cluster.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-healthcheck
TimeoutStartSec=90
EOF
cat >/etc/systemd/system/pve-wsl-healthcheck.timer <<'EOF'
[Unit]
Description=Check Proxmox VE every minute
[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now pve-wsl-healthcheck.timer
/usr/local/sbin/pve-healthcheck
