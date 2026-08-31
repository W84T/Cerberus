#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root. Try: sudo $0"
  exit 1
fi

BINDIR="/opt/cerberus"

# ── determine the installing (human) user ─────────────────────
# Run as root (via sudo or as root). Prefer the real invoking user so the
# sudoers rule and per-user backup paths work on any machine, not just w84t's.
INSTALL_USER=""
if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
  INSTALL_USER="$SUDO_USER"
else
  # Fall back to the first active graphical session user, then root
  INSTALL_USER=$(loginctl list-sessions --no-legend 2>/dev/null | awk 'NF>=4 && $4!="-"{print $3; exit}')
fi
[[ -z "$INSTALL_USER" ]] && INSTALL_USER="root"
INSTALL_HOME=$(getent passwd "$INSTALL_USER" | cut -d: -f6)
[[ -z "$INSTALL_HOME" ]] && INSTALL_HOME="/root"

echo "=== Cerberus Setup v2 (SQLite DNS) ==="
echo "Installing for user: $INSTALL_USER (home: $INSTALL_HOME)"
echo ""

# ── clear immutable flags ──────────────────────────────────────
for f in "$BINDIR/core.sh" "$BINDIR/cli.sh" "$BINDIR/config" "$BINDIR/custom-block.txt" \
         "$BINDIR/blockpage.py" "$BINDIR/blockpage.crt" "$BINDIR/blockpage.key" \
         "$BINDIR/resolver.py" "$BINDIR/blocklist_updater.py" "$BINDIR/watchdog.py" \
         "$BINDIR/watcher.py" "$BINDIR/AI_POLICY.md"; do
  chattr -i "$f" 2>/dev/null || true
done

# ── dependencies ──────────────────────────────────────────────
if ! command -v curl &>/dev/null; then echo "Installing curl...";  pacman -Sy --noconfirm curl; fi
if ! command -v openssl &>/dev/null; then echo "Installing openssl..."; pacman -Sy --noconfirm openssl; fi
if ! python3 -c "import dnslib" &>/dev/null; then echo "Installing python-dnslib..."; pacman -S --noconfirm python-dnslib; fi

# ── system user for resolver ──────────────────────────────────
if ! id cerberus-resolve &>/dev/null; then
  useradd -r -s /usr/bin/nologin -d /opt/cerberus cerberus-resolve
  echo "Created cerberus-resolve system user"
fi
RESOLVER_UID=$(id -u cerberus-resolve)

# ── directories ───────────────────────────────────────────────
mkdir -p "$BINDIR" /var/lib/cerberus /etc/NetworkManager/conf.d
# Let the unprivileged resolver create/write the penalty signal file even if it
# is deleted after a reboot/cleanup (it runs as cerberus-resolve, not root).
chgrp cerberus-resolve /var/lib/cerberus 2>/dev/null || true
chmod 775 /var/lib/cerberus 2>/dev/null || true
install -o cerberus-resolve -g cerberus-resolve -m 664 /dev/null /var/lib/cerberus/penalty_signal 2>/dev/null || true
rm -f /usr/local/bin/cerberus

# ── copy source files ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Preserve an existing per-install ID across reinstalls (unit names must stay stable)
EXISTING_INSTALL_ID=""
if [[ -f "$BINDIR/config" ]] && grep -qE '^INSTALL_ID=' "$BINDIR/config"; then
  EXISTING_INSTALL_ID=$(grep -E '^INSTALL_ID=' "$BINDIR/config" | tail -1 | cut -d= -f2)
fi
  cp "$SCRIPT_DIR/config"       "$BINDIR/config"
  cp "$SCRIPT_DIR/core.sh"      "$BINDIR/core.sh"
# Rewrite any hardcoded home paths in BACKUP_LOCATIONS to this machine's user,
# so per-user backup copies are portable (fall back gracefully if old templates)
sed -i "s#/home/[a-zA-Z0-9_.-]*/.config/systemd/user/.helper#$INSTALL_HOME/.config/systemd/user/.helper#g" "$BINDIR/config"
sed -i "s#/home/[a-zA-Z0-9_.-]*/.local/share/applications/.update#$INSTALL_HOME/.local/share/applications/.update#g" "$BINDIR/config"
cp "$SCRIPT_DIR/cli.sh"       "$BINDIR/cli.sh"
cp "$SCRIPT_DIR/blockpage.py" "$BINDIR/blockpage.py"
cp "$SCRIPT_DIR/resolver.py"  "$BINDIR/resolver.py"
cp "$SCRIPT_DIR/blocklist_updater.py" "$BINDIR/blocklist_updater.py"
cp "$SCRIPT_DIR/watchdog.py"  "$BINDIR/watchdog.py"
[[ -f "$SCRIPT_DIR/custom-block.txt" ]] && cp "$SCRIPT_DIR/custom-block.txt" "$BINDIR/custom-block.txt" || true

# ── permissions ───────────────────────────────────────────────
chmod +x "$BINDIR/core.sh" "$BINDIR/cli.sh" "$BINDIR/blockpage.py" "$BINDIR/resolver.py" "$BINDIR/blocklist_updater.py"
chmod 644 "$BINDIR/config" "$BINDIR/custom-block.txt"
ln -sf "$BINDIR/cli.sh" /usr/local/bin/cerberus

# ── sudoers rule ─────────────────────────────────────────────
cat > /etc/sudoers.d/99-cerberus << SUDOEOF
$INSTALL_USER ALL=(ALL) NOPASSWD: /opt/cerberus/cli.sh, /opt/cerberus/core.sh, /usr/bin/iptables -L CERBERUS -n, /usr/bin/iptables -L CERBERUS_NAT -n
Defaults:$INSTALL_USER timestamp_timeout=0
SUDOEOF
chmod 440 /etc/sudoers.d/99-cerberus
visudo -cf /etc/sudoers.d/99-cerberus

# ── DNS: point system at the Cerberus resolver with upstream fallback ──
cat > /etc/NetworkManager/conf.d/dns.conf << 'NMEOF'
[main]
dns=default
NMEOF
rm -f /etc/resolv.conf
printf 'nameserver 127.0.0.1\nnameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf

# ── SSL self-signed cert ──────────────────────────────────────
if [[ ! -f "$BINDIR/blockpage.crt" ]]; then
  openssl req -x509 -newkey rsa:2048 -keyout "$BINDIR/blockpage.key" \
    -out "$BINDIR/blockpage.crt" -days 3650 -nodes \
    -subj "/CN=Cerberus" 2>/dev/null
  echo "Self-signed cert created"
fi

# ── source config for DB_PATH etc ─────────────────────────────
source "$BINDIR/config"

# ── randomized per-install unit naming ────────────────────────
# Each installation gets a unique random prefix so service names differ
# across machines. The mapping is stored in config so every component can
# re-discover its units (keeps self-healing working). If INSTALL_ID is
# already set (reinstall of same box), keep it stable.
if [[ -z "${INSTALL_ID:-}" ]]; then
  if [[ -n "$EXISTING_INSTALL_ID" ]]; then
    INSTALL_ID="$EXISTING_INSTALL_ID"
  else
    INSTALL_ID="$(head -c4 /dev/urandom | od -An -tx4 | tr -dc 'a-f0-9' | head -c8)"
    [[ -z "$INSTALL_ID" ]] && INSTALL_ID="cb"$(date +%s)
  fi
fi
UNIT_CORE="${INSTALL_ID}.service"
UNIT_RESOLVER="${INSTALL_ID}-rs.service"
UNIT_WD="${INSTALL_ID}-wd.service"
UNIT_WD_TIMER="${INSTALL_ID}-wd.timer"
UNIT_WDI="${INSTALL_ID}-wdi.service"
UNIT_WDW="${INSTALL_ID}-wdw.service"
UNIT_WDW_TIMER="${INSTALL_ID}-wdw.timer"
UNIT_REFRESH="${INSTALL_ID}-rf.service"
UNIT_REFRESH_TIMER="${INSTALL_ID}-rf.timer"
UNIT_BLOCKPAGE="${INSTALL_ID}-bp.service"
UNIT_BLOCKPAGE_HTTPS="${INSTALL_ID}-bps.service"

# Persist the mapping into config (idempotent)
UNIT_BLOCK_START="# ==BEGIN RANDOMIZED UNIT MAPPING=="
if ! grep -qF "$UNIT_BLOCK_START" "$BINDIR/config"; then
  cat >> "$BINDIR/config" << EOF

$UNIT_BLOCK_START
INSTALL_ID=$INSTALL_ID
UNIT_CORE=$UNIT_CORE
UNIT_RESOLVER=$UNIT_RESOLVER
UNIT_WD=$UNIT_WD
UNIT_WD_TIMER=$UNIT_WD_TIMER
UNIT_WDI=$UNIT_WDI
UNIT_WDW=$UNIT_WDW
UNIT_WDW_TIMER=$UNIT_WDW_TIMER
UNIT_REFRESH=$UNIT_REFRESH
UNIT_REFRESH_TIMER=$UNIT_REFRESH_TIMER
UNIT_BLOCKPAGE=$UNIT_BLOCKPAGE
UNIT_BLOCKPAGE_HTTPS=$UNIT_BLOCKPAGE_HTTPS
# ==END RANDOMIZED UNIT MAPPING==
EOF
  echo "Randomized unit prefix: $INSTALL_ID"
else
  echo "Reusing existing unit prefix: $INSTALL_ID"
fi

# ── systemd services (randomized names) ───────────────────────

# Core apply
cat > /etc/systemd/system/"$UNIT_CORE" << 'UNITEOF'
[Unit]
Description=Cerberus Content Filter
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/opt/cerberus/core.sh apply
RemainAfterExit=no
StandardOutput=journal
[Install]
WantedBy=multi-user.target
UNITEOF

# Watchdog (60s timer oneshot)
cat > /etc/systemd/system/"$UNIT_WD" << 'WDSVCEOF'
[Unit]
Description=Cerberus Watchdog
After=network.target
[Service]
Type=oneshot
ExecStart=/opt/cerberus/core.sh check
SuccessExitStatus=1 64 65 66
StandardOutput=journal
WDSVCEOF

cat > /etc/systemd/system/"$UNIT_WD_TIMER" << 'WDTIMEREOF'
[Unit]
Description=Cerberus Watchdog Timer
[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=5
[Install]
WantedBy=timers.target
WDTIMEREOF

# Instant watchdog (event-driven, sub-second reaction)
cat > /etc/systemd/system/"$UNIT_WDI" << WD2EOF
[Unit]
Description=Cerberus Instant Watchdog (event-driven enforcement)
After=network.target $UNIT_RESOLVER
Wants=$UNIT_RESOLVER

[Service]
Type=simple
ExecStart=/usr/bin/python3 $BINDIR/watchdog.py
Restart=always
RestartSec=2
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
WD2EOF

# Watcher-of-the-watcher (redundant backstop, 30s timer)
cp "$SCRIPT_DIR/watcher.py" "$BINDIR/watcher.py"
cat > /etc/systemd/system/"$UNIT_WDW" << 'WWSEOF'
[Unit]
Description=Cerberus Watcher-of-the-Watcher (mutual backstop)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/cerberus/watcher.py
StandardOutput=journal

[Install]
WantedBy=multi-user.target
WWSEOF

cat > /etc/systemd/system/"$UNIT_WDW_TIMER" << 'WWTEOF'
[Unit]
Description=Cerberus Watcher-of-the-Watcher Timer
[Timer]
OnBootSec=25
OnUnitActiveSec=30
AccuracySec=3
[Install]
WantedBy=timers.target
WWTEOF

# Blocklist refresh
cat > /etc/systemd/system/"$UNIT_REFRESH" << 'REFSVCEOF'
[Unit]
Description=Cerberus Blocklist Refresh
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/opt/cerberus/core.sh refresh
StandardOutput=journal
REFSVCEOF

cat > /etc/systemd/system/"$UNIT_REFRESH_TIMER" << 'REFTIMEREOF'
[Unit]
Description=Cerberus Daily Blocklist Refresh
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
REFTIMEREOF

# Block page servers
cat > /etc/systemd/system/"$UNIT_BLOCKPAGE" << 'BPSVCEOF'
[Unit]
Description=Cerberus Block Page Server (HTTP port 80)
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/opt/cerberus/blockpage.py 80
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
BPSVCEOF

cat > /etc/systemd/system/"$UNIT_BLOCKPAGE_HTTPS" << 'BPHTTPSEOF'
[Unit]
Description=Cerberus Block Page Server (HTTPS port 443)
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/opt/cerberus/blockpage.py 443
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
BPHTTPSEOF

# DNS resolver
cat > /etc/systemd/system/"$UNIT_RESOLVER" << RESOLVEREOF
[Unit]
Description=Cerberus DNS Resolver
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/bash -c "install -o cerberus-resolve -g cerberus-resolve -m 664 /dev/null /var/lib/cerberus/penalty_signal"
ExecStart=/usr/bin/python3 $BINDIR/resolver.py
User=cerberus-resolve
Group=cerberus-resolve
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=yes
ProtectHome=yes
PrivateTmp=yes
Restart=always
RestartSec=5
Environment=CERBERUS_DB=$BINDIR/cerberus.db
Environment=CERBERUS_PORT=5353

[Install]
WantedBy=multi-user.target
RESOLVEREOF

# ── disable Firefox DoH ──────────────────────────────────────
for profile in /home/*/.mozilla/firefox/*.default*/prefs.js; do
  if [[ -f "$profile" ]] && ! grep -q "network.trr.mode" "$profile" 2>/dev/null; then
    echo 'user_pref("network.trr.mode", 5);' >> "$profile"
    echo "Disabled DoH in $profile"
  fi
done

# ── faillock ─────────────────────────────────────────────────
if grep -q "^auth.*required.*pam_faillock.so" /etc/pam.d/system-auth 2>/dev/null; then
  cat > /etc/security/faillock.conf << 'FAILEOF'
deny = 3
unlock_time = 600
silent
FAILEOF
  echo "faillock configured (3 tries, 10 minute lockout)"
else
  echo "WARNING: pam_faillock.so not found in system-auth"
fi

# ── systemd enable (randomized names) ────────────────────────
# Remove any legacy cerberus-* unit names from earlier versions first
legacy_units=( cerberus.service cerberus-resolver.service cerberus-watchdog.service \
  cerberus-watchdog.timer cerberus-watchdog2.service cerberus-watchdog-watcher.service \
  cerberus-watchdog-watcher.timer cerberus-refresh.service cerberus-refresh.timer \
  cerberus-blockpage.service cerberus-blockpage-https.service )
for u in "${legacy_units[@]}"; do
  if [[ -f "/etc/systemd/system/$u" ]]; then
    systemctl disable --now "$u" 2>/dev/null || true
    rm -f "/etc/systemd/system/$u"
    echo "Removed legacy unit $u"
  fi
done

systemctl daemon-reload
systemctl enable --now "$UNIT_CORE" "$UNIT_RESOLVER" "$UNIT_WD_TIMER" "$UNIT_WDI" "$UNIT_WDW_TIMER" "$UNIT_BLOCKPAGE" "$UNIT_BLOCKPAGE_HTTPS" "$UNIT_REFRESH_TIMER"

# ── hidden backups ────────────────────────────────────────────
for loc in "${BACKUP_LOCATIONS[@]}"; do
  mkdir -p "$(dirname "$loc")" 2>/dev/null || true
  chattr -i "$loc" 2>/dev/null || true
  cp "$BINDIR/core.sh" "$loc" 2>/dev/null || true
  chmod 644 "$loc" 2>/dev/null || true
  chattr +i "$loc" 2>/dev/null || true
done

# ── NetworkManager restart ────────────────────────────────────
systemctl restart NetworkManager

# ── AI Security Policy ───────────────────────────────────────
chattr -i "$BINDIR/AI_POLICY.md" 2>/dev/null || true
cp "$SCRIPT_DIR/AI_POLICY.md" "$BINDIR/AI_POLICY.md" 2>/dev/null || true
chmod 444 "$BINDIR/AI_POLICY.md" 2>/dev/null || true
chattr +i "$BINDIR/AI_POLICY.md" 2>/dev/null || true

echo ""
echo "=== Setup Complete (v2 SQLite DNS) ==="
echo ""
echo "Commands:"
echo "  cerberus status              Check status"
echo "  cerberus lock                Apply and lock immediately"
echo "  cerberus block add <domain>  Add custom domain to block"
echo "  cerberus block rm <domain>   Remove custom domain"
echo "  cerberus block list          List custom blocked domains"
echo "  cerberus update              Self-update from git and reinstall"
echo "  cerberus refresh             Force refresh blocklist from internet"
echo ""
echo "Mandatory categories (porn, gambling, drugs, malware, phishing,"
echo "ransomware, abuse, fraud, scam) cannot be overridden."
echo "Optional categories (facebook, twitter, youtube, tiktok, whatsapp,"
echo "tracking, redirect) can be toggled in ENABLED_OPTIONALS in config."
echo ""
echo "WARNING: To fully lock yourself out so NOTHING can be undone:"
echo "  1. Run: passwd"
echo "  2. Change to a password you don't know (mash keyboard)"
echo "  3. Delete any saved passwords from your session"
echo ""
echo "faillock is active: 3 wrong sudo attempts = 10 min lockout"
