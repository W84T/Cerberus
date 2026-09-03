#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root. Try: sudo $0"
  exit 1
fi

SRC="/home/w84t/Cerberus/core.sh"
BINDIR="/opt/cerberus"
CORE="$BINDIR/core.sh"
CONFIG="$BINDIR/config"

[[ -f "$SRC" ]] || { echo "Patched core.sh not found at $SRC"; exit 1; }

echo "=== Cerberus Patch Install ==="
echo ""

systemctl stop cerberus-watchdog.timer 2>/dev/null || true
systemctl stop cerberus-watchdog.service 2>/dev/null || true
systemctl stop cerberus-refresh.timer 2>/dev/null || true

chattr -i "$CORE" 2>/dev/null || true
cp "$SRC" "$CORE"
chmod +x "$CORE"
echo "Installed patched core.sh"

source "$CONFIG"

for loc in "${BACKUP_LOCATIONS[@]}"; do
  chattr -i "$loc" 2>/dev/null || true
  cp "$CORE" "$loc"
  chmod 644 "$loc"
  chattr +i "$loc"
  echo "Backup synced: $loc"
done

chattr -i /etc/hosts 2>/dev/null || true
chmod 644 /etc/hosts
chattr +i /etc/hosts
echo "hosts perms: $(ls -l /etc/hosts | awk '{print $1}')"

echo "Re-applying rules..."
"$CORE" apply

systemctl start cerberus-refresh.timer 2>/dev/null || true
systemctl start cerberus-watchdog.timer 2>/dev/null || true

echo ""
echo "=== CERBERUS chain ==="
iptables -L CERBERUS -n
echo ""
echo "NOTE: blanket UDP/443 (QUIC) and generic port-53 DNS drops removed."
echo "Encrypted DNS (DoH/DoT/DoQ) to public resolvers is still blocked."
