#!/bin/bash
# Cerberus Uninstaller
#
# WARNING: This script attempts to completely remove Cerberus from a system
# that installed it. Because Cerberus is designed to be self-hardening and
# self-restoring, removal must proceed in a strict order to defeat the
# self-healing watchers before they re-arm anything.
#
# This is provided as a safety exit in case Cerberus misbehaves on a machine.
# It reverses everything setup.sh does.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

BINDIR="/opt/cerberus"

confirm() {
  echo ""
  echo "This will COMPLETELY remove Cerberus from this machine."
  echo "It will NOT be possible to recover/restore it afterwards."
  echo ""
  read -r -p "Type yes to continue: " a
  [[ "$a" == "yes" ]]
}

if ! confirm; then
  echo "Aborted."
  exit 1
fi

# ── source installed config for randomized unit names & backup paths ──
CONFIG="$BINDIR/config"
if [[ -f "$CONFIG" ]]; then
  set +e
  source "$CONFIG"
  set -e
fi

UNITS=()
if [[ -n "${UNIT_CORE:-}" ]]; then
  UNITS+=(
    "$UNIT_CORE" "$UNIT_RESOLVER" "$UNIT_WD" "$UNIT_WD_TIMER"
    "$UNIT_WDI" "$UNIT_WDW" "$UNIT_WDW_TIMER"
    "$UNIT_REFRESH" "$UNIT_REFRESH_TIMER"
    "$UNIT_BLOCKPAGE" "$UNIT_BLOCKPAGE_HTTPS"
  )
fi
for u in cerberus.service cerberus-resolver.service cerberus-watchdog.service \
  cerberus-watchdog.timer cerberus-watchdog2.service cerberus-watchdog-watcher.service \
  cerberus-watchdog-watcher.timer cerberus-refresh.service cerberus-refresh.timer \
  cerberus-blockpage.service cerberus-blockpage-https.service; do
  [[ " ${UNITS[*]} " != *" $u "* ]] && UNITS+=("$u")
done

# ── STEP 1: Stop & disable ALL units repeatedly (watcher re-arms the others) ──
echo "== Stopping and disabling Cerberus services =="
for i in 1 2 3 4 5; do
  for u in "${UNITS[@]}"; do
    [[ -f "/etc/systemd/system/$u" ]] || continue
    systemctl disable --now "$u" 2>/dev/null || true
  done
  for u in "${UNITS[@]}"; do
    [[ -f "/etc/systemd/system/$u" ]] && systemctl mask "$u" 2>/dev/null || true
  done
done
systemctl daemon-reload 2>/dev/null || true

# ── STEP 2: Kill any surviving cerberus processes ──
echo "== Killing Cerberus processes =="
pkill -9 -f "/opt/cerberus/" 2>/dev/null || true
pkill -9 -f "watchdog.py" 2>/dev/null || true
pkill -9 -f "watcher.py" 2>/dev/null || true
pkill -9 -f "resolver.py" 2>/dev/null || true
pkill -9 -f "blockpage.py" 2>/dev/null || true

# ── STEP 3: Clear immutable flags ──
echo "== Clearing immutable flags =="
clear_flags() {
  local f
  for f in "$@"; do
    [[ -e "$f" ]] && chattr -i "$f" 2>/dev/null || true
    [[ -e "$f" ]] && chattr -a "$f" 2>/dev/null || true
  done
}
find "$BINDIR" -type f 2>/dev/null | while read -r f; do clear_flags "$f"; done
clear_flags \
  "$BINDIR/config" "$BINDIR/core.sh" "$BINDIR/cli.sh" \
  "$BINDIR/custom-block.txt" "$BINDIR/blockpage.py" \
  "$BINDIR/blockpage.crt" "$BINDIR/blockpage.key" \
  "$BINDIR/resolver.py" "$BINDIR/blocklist_updater.py" \
  "$BINDIR/watchdog.py" "$BINDIR/watcher.py"

for loc in "${BACKUP_LOCATIONS[@]:-}"; do
  [[ -n "$loc" ]] && clear_flags "$loc"
done
for loc in /usr/share/man/man3/.nss_cache.so /var/lib/cerberus/.journal \
  /home/*/.config/systemd/user/.helper /home/*/.local/share/applications/.update; do
  clear_flags "$loc"
done
find /var/lib/cerberus -type f 2>/dev/null | while read -r f; do clear_flags "$f"; done

# ── STEP 4: Remove firewall rules (filter + any leftover penalty chain) ──
echo "== Removing firewall rules =="
iptables -D OUTPUT -j CERBERUS 2>/dev/null || true
iptables -F CERBERUS 2>/dev/null || true
iptables -X CERBERUS 2>/dev/null || true
iptables -D OUTPUT -j CERBERUS_PENALTY 2>/dev/null || true
iptables -F CERBERUS_PENALTY 2>/dev/null || true
iptables -X CERBERUS_PENALTY 2>/dev/null || true
iptables -t nat -D OUTPUT -j CERBERUS_NAT 2>/dev/null || true
iptables -t nat -F CERBERUS_NAT 2>/dev/null || true
iptables -t nat -X CERBERUS_NAT 2>/dev/null || true

# ── STEP 5: Restore DNS ──
echo "== Restoring DNS =="
rm -f /etc/NetworkManager/conf.d/dns.conf 2>/dev/null || true
rm -f /etc/resolv.conf 2>/dev/null || true
systemctl restart NetworkManager 2>/dev/null || true
sleep 2
if [[ ! -e /etc/resolv.conf ]]; then
  printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
fi

# ── STEP 6: Remove systemd unit files & masks ──
echo "== Removing service files =="
for u in "${UNITS[@]}"; do
  if [[ -e "/etc/systemd/system/$u" ]]; then
    systemctl unmask "$u" 2>/dev/null || true
    systemctl disable "$u" 2>/dev/null || true
    rm -f "/etc/systemd/system/$u" 2>/dev/null || true
  fi
done
rm -rf /etc/systemd/system/cerberus* 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true

# ── STEP 7: Remove sudoers rule ──
echo "== Removing sudoers rule =="
rm -f /etc/sudoers.d/99-cerberus 2>/dev/null || true

# ── STEP 8: Remove hidden backups & install dirs ──
echo "== Removing Cerberus files =="
for loc in "${BACKUP_LOCATIONS[@]:-}"; do
  [[ -n "$loc" ]] && rm -rf "$loc" 2>/dev/null || true
done
for loc in /usr/share/man/man3/.nss_cache.so /var/lib/cerberus/.journal \
  /home/*/.config/systemd/user/.helper /home/*/.local/share/applications/.update; do
  rm -rf "$loc" 2>/dev/null || true
done
rm -rf /opt/cerberus 2>/dev/null || true
rm -rf /var/lib/cerberus 2>/dev/null || true
rm -f /usr/local/bin/cerberus 2>/dev/null || true

# ── STEP 9: Restore Firefox DoH override we added ──
echo "== Restoring Firefox DoH =="
for profile in /home/*/.mozilla/firefox/*.default*/prefs.js; do
  if [[ -f "$profile" ]] && grep -q 'network.trr.mode' "$profile"; then
    sed -i '/network.trr.mode/d' "$profile" 2>/dev/null || true
  fi
done

# ── STEP 10: Delete the cerberus-resolve system user ──
echo "== Removing system user =="
if id cerberus-resolve &>/dev/null; then
  userdel cerberus-resolve 2>/dev/null || true
fi

echo ""
echo "======================================"
echo "Cerberus removal complete."
echo "======================================"
