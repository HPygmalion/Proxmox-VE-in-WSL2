#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
awk "/^cat >\/usr\/local\/sbin\/pve-healthcheck /{capture=1;next} capture && /^EOF$/{exit} capture{print}" "$root/scripts/install-keepalive.sh" >"$tmp/check.sh"
[[ -s $tmp/check.sh ]]
bash -n "$tmp/check.sh"
# Execute only a sandboxed copy; redirect all absolute managed paths and stub
# every host-affecting operation. No live systemctl/network changes occur.
sed -i "s|/run/pve-healthcheck.lock|$tmp/check.lock|;s|/usr/local/lib/pve-wsl/update-hosts|$tmp/no-hosts|;s|/etc/dnsmasq.d/pve-wsl.conf|$tmp/no-nat|" "$tmp/check.sh"
mkdir "$tmp/bin"
cat >"$tmp/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$CALLS"
exit 0
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
printf '%s' "$HTTP_CODE"
EOF
cat >"$tmp/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls"
for code in 200 401; do
    : >"$CALLS"
    HTTP_CODE=$code bash "$tmp/check.sh"
    ! grep -q restart "$CALLS"
done
: >"$CALLS"
if HTTP_CODE=503 bash "$tmp/check.sh"; then echo 'FAIL: persistent HTTP 503 accepted'; exit 1; fi
grep -q 'restart pvedaemon pveproxy' "$CALLS"
echo 'PASS: healthy 200/401 preserved, persistent 503 recovery fails honestly'
