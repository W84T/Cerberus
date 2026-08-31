#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root. Try: sudo $0"
  exit 1
fi

BINDIR="/opt/cerberus"

echo "=== Cerberus Setup v2 (SQLite DNS) ==="
echo ""

# ── clear immutable flags ──────────────────────────────────────
for f in "$BINDIR/core.sh" "$BINDIR/cli.sh" "$BINDIR/config" "$BINDIR/custom-block.txt" \
         "$BINDIR/blockpage.py" "$BINDIR/blockpage.crt" "$BINDIR/blockpage.key"; do
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
rm -f /usr/local/bin/cerberus

# ── copy source files ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  cp "$SCRIPT_DIR/config"       "$BINDIR/config"
  cp "$SCRIPT_DIR/core.sh"      "$BINDIR/core.sh"
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
cat > /etc/sudoers.d/99-cerberus << 'SUDOEOF'
w84t ALL=(ALL) NOPASSWD: /opt/cerberus/cli.sh, /opt/cerberus/core.sh, /usr/bin/iptables -L CERBERUS -n, /usr/bin/iptables -L CERBERUS_NAT -n
Defaults:w84t timestamp_timeout=0
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

# ── systemd services ─────────────────────────────────────────

# Core cerberus apply
cat > /etc/systemd/system/cerberus.service << 'UNITEOF'
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

# Watchdog
cat > /etc/systemd/system/cerberus-watchdog.service << 'WDSVCEOF'
[Unit]
Description=Cerberus Watchdog
After=network.target
[Service]
Type=oneshot
ExecStart=/opt/cerberus/core.sh check
StandardOutput=journal
WDSVCEOF

cat > /etc/systemd/system/cerberus-watchdog.timer << 'WDTIMEREOF'
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
cat > /etc/systemd/system/cerberus-watchdog2.service << 'WD2EOF'
[Unit]
Description=Cerberus Instant Watchdog (event-driven enforcement)
After=network.target cerberus-resolver.service
Wants=cerberus-resolver.service

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
cat > /etc/systemd/system/cerberus-watchdog-watcher.service << 'WWSEOF'
[Unit]
Description=Cerberus Watcher-of-the-Watcher (mutual backstop)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 $BINDIR/watcher.py
StandardOutput=journal

[Install]
WantedBy=multi-user.target
WWSEOF

cat > /etc/systemd/system/cerberus-watchdog-watcher.timer << 'WWTEOF'
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
cat > /etc/systemd/system/cerberus-refresh.service << 'REFSVCEOF'
[Unit]
Description=Cerberus Blocklist Refresh
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/opt/cerberus/core.sh refresh
StandardOutput=journal
REFSVCEOF

cat > /etc/systemd/system/cerberus-refresh.timer << 'REFTIMEREOF'
[Unit]
Description=Cerberus Daily Blocklist Refresh
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
REFTIMEREOF

# Block page servers
cat > /etc/systemd/system/cerberus-blockpage.service << 'BPSVCEOF'
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

cat > /etc/systemd/system/cerberus-blockpage-https.service << 'BPHTTPSEOF'
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
cat > /etc/systemd/system/cerberus-resolver.service << RESOLVEREOF
[Unit]
Description=Cerberus DNS Resolver
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
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

# ── systemd enable ───────────────────────────────────────────
systemctl daemon-reload
systemctl enable --now cerberus.service
systemctl enable --now cerberus-resolver.service
systemctl enable --now cerberus-watchdog.timer
systemctl enable --now cerberus-watchdog2.service
systemctl enable --now cerberus-watchdog-watcher.timer
systemctl enable --now cerberus-blockpage.service
systemctl enable --now cerberus-blockpage-https.service
systemctl enable --now cerberus-refresh.timer

# ── hidden backups ────────────────────────────────────────────
for loc in "${BACKUP_LOCATIONS[@]}"; do
  mkdir -p "$(dirname "$loc")" 2>/dev/null || true
  cp "$BINDIR/core.sh" "$loc" 2>/dev/null || true
  chmod 644 "$loc" 2>/dev/null || true
  chattr +i "$loc" 2>/dev/null || true
done

# ── NetworkManager restart ────────────────────────────────────
systemctl restart NetworkManager

# ── AI Security Policy ───────────────────────────────────────
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
