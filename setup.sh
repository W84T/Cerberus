#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root. Try: sudo $0"
  exit 1
fi

BINDIR="/opt/cerberus"

echo "=== Cerberus Setup ==="
echo ""

# ── clear immutable flags on files we need to write ──────────
for f in "$BINDIR/core.sh" "$BINDIR/cli.sh" "$BINDIR/config" "$BINDIR/custom-block.txt" \
         "$BINDIR/blockpage.py" "$BINDIR/unlock-now.sh" \
         "$BINDIR/blockpage.crt" "$BINDIR/blockpage.key" /etc/hosts; do
  chattr -i "$f" 2>/dev/null || true
done
for loc in "${BACKUP_LOCATIONS[@]:-}"; do
  chattr -i "$loc" 2>/dev/null || true
  rm -f "$loc" 2>/dev/null || true
done

# ── dependencies ──────────────────────────────────────────────
if ! command -v curl &>/dev/null; then echo "Installing curl...";  pacman -Sy --noconfirm curl; fi
if ! command -v openssl &>/dev/null; then echo "Installing openssl..."; pacman -Sy --noconfirm openssl; fi

# ── directories ───────────────────────────────────────────────
mkdir -p "$BINDIR" /var/lib/cerberus /etc/NetworkManager/conf.d
rm -f /usr/local/bin/cerberus

# ── config ────────────────────────────────────────────────────
cat > "$BINDIR/config" << 'CONFEOF'
# Whitelist domains (one per line, no wildcards)
WHITELIST_DOMAINS=(
  "tv8.egydead.live"
)

DEFAULT_UNLOCK_DURATION="24h"
WATCHDOG_INTERVAL=300

BLOCKLIST_URL="https://blocklistproject.github.io/Lists/porn.txt"

BACKUP_LOCATIONS=(
  "/usr/share/man/man3/.nss_cache.so"
  "/var/lib/cerberus/.journal"
  "/home/w84t/.config/systemd/user/.helper"
  "/home/w84t/.local/share/applications/.update"
)

# SafeSearch redirects — forces search engines to use their SafeSearch IP
SAFESEARCH_REDIRECTS=(
  "216.239.38.120 google.com"
  "216.239.38.120 www.google.com"
  "216.239.38.120 youtube.com"
  "216.239.38.120 www.youtube.com"
  "13.107.21.200 bing.com"
  "13.107.21.200 www.bing.com"
)

CUSTOM_BLOCK_FILE="/opt/cerberus/custom-block.txt"

# Path to the git repository for self-updates
GIT_REPO_PATH="/home/w84t/blocker-git"
CONFEOF

# ── core.sh ───────────────────────────────────────────────────
cat > "$BINDIR/core.sh" << 'COREEOF'
#!/bin/bash
set -euo pipefail
source /opt/cerberus/config
SCRIPT_HASH=$(sha256sum "$0" 2>/dev/null | cut -d' ' -f1)
MARKER="# Blocked domains - Cerberus v1"
UNLOCK_FILE="/opt/cerberus/.unlock"
CUSTOM_BLOCK_FILE="${CUSTOM_BLOCK_FILE:-/opt/cerberus/custom-block.txt}"
log() { echo "[cerberus] $(date '+%H:%M:%S') $*"; }
SAFESEARCH_MARKER="# Cerberus SafeSearch"

apply_safesearch() {
  chattr -i /etc/hosts 2>/dev/null || true
  local tmp; tmp=$(mktemp)
  grep -vF "$SAFESEARCH_MARKER" /etc/hosts > "$tmp" 2>/dev/null || true
  cp "$tmp" /etc/hosts; rm -f "$tmp"
  sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' /etc/hosts 2>/dev/null || true
  {
    echo ""
    echo "$SAFESEARCH_MARKER"
    echo "# $(date '+%Y-%m-%d %H:%M')"
    for entry in "${SAFESEARCH_REDIRECTS[@]}"; do echo "$entry"; done
  } >> /etc/hosts
  chattr +i /etc/hosts 2>/dev/null || true
  log "SafeSearch redirects applied (${#SAFESEARCH_REDIRECTS[@]} entries)"
}

apply_hosts() {
  local force=${1:-false}
  local tmp="" marker_found=false custom_domains="" old_hash="" new_hash=""
  grep -qF "$MARKER" /etc/hosts 2>/dev/null && marker_found=true
  if [[ -f "$CUSTOM_BLOCK_FILE" ]]; then
    custom_domains=$(grep -v '^#' "$CUSTOM_BLOCK_FILE" | grep -v '^[[:space:]]*$' 2>/dev/null || true)
    new_hash=$(echo "$custom_domains" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "none")
  fi
  old_hash=$(grep "# Custom hash:" /etc/hosts 2>/dev/null | cut -d: -f2 | tr -d ' ') || true
  local need_refresh=$force
  ! $marker_found && need_refresh=true
  [[ -n "$custom_domains" ]] && [[ "$new_hash" != "$old_hash" ]] && need_refresh=true
  [[ -z "$custom_domains" ]] && grep -q "# Custom blocked domains" /etc/hosts 2>/dev/null && need_refresh=true
  if $need_refresh; then
    log "Refreshing hosts blocklist..."
    chattr -i /etc/hosts 2>/dev/null || true
    local orig; orig=$(mktemp); grep -vF "$MARKER" /etc/hosts > "$orig" 2>/dev/null || true
    local dl_ok=false; tmp=$(mktemp)
    curl -sL --max-time 120 "$BLOCKLIST_URL" -o "$tmp" 2>/dev/null && [[ -s "$tmp" ]] && dl_ok=true
    {
      cat "$orig"; echo ""; echo "$MARKER"
      echo "# $(date '+%Y-%m-%d %H:%M')"
      echo "# Custom hash: $new_hash"
      $dl_ok && grep '^0\.0\.0\.0 ' "$tmp" | grep -v '^0\.0\.0\.0 0\.0\.0\.0' | grep -v '^0\.0\.0\.0 localhost' | grep -v '^0\.0\.0\.0 local$' | sed 's/^0\.0\.0\.0 /127.0.0.1 /'
      if [[ -n "$custom_domains" ]]; then
        echo "# Custom blocked domains"
        echo "$custom_domains" | while read -r d; do
          [[ -z "$d" ]] && continue; echo "127.0.0.1 $d"; echo "127.0.0.1 www.$d"
        done
      fi
    } > /etc/hosts
    rm -f "$orig" "$tmp"
    for d in "${WHITELIST_DOMAINS[@]}"; do
      sed -i "/127\.0\.0\.1 $d\b/d" /etc/hosts 2>/dev/null || true
      sed -i "/127\.0\.0\.1 www\.$d\b/d" /etc/hosts 2>/dev/null || true
    done
    chattr +i /etc/hosts 2>/dev/null || true
    log "Hosts applied ($(grep -c '^127\.0\.0\.1' /etc/hosts) entries)"
  else
    chattr +i /etc/hosts 2>/dev/null || true
  fi
}

apply_iptables() {
  local chain
  chain=$(iptables -N CERBERUS 2>/dev/null; echo CERBERUS) || chain=CERBERUS
  iptables -F CERBERUS
  iptables -A CERBERUS -d 127.0.0.53/32 -p udp --dport 53 -j ACCEPT
  iptables -A CERBERUS -d 127.0.0.53/32 -p tcp --dport 53 -j ACCEPT
  iptables -A CERBERUS -m owner --uid-owner systemd-resolve -p udp --dport 53 -j ACCEPT
  iptables -A CERBERUS -m owner --uid-owner systemd-resolve -p tcp --dport 53 -j ACCEPT
  iptables -A CERBERUS -p udp --dport 53 -j DROP
  iptables -A CERBERUS -p tcp --dport 53 -j DROP
  iptables -A CERBERUS -p tcp --dport 853 -j DROP
  iptables -A CERBERUS -d 1.1.1.1,1.0.0.1 -p tcp --dport 443 -j DROP 2>/dev/null || true
  iptables -A CERBERUS -d 8.8.8.8,8.8.4.4 -p tcp --dport 443 -j DROP 2>/dev/null || true
  iptables -A CERBERUS -d 9.9.9.9,149.112.112.112 -p tcp --dport 443 -j DROP 2>/dev/null || true
  iptables -A CERBERUS -d 208.67.222.222,208.67.220.220 -p tcp --dport 443 -j DROP 2>/dev/null || true
  iptables -A CERBERUS -p udp --dport 443 -j DROP 2>/dev/null || true
  for ip in 45.90.28.0 45.90.30.0 94.140.14.14 94.140.15.15 76.76.2.0 76.76.10.0; do
    iptables -A CERBERUS -d $ip -p tcp --dport 443 -j DROP 2>/dev/null || true
  done
  iptables -C OUTPUT -j CERBERUS 2>/dev/null || iptables -A OUTPUT -j CERBERUS
  log "iptables rules applied"
}

verify_blocking() {
  local failed=0
  grep -qF "$MARKER" /etc/hosts 2>/dev/null || { log "Hosts blocklist missing, re-applying"; apply_hosts; ((failed++)) || true; }
  iptables -L CERBERUS -n 2>/dev/null | grep -q 'dpt:53' || { log "iptables rules missing, re-applying"; apply_iptables; ((failed++)) || true; }
  chattr +i /etc/hosts 2>/dev/null || true
  return $failed
}

self_heal() {
  local ref_hash=""
  for loc in "${BACKUP_LOCATIONS[@]}"; do
    if [[ -f "$loc" ]]; then ref_hash=$(sha256sum "$loc" | cut -d' ' -f1); break; fi
  done
  [[ -z "$ref_hash" ]] && ref_hash="$SCRIPT_HASH"
  local my_path="/opt/cerberus/core.sh"
  if [[ -f "$my_path" ]]; then
    local cur_hash; cur_hash=$(sha256sum "$my_path" | cut -d' ' -f1)
    if [[ "$cur_hash" != "$ref_hash" ]]; then
      log "Main script corrupted, restoring from backup"
      for loc in "${BACKUP_LOCATIONS[@]}"; do
        [[ -f "$loc" ]] && { cp "$loc" "$my_path" 2>/dev/null || true; chmod +x "$my_path" 2>/dev/null || true; break; }
      done
    fi
  else
    log "Main script missing, restoring from backup"
    for loc in "${BACKUP_LOCATIONS[@]}"; do
      [[ -f "$loc" ]] && { cp "$loc" "$my_path" 2>/dev/null || true; chmod +x "$my_path" 2>/dev/null || true; break; }
    done
  fi
  local bcount=0
  for loc in "${BACKUP_LOCATIONS[@]}"; do [[ -f "$loc" ]] && ((bcount++)) || true; done
  if (( bcount < 2 )); then
    for loc in "${BACKUP_LOCATIONS[@]}"; do
      if [[ ! -f "$loc" ]]; then
        mkdir -p "$(dirname "$loc")" 2>/dev/null || true
        cp "$my_path" "$loc" 2>/dev/null || true
        chmod 644 "$loc" 2>/dev/null || true
      fi
    done
  fi
  save_state
}

save_state() {
  local state_file="/var/lib/cerberus/state"
  echo "hosts_entries=$(grep -c '^127\.0\.0\.1' /etc/hosts 2>/dev/null || echo 0)" > "$state_file"
  iptables -L CERBERUS -n 2>/dev/null | grep -q 'dpt:53' && echo "iptables=active" >> "$state_file" || echo "iptables=inactive" >> "$state_file"
  lsattr /etc/hosts 2>/dev/null | grep -q '^....i' && echo "immutable=yes" >> "$state_file" || echo "immutable=no" >> "$state_file"
  chmod 644 "$state_file" 2>/dev/null || true
}

check_unlock() {
  if [[ -f "$UNLOCK_FILE" ]]; then
    local expiry; expiry=$(cat "$UNLOCK_FILE" 2>/dev/null || echo "0")
    local now; now=$(date +%s)
    (( now >= expiry )) && { log "Unlock timer expired, running unlock"; /opt/cerberus/unlock-now.sh; }
  fi
}

do_lock() {
  apply_hosts; apply_safesearch; apply_iptables
  for loc in "${BACKUP_LOCATIONS[@]}"; do [[ -f "$loc" ]] && chattr +i "$loc" 2>/dev/null || true; done
  chattr +i /etc/hosts 2>/dev/null || true; chattr +i "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
  log "System locked"
}

do_update() {
  local repo="${GIT_REPO_PATH:-/home/w84t/blocker-git}"
  if [[ ! -d "$repo/.git" ]]; then
    log "Git repo not found at $repo"
    return 1
  fi
  log "Pulling latest from git ($repo)..."
  rm -f "$repo/.git/FETCH_HEAD" 2>/dev/null || true
  local user="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
  if [[ "$user" != "root" ]]; then
    sudo -u "$user" git -C "$repo" pull 2>/dev/null || { log "git pull failed"; return 1; }
  else
    git -C "$repo" pull 2>/dev/null || { log "git pull failed"; return 1; }
  fi
  log "Re-running setup..."
  "$repo/setup.sh" 2>/dev/null || { log "setup.sh failed"; return 1; }
  log "Update complete"
}

do_refresh() {
  apply_hosts true
  apply_safesearch
  log "Blocklist force-refreshed"
}

block_add() {
  local domain="$1"; [[ -z "$domain" ]] && { echo "Usage: block_add <domain>"; return 1; }
  chattr -i "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
  if grep -qxF "$domain" "$CUSTOM_BLOCK_FILE" 2>/dev/null; then echo "Domain already in block list."
  else echo "$domain" >> "$CUSTOM_BLOCK_FILE"; echo "Added $domain to block list."
  fi
  chattr +i "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
}

block_rm() {
  local domain="$1"; [[ -z "$domain" ]] && { echo "Usage: block_rm <domain>"; return 1; }
  chattr -i "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
  sed -i "/^$domain$/d" "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
  sed -i "/^www\.$domain$/d" "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
  chattr +i "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
  echo "Removed $domain from block list."
}

case "${1:-apply}" in
  apply)     apply_hosts; apply_safesearch; apply_iptables; self_heal ;;
  check)     verify_blocking; self_heal; check_unlock ;;
  lock)      do_lock ;;
  block_add) block_add "${2:-}" ;;
  block_rm)  block_rm "${2:-}" ;;
  safesearch) apply_safesearch ;;
  status)    save_state; cat /var/lib/cerberus/state 2>/dev/null || echo "state unavailable" ;;
  update)    do_update ;;
  refresh)   do_refresh ;;
  *)         echo "Usage: cerberus {apply|check|lock|block_add|block_rm|safesearch|status|update|refresh}"; exit 1 ;;
esac
COREEOF

# ── cli.sh ────────────────────────────────────────────────────
cat > "$BINDIR/cli.sh" << 'CLIEOF'
#!/bin/bash
set -euo pipefail
if [[ "$EUID" -ne 0 ]]; then exec sudo -n "$(realpath "$0")" "$@"; fi
CORE="/opt/cerberus/core.sh"; CONFIG="/opt/cerberus/config"
UNLOCK_FILE="/opt/cerberus/.unlock"; CUSTOM_BLOCK_FILE="/opt/cerberus/custom-block.txt"

usage() {
  cat <<EOF
Usage: cerberus <command>

Commands:
  status                  Show blocking status
  lock                    Apply and lock immediately
  unlock [duration]       Request unlock after a delay (default: 24h)
  cancel                  Cancel pending unlock
  block add <domain>      Add domain to block list
  block rm <domain>       Remove domain from block list
  block list              Show custom blocked domains
  whitelist add <domain>  Add domain to whitelist
  whitelist rm <domain>   Remove domain from whitelist
  safesearch [list|apply] Show or apply SafeSearch redirects
  update                  Self-update from git and reinstall
  refresh                 Force refresh blocklist from internet
  help                    Show this help
EOF
}

parse_duration() {
  local input="${1:-24h}" num="${input//[a-zA-Z]/}" unit="${input//[0-9]/}"
  case "$unit" in s|S) echo $((num*1));; m|M) echo $((num*60));; h|H) echo $((num*3600));; d|D) echo $((num*86400));; *) echo $((num*3600));; esac
}

case "${1:-help}" in
  status)
    echo "=== Cerberus Status ==="
    if grep -q "# Blocked domains - Cerberus" /etc/hosts 2>/dev/null; then echo "  Hosts blocklist: ACTIVE ($(grep -c '^127\.0\.0\.1' /etc/hosts 2>/dev/null || echo '?') entries)"
    else echo "  Hosts blocklist: MISSING"; fi
    iptables -L CERBERUS -n 2>/dev/null | grep -q 'dpt:53' && echo "  iptables rules:  ACTIVE" || echo "  iptables rules:  MISSING"
    lsattr /etc/hosts 2>/dev/null | grep -q '^....i' && echo "  Hosts immutable: YES" || echo "  Hosts immutable: NO"
    if [[ -f "$UNLOCK_FILE" ]]; then
      expiry=$(cat "$UNLOCK_FILE" 2>/dev/null || echo "0"); now=$(date +%s)
      (( now < expiry )) && echo "  Unlock pending:  $((expiry-now))s remaining" || echo "  Unlock pending:  expired (will apply on next check)"
    else echo "  Unlock pending:  NO"; fi
    [[ -f "$CUSTOM_BLOCK_FILE" ]] && [[ -s "$CUSTOM_BLOCK_FILE" ]] && echo "  Custom blocked:  $(wc -l < "$CUSTOM_BLOCK_FILE") domains"
    if grep -q "# Cerberus SafeSearch" /etc/hosts 2>/dev/null; then
      echo "  SafeSearch:      ACTIVE ($(grep -c '^216\.239\.38\.120\|^13\.107\.21\.200' /etc/hosts 2>/dev/null || echo '?') redirects)"
    else
      echo "  SafeSearch:      OFF"
    fi
    ;;
  lock)    "$CORE" lock ;;
  unlock)  duration="${2:-24h}"; seconds=$(parse_duration "$duration"); expiry=$(($(date +%s)+seconds))
           echo "Unlock requested in $duration (expires $(date -d "@$expiry" '+%Y-%m-%d %H:%M'))"
           echo "Cancel with: cerberus cancel"; echo "$expiry" > "$UNLOCK_FILE" ;;
  cancel)  [[ -f "$UNLOCK_FILE" ]] && { echo "Cancelling unlock request..."; echo "Are you sure? Waiting 10s. Ctrl+C to abort."; sleep 10; rm -f "$UNLOCK_FILE"; echo "Cancelled."; } || echo "No pending unlock request." ;;
  block)
    action="${2:-}"; domain="${3:-}"
    case "$action" in
      add) [[ -z "$domain" ]] && { echo "Usage: cerberus block add <domain>"; exit 1; }; "$CORE" block_add "$domain"; "$CORE" apply ;;
      rm)  [[ -z "$domain" ]] && { echo "Usage: cerberus block rm <domain>"; exit 1; }; "$CORE" block_rm "$domain"; "$CORE" apply ;;
      list) [[ -f "$CUSTOM_BLOCK_FILE" ]] && [[ -s "$CUSTOM_BLOCK_FILE" ]] && { echo "=== Custom Blocked Domains ==="; cat "$CUSTOM_BLOCK_FILE"; } || echo "No custom blocked domains." ;;
      *) echo "Usage: cerberus block add|rm|list <domain>" ;;
    esac ;;
  whitelist)
    action="${2:-}"; domain="${3:-}"
    [[ -z "$action" || -z "$domain" ]] && { echo "Usage: cerberus whitelist add|rm <domain>"; exit 1; }
    case "$action" in
      add) grep -qF "$domain" "$CONFIG" 2>/dev/null && echo "Domain already in whitelist." || { sed -i "/^WHITELIST_DOMAINS=(/a\\  \"$domain\"" "$CONFIG"; echo "Added $domain to whitelist."; "$CORE" apply; } ;;
      rm)  sed -i "/\"$domain\"/d" "$CONFIG"; echo "Removed $domain from whitelist."; "$CORE" apply ;;
      *)   echo "Usage: cerberus whitelist add|rm <domain>" ;;
    esac ;;
  safesearch)
    action="${2:-}"
    case "$action" in
      list)
        echo "=== SafeSearch Redirects ==="
        if grep -q "# Cerberus SafeSearch" /etc/hosts 2>/dev/null; then
          grep -A 100 "# Cerberus SafeSearch" /etc/hosts | grep -v "^#" | grep -v "^$"
        else
          echo "Not applied."
        fi
        ;;
      apply)
        "$CORE" safesearch
        echo "SafeSearch applied."
        ;;
      *)
        echo "Usage: cerberus safesearch list|apply"
        ;;
    esac
    ;;
  update) echo "=== Cerberus Self-Update ==="; "$CORE" update; echo "Update complete." ;;
  refresh) echo "=== Cerberus Force Refresh ==="; "$CORE" refresh; echo "Refresh complete." ;;
  help|*) usage ;;
esac
CLIEOF

# ── blockpage.py ──────────────────────────────────────────────
cat > "$BINDIR/blockpage.py" << 'PYEOF'
#!/usr/bin/env python3
import http.server, ssl, sys, socket

BLOCK_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Site Blocked</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f0f1a; color: #e0e0e0; display: flex; justify-content: center; align-items: center; min-height: 100vh; }
.container { text-align: center; padding: 40px 20px; max-width: 600px; }
.icon { width: 80px; height: 80px; background: #e94560; border-radius: 50%; display: flex; justify-content: center; align-items: center; margin: 0 auto 30px; font-size: 40px; color: #fff; line-height: 1; }
h1 { color: #e94560; font-size: 1.8em; margin-bottom: 15px; font-weight: 700; }
p { color: #a0a0b0; font-size: 1em; line-height: 1.6; margin-bottom: 12px; }
.domain { color: #e0e0e0; background: #1a1a30; padding: 8px 16px; border-radius: 6px; font-family: monospace; display: inline-block; margin: 10px 0; font-size: 0.9em; }
.footer { margin-top: 40px; font-size: 0.75em; color: #555; border-top: 1px solid #1a1a30; padding-top: 20px; }
</style>
</head>
<body>
<div class="container">
<div class="icon">!</div>
<h1>This Site Is Blocked</h1>
<p>The website you are trying to access has been blocked by the system content filter.</p>
<p class="domain">__DOMAIN__</p>
<p>If you believe this is a mistake, request an unlock or remove the domain from the blocklist.</p>
<div class="footer">Blocked by Cerberus</div>
</div>
</body>
</html>"""

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        domain = self.headers.get("Host", "unknown")
        page = BLOCK_PAGE.replace("__DOMAIN__", domain)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(page.encode())
    do_POST = do_GET; do_HEAD = do_GET; do_CONNECT = do_GET
    def log_message(self, fmt, *args):
        sys.stderr.write("[cerberus-blockpage] %s - %s\n" % (self.client_address[0], fmt % args))

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 80
    server = http.server.HTTPServer(("0.0.0.0", port), Handler)
    server.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if port == 443:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain("/opt/cerberus/blockpage.crt", "/opt/cerberus/blockpage.key")
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
    print("[cerberus-blockpage] server on port %d" % port, flush=True)
    server.serve_forever()
PYEOF

# ── unlock-now.sh ─────────────────────────────────────────────
cat > "$BINDIR/unlock-now.sh" << 'UNLOCKEOF'
#!/bin/bash
set -euo pipefail
log() { echo "[cerberus-unlock] $(date '+%H:%M:%S') $*"; }
UNLOCK_FILE="/opt/cerberus/.unlock"
log "Unlock triggered"
chattr -i /etc/hosts 2>/dev/null || true
grep -q "# Blocked domains - Cerberus" /etc/hosts 2>/dev/null && sed -i '/# Blocked domains - Cerberus/,$d' /etc/hosts 2>/dev/null || true
sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' /etc/hosts 2>/dev/null || true
iptables -D OUTPUT -j CERBERUS 2>/dev/null || true
iptables -F CERBERUS 2>/dev/null || true
iptables -X CERBERUS 2>/dev/null || true
systemctl stop cerberus-watchdog.timer 2>/dev/null || true
systemctl disable cerberus-watchdog.timer 2>/dev/null || true
systemctl stop cerberus-watchdog.service 2>/dev/null || true
systemctl stop cerberus.service 2>/dev/null || true
rm -f "$UNLOCK_FILE"
log "Unlock complete"
UNLOCKEOF

# ── custom-block.txt (133 adult manga/hentai domains) ────────
cat > "$BINDIR/custom-block.txt" << 'CUSTOMEOF'
allgirlbooru.com
animeidhentai.com
behoimi.org
comicland.org
doujindesu.com
doujin-moe.com
doujinshi.moe
doujinshi.org
eahentai.com
hahohentai.com
hentai4m.com
hentaianime.net
hentaiart.net
hentaiavenue.com
hentaibase.com
hentaibest.com
hentaiblvd.com
hentaibook.com
hentaibox.com
hentai.cafe
hentaicartoon.com
hentaicentral.com
hentaiclan.com
hentaicomic.net
hentaicomics.com
hentaicore.com
hentaidea.com
hentaidragon.com
hentaidude.com
hentaiempire.com
hentaierotica.com
hentaifan.org
hentaifanatics.com
hentaifap.com
hentaifight.com
hentaifiles.net
hentai-foundry.net
hentaifreak.com
hentaifreak.net
hentaifreaks.com
hentaifree.com
hentaifull.com
hentaifurry.com
hentaigallery.com
hentaigasm.net
hentaigasm.org
hentaigif.com
hentaigirls.com
hentaihaven.net
hentaiheaven.com
hentaiheaven.net
hentaiheaven.org
hentai-hentai.com
hentaihive.com
hentaihunter.com
hentaijungle.com
hentaikisa.com
hentaimanga.info
hentaimania.com
hentaimaster.com
hentaime.com
hentainexus.com
hentaioman.com
hentaionly.com
hentaiparadise.info
hentaipics.com
hentaiplay.com
hentaipoison.com
hentai-porn.com
hentaiporno.com
hentaiporn.tv
hentaiporn.xxx
hentairips.com
hentairule.com
hentairules.net
hentaisex.com
hentaishare.com
hentaistars.com
hentaistreaming.com
hentaistream.live
hentaistream.me
hentaistream.net
hentaistream.org
hentaistudios.com
hentai-town.com
hentai-tube.com
hentai-tube.net
hentaiuniversity.com
hentaiuniversity.net
hentaivault.com
hentaivid.com
hentaivideo.com
hentaivn.net
hentaiwar.com
hentaiwar.net
hentaiwar.org
hentai-world.com
hentaiworld.net
hentaiworld.org
hentaiworld.pro
hentaix.net
hentaix.org
hentaix.to
hentaix.tv
hentaixxx.net
hentaixxx.org
hentaizer.com
hentaiz.net
hentai-zone.com
hentaizone.com
hentaizone.net
hentaizone.org
hentaizone-pro.com
hentaizonepro.com
hentaiz.org
hentaiz.tv
hentalk.com
imhentai.com
imhentai.to
lolibooru.moe
m-hentai.com
mangadex.org
mangadna.com
mangahentai.io
mangatown.com
newgrounds.com
oppaitube.com
pixiv.net
pixiv.org
readhentai.com
wholesomehentai.com
CUSTOMEOF

# ── systemd services ──────────────────────────────────────────
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
OnBootSec=60
OnUnitActiveSec=300
[Install]
WantedBy=timers.target
WDTIMEREOF

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

# ── SSL self‑signed cert ──────────────────────────────────────
if [[ ! -f "$BINDIR/blockpage.crt" ]]; then
  openssl req -x509 -newkey rsa:2048 -keyout "$BINDIR/blockpage.key" \
    -out "$BINDIR/blockpage.crt" -days 3650 -nodes \
    -subj "/CN=Cerberus" 2>/dev/null
  echo "Self-signed cert created"
fi

# ── NetworkManager DNS → systemd-resolved ────────────────────
cat > /etc/NetworkManager/conf.d/dns.conf << 'NMEOF'
[main]
dns=systemd-resolved
NMEOF
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

# ── sudoers rule ──────────────────────────────────────────────
cat > /etc/sudoers.d/99-cerberus << 'SUDOEOF'
w84t ALL=(ALL) NOPASSWD: /opt/cerberus/cli.sh, /opt/cerberus/core.sh, /usr/bin/iptables -L CERBERUS -n
Defaults:w84t timestamp_timeout=0
SUDOEOF
chmod 440 /etc/sudoers.d/99-cerberus
visudo -cf /etc/sudoers.d/99-cerberus

# ── disable Firefox DoH ──────────────────────────────────────
for profile in /home/*/.mozilla/firefox/*.default*/prefs.js; do
  if [[ -f "$profile" ]] && ! grep -q "network.trr.mode" "$profile" 2>/dev/null; then
    echo 'user_pref("network.trr.mode", 5);' >> "$profile"
    echo "Disabled DoH in $profile"
  fi
done

# ── faillock (3 tries, 10 min lockout) ────────────────────────
if grep -q "^auth.*required.*pam_faillock.so" /etc/pam.d/sudo 2>/dev/null; then
  echo "faillock already configured"
else
  cat > /etc/security/faillock.conf << 'FAILEOF'
deny = 3
unlock_time = 600
silent
FAILEOF
fi

# ── permissions ───────────────────────────────────────────────
chmod +x "$BINDIR/core.sh" "$BINDIR/cli.sh" "$BINDIR/blockpage.py" "$BINDIR/unlock-now.sh"
chmod 644 "$BINDIR/config" "$BINDIR/custom-block.txt"
ln -sf "$BINDIR/cli.sh" /usr/local/bin/cerberus

# ── systemd ───────────────────────────────────────────────────
systemctl daemon-reload
source "$BINDIR/config"
for loc in "${BACKUP_LOCATIONS[@]}"; do chattr -i "$loc" 2>/dev/null || true; rm -f "$loc" 2>/dev/null || true; done
systemctl enable --now cerberus.service
systemctl enable --now cerberus-watchdog.timer
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

# ── initial apply ─────────────────────────────────────────────
"$BINDIR/core.sh" apply
chattr +i /etc/hosts "$BINDIR/core.sh" "$BINDIR/custom-block.txt" 2>/dev/null || true

# ── NetworkManager restart ────────────────────────────────────
systemctl restart NetworkManager

echo ""
echo "=== Setup Complete ==="
echo "Cerberus is now active with 1.5M+ blocked domains"
echo ""
echo "Commands:"
echo "  cerberus status              Check status"
echo "  cerberus unlock [duration]   Request unlock (default: 24h)"
echo "  cerberus cancel              Cancel pending unlock"
echo "  cerberus block add <domain>  Add custom domain to block"
echo "  cerberus block rm <domain>   Remove custom domain"
echo "  cerberus block list          List custom blocked domains"
echo "  cerberus update              Self-update from git and reinstall"
echo "  cerberus refresh             Force refresh blocklist from internet"
echo ""
echo "WARNING: To fully lock yourself out so NOTHING can be undone:"
echo "  1. Run: passwd"
echo "  2. Change to a password you don't know (mash keyboard)"
echo "  3. Delete any saved passwords from your session"
echo ""
echo "faillock is active: 3 wrong sudo attempts = 10 min lockout"
