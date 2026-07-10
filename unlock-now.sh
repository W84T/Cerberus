#!/bin/bash
set -euo pipefail

log() { echo "[cerberus-unlock] $(date '+%H:%M:%S') $*"; }
UNLOCK_FILE="/opt/cerberus/.unlock"

log "Unlock triggered"

if lsattr /etc/hosts 2>/dev/null | grep -q '^....i'; then
  chattr -i /etc/hosts 2>/dev/null || true
  log "Removed immutable flag from /etc/hosts"
fi

if grep -q "# Blocked domains - Cerberus" /etc/hosts 2>/dev/null; then
  sed -i '/# Blocked domains - Cerberus/,$d' /etc/hosts 2>/dev/null || true
  sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' /etc/hosts 2>/dev/null || true
  log "Restored original hosts file"
fi

iptables -D OUTPUT -j CERBERUS 2>/dev/null || true
iptables -F CERBERUS 2>/dev/null || true
iptables -X CERBERUS 2>/dev/null || true
log "Removed iptables rules"

systemctl stop cerberus-watchdog.timer 2>/dev/null || true
systemctl disable cerberus-watchdog.timer 2>/dev/null || true
systemctl stop cerberus-watchdog.service 2>/dev/null || true
systemctl stop cerberus.service 2>/dev/null || true
log "Stopped cerberus services"

rm -f "$UNLOCK_FILE"

log "Unlock complete"
