#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root. Try: sudo $0"
  exit 1
fi

SRC="/home/w84t/Cerberus/config"
CONFIG="/opt/cerberus/config"

[[ -f "$SRC" ]] || { echo "Fixed config not found at $SRC"; exit 1; }

echo "=== Cerberus Config Fix ==="
echo ""

systemctl stop cerberus-watchdog.timer 2>/dev/null || true
systemctl stop cerberus-refresh.timer 2>/dev/null || true

chattr -i "$CONFIG" 2>/dev/null || true
cp "$SRC" "$CONFIG"
chmod 644 "$CONFIG"
chattr +i "$CONFIG"
echo "Installed fixed config (dead URLs adult/social/drug -> live lists)"

echo "Re-downloading blocklists with fixed URLs..."
/opt/cerberus/core.sh refresh

systemctl start cerberus-refresh.timer 2>/dev/null || true
systemctl start cerberus-watchdog.timer 2>/dev/null || true

echo ""
echo "=== Verification ==="
echo "hosts entries: $(grep -c '^127\.0\.0\.1' /etc/hosts)"
echo "facebook.com -> $(getent hosts facebook.com | head -1)"
echo "youtube.com  -> $(getent hosts youtube.com | head -1)"
echo "xvideos.com  -> $(getent hosts xvideos.com | head -1)"
