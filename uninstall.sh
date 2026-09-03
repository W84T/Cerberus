#!/bin/bash
# Cerberus Content Filter - uninstaller.
#
# Reverses everything setup.sh does and removes Cerberus from the machine:
#   - stops/disables all systemd units (across installs, by scanning)
#   - flushes/removes all iptables+ip6tables enforcement chains
#   - clears immutable flags and removes all hidden self-healing backups
#   - removes files, system user, sudoers rule, symlink, directories
#   - restores DNS to the previous NetworkManager-managed resolv.conf
#   - undoes the Firefox DoH preference and faillock config it added
#
# Run as root or with sudo.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root. Try: sudo $0"
  exit 1
fi

BINDIR="/opt/cerberus"
VARLIB="/var/lib/cerberus"

echo "=== Cerberus Uninstaller ==="

# ── load installed config for runtime facts (unit mapping, backups, penalty) ──
INSTALLED_CONFIG="$BINDIR/config"
BACKUP_LOCATIONS=()
declare -A UNITMAP=()
if [[ -f "$INSTALLED_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$INSTALLED_CONFIG"
  for var in UNIT_CORE UNIT_RESOLVER UNIT_WD UNIT_WD_TIMER UNIT_WDI UNIT_WDW \
             UNIT_WDW_TIMER UNIT_REFRESH UNIT_REFRESH_TIMER UNIT_BLOCKPAGE \
             UNIT_BLOCKPAGE_HTTPS; do
    [[ -n "${!var:-}" ]] && UNITMAP["$var"]="${!var}"
  done
  echo "Loaded install ID ${INSTALL_ID:-<none>} from $INSTALLED_CONFIG"
else
  echo "NOTE: $INSTALLED_CONFIG not found; scanning systemd for leftover units."
fi

# ── collect every unit the resolver may have created ─────────────────────────
# Current install's randomized units plus any legacy cerberus-* names from older
# versions and whatever is actually present in /etc/systemd/system today.
units=()
if [[ -n "${UNITMAP[UNIT_CORE]:-}" ]]; then units+=("${UNITMAP[@]}"); fi
units+=( cerberus.service cerberus-resolver.service cerberus-watchdog.service \
  cerberus-watchdog.timer cerberus-watchdog2.service cerberus-watchdog-watcher.service \
  cerberus-watchdog-watcher.timer cerberus-refresh.service cerberus-refresh.timer \
  cerberus-blockpage.service cerberus-blockpage-https.service )
# De-duplicate
readarray -t units < <(printf '%s\n' "${units[@]}" | sort -u | grep -v '^$')

# ── stop & disable units ─────────────────────────────────────────────────────
for u in "${units[@]}"; do
  if [[ -f "/etc/systemd/system/$u" ]]; then
    systemctl disable --now "$u" 2>/dev/null || \
      systemctl stop "$u" 2>/dev/null || true
    rm -f "/etc/systemd/system/$u"
    echo "Removed unit $u"
  fi
done
systemctl daemon-reload

# ── remove iptables / ip6tables chains ───────────────────────────────────────
# CERBERUS, CERBERUS_NAT (from core.sh) and CERBERUS_PENALTY (penalty system)
ip6chains=( CERBERUS CERBERUS_NAT CERBERUS_PENALTY )
for ch in "${ip6chains[@]}"; do
  iptables -D OUTPUT -j "$ch" 2>/dev/null || true
  iptables -t nat -D OUTPUT -j "$ch" 2>/dev/null || true
  iptables -F "$ch" 2>/dev/null || true
  iptables -t nat -F "$ch" 2>/dev/null || true
  iptables -X "$ch" 2>/dev/null || true
  iptables -t nat -X "$ch" 2>/dev/null || true
done
if command -v ip6tables >/dev/null 2>&1; then
  for ch in CERBERUS CERBERUS_NAT CERBERUS_PENALTY; do
    ip6tables -D OUTPUT -j "$ch" 2>/dev/null || true
    ip6tables -F "$ch" 2>/dev/null || true
    ip6tables -X "$ch" 2>/dev/null || true
  done
fi
echo "Removed iptables chains."

# ── clear immutable flags & remove hidden backups ────────────────────────────
protected=( core.sh cli.sh config custom-block.txt blockpage.py blockpage.crt \
  blockpage.key resolver.py blocklist_updater.py watchdog.py watcher.py AI_POLICY.md )
for f in "${protected[@]}"; do
  chattr -i "$BINDIR/$f" 2>/dev/null || true
done
for loc in "${BACKUP_LOCATIONS[@]}"; do
  chattr -i "$loc" 2>/dev/null || true
  rm -f "$loc" 2>/dev/null || true
done
echo "Cleared immutable flags and removed hidden backups."

# ── restore resolv.conf / NetworkManager ─────────────────────────────────────
# setup.sh wrote a static resolv.conf and a dns.conf; restore NetworkManager's
# default DNS handling and remove the Cerberus-specific dns.conf.
if [[ -f /etc/NetworkManager/conf.d/dns.conf ]]; then
  content=$(cat /etc/NetworkManager/conf.d/dns.conf 2>/dev/null || true)
  # Only remove if it's the exact file Cerberus wrote (safer than clobbering a
  # user's own config).
  if [[ "$content" == *"dns=default"* ]] && [[ "$content" == "[main]"* ]] \
     && ! grep -qE '=(dnsmasq|systemd-resolved|unbound)' /etc/NetworkManager/conf.d/dns.conf 2>/dev/null; then
    rm -f /etc/NetworkManager/conf.d/dns.conf
    echo "Removed /etc/NetworkManager/conf.d/dns.conf"
  fi
fi
rm -f /etc/resolv.conf
systemctl restart NetworkManager 2>/dev/null || true
echo "Restored NetworkManager DNS handling."

# ── undo Firefox DoH preference added by setup.sh ────────────────────────────
# setup.sh only appends the line when it is absent; remove that exact line from
# every profile so we restore the prior state.
for profile in /home/*/.mozilla/firefox/*.default*/prefs.js; do
  if [[ -f "$profile" ]] && grep -q 'user_pref("network.trr.mode", 5);' "$profile" 2>/dev/null; then
    sed -i '/user_pref("network.trr.mode", 5);/d' "$profile"
    echo "Restored DoH setting in $profile"
  fi
done

# ── remove faillock config (installed by setup.sh) ───────────────────────────
if [[ -f /etc/security/faillock.conf ]] && grep -q '^deny = 3$' /etc/security/faillock.conf 2>/dev/null \
   && grep -q '^unlock_time = 600$' /etc/security/faillock.conf 2>/dev/null; then
  rm -f /etc/security/faillock.conf
  echo "Removed /etc/security/faillock.conf"
fi

# ── remove sudoers rule ──────────────────────────────────────────────────────
if [[ -f /etc/sudoers.d/99-cerberus ]]; then
  rm -f /etc/sudoers.d/99-cerberus
  echo "Removed /etc/sudoers.d/99-cerberus"
fi

# ── remove system user, symlink, directories ─────────────────────────────────
if id cerberus-resolve &>/dev/null; then
  userdel -r cerberus-resolve 2>/dev/null || userdel cerberus-resolve 2>/dev/null || true
  echo "Removed cerberus-resolve system user"
fi
rm -f /usr/local/bin/cerberus
rm -rf "$BINDIR" "$VARLIB"
echo "Removed $BINDIR, $VARLIB, /usr/local/bin/cerberus."

echo ""
echo "=== Cerberus uninstalled ==="
