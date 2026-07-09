#!/bin/bash
set -euo pipefail

log() { echo "[blocker-unlock] $(date '+%H:%M:%S') $*"; }
UNLOCK_FILE="/opt/blocker/.unlock"

log "Unlock triggered"

if lsattr /etc/hosts 2>/dev/null | grep -q '^....i'; then
  chattr -i /etc/hosts 2>/dev/null || true
  log "Removed immutable flag from /etc/hosts"
fi

if grep -q "# Blocked domains - Blocker" /etc/hosts 2>/dev/null; then
  sed -i '/# Blocked domains - Blocker/,$d' /etc/hosts 2>/dev/null || true
  sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' /etc/hosts 2>/dev/null || true
  log "Restored original hosts file"
fi

iptables -D OUTPUT -j BLOCKER 2>/dev/null || true
iptables -F BLOCKER 2>/dev/null || true
iptables -X BLOCKER 2>/dev/null || true
log "Removed iptables rules"

systemctl stop blocker-watchdog.timer 2>/dev/null || true
systemctl disable blocker-watchdog.timer 2>/dev/null || true
systemctl stop blocker-watchdog.service 2>/dev/null || true
systemctl stop blocker.service 2>/dev/null || true
log "Stopped blocker services"

rm -f "$UNLOCK_FILE"

log "Unlock complete"
