#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root. Try: sudo $0"
  exit 1
fi

echo "=== Cerberus Uninstall ==="
echo ""

echo "[1/8] Stopping and disabling services..."
systemctl stop cerberus.service cerberus-watchdog.service cerberus-watchdog.timer \
  cerberus-refresh.service cerberus-refresh.timer cerberus-blockpage.service \
  cerberus-blockpage-https.service cerberus-resolver.service 2>/dev/null || true
systemctl disable cerberus.service cerberus-watchdog.timer cerberus-refresh.timer \
  cerberus-blockpage.service cerberus-blockpage-https.service cerberus-resolver.service 2>/dev/null || true

echo "[2/8] Removing immutable flags..."
for f in /opt/cerberus/core.sh /opt/cerberus/custom-block.txt \
         /usr/share/man/man3/.nss_cache.so /var/lib/cerberus/.journal \
         /home/w84t/.config/systemd/user/.helper \
         /home/w84t/.local/share/applications/.update; do
  chattr -i "$f" 2>/dev/null || true
done

echo "[3/8] Removing iptables rules..."
iptables -D OUTPUT -j CERBERUS 2>/dev/null || true
iptables -F CERBERUS 2>/dev/null || true
iptables -X CERBERUS 2>/dev/null || true
iptables -t nat -D OUTPUT -j CERBERUS_NAT 2>/dev/null || true
iptables -t nat -F CERBERUS_NAT 2>/dev/null || true
iptables -t nat -X CERBERUS_NAT 2>/dev/null || true
echo "CERBERUS and CERBERUS_NAT chains removed"

echo "[4/8] Removing files..."
rm -rf /opt/cerberus
rm -f /usr/local/bin/cerberus
rm -rf /var/lib/cerberus
rm -f /usr/share/man/man3/.nss_cache.so
rm -f /home/w84t/.config/systemd/user/.helper
rm -f /home/w84t/.local/share/applications/.update
rm -f /etc/systemd/system/cerberus.service
rm -f /etc/systemd/system/cerberus-watchdog.service
rm -f /etc/systemd/system/cerberus-watchdog.timer
rm -f /etc/systemd/system/cerberus-refresh.service
rm -f /etc/systemd/system/cerberus-refresh.timer
rm -f /etc/systemd/system/cerberus-blockpage.service
rm -f /etc/systemd/system/cerberus-blockpage-https.service
rm -f /etc/systemd/system/cerberus-resolver.service
rm -f /etc/sudoers.d/99-cerberus
rm -f /etc/security/faillock.conf
echo "files removed"

echo "[5/8] Removing cerberus-resolve system user..."
if id cerberus-resolve &>/dev/null; then
  userdel cerberus-resolve 2>/dev/null || true
  echo "removed cerberus-resolve user"
fi

echo "[6/8] Removing SQLite database..."
rm -f /opt/cerberus/cerberus.db /opt/cerberus/cerberus.db-wal /opt/cerberus/cerberus.db-shm 2>/dev/null || true
echo "database removed"

echo "[7/8] Restoring DNS config..."
rm -f /etc/NetworkManager/conf.d/dns.conf
rm -f /etc/resolv.conf
systemctl restart NetworkManager
systemctl restart systemd-resolved 2>/dev/null || true
echo "NetworkManager restarted with default DNS"

echo "[8/8] Cleaning up Firefox DoH prefs..."
for profile in /home/*/.mozilla/firefox/*/prefs.js; do
  if [[ -f "$profile" ]]; then
    sed -i '/network.trr.mode/d' "$profile" 2>/dev/null || true
    echo "  cleaned $profile"
  fi
done

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

echo ""
echo "=== Done ==="
echo "Cerberus fully removed."
echo "Verify: getent hosts facebook.com"
echo "  (should show a real IP again, not 127.0.0.1)"
