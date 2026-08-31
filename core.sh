#!/bin/bash
set -euo pipefail
source /opt/cerberus/config
SCRIPT_HASH=$(sha256sum "$0" 2>/dev/null | cut -d' ' -f1)
CUSTOM_BLOCK_FILE="${CUSTOM_BLOCK_FILE:-/opt/cerberus/custom-block.txt}"
BINDIR="/opt/cerberus"
DB_PATH="${DB_PATH:-/opt/cerberus/cerberus.db}"
RESOLVER_UID=$(id -u cerberus-resolve 2>/dev/null || echo "65534")
RESOLVER_PORT="${RESOLVER_PORT:-5353}"
log() { echo "[cerberus] $(date '+%H:%M:%S') $*"; }

update_db() {
  local force=${1:-false}
  if [[ "$force" == "true" ]] || [[ ! -f "$DB_PATH" ]]; then
    log "Updating blocklist database..."
    python3 "$BINDIR/blocklist_updater.py"
  else
    local entry_count
    entry_count=$(python3 -c "import sqlite3; db=sqlite3.connect('$DB_PATH'); print(db.execute('SELECT count(*) FROM blocked_domains').fetchone()[0])" 2>/dev/null || echo 0)
    log "Database has $entry_count entries, skipping update"
  fi
}

dns_reachable() {
  # Probe the resolver via UDP with a real DNS query, verifying it responds
  python3 - "$RESOLVER_PORT" << 'PYEOF' 2>/dev/null
import socket, sys
port = int(sys.argv[1]) if len(sys.argv) > 1 else 5353
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.5)
    labels = b"\x03www\x06google\x03com\x00"
    q = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + labels + b"\x00\x01\x00\x01"
    s.sendto(q, ("127.0.0.1", port))
    datum, _ = s.recvfrom(512)
    s.close()
    sys.exit(0 if len(datum) >= 12 else 1)
except Exception:
    sys.exit(1)
PYEOF
}

ensure_resolver() {
  local tries
  for tries in 1 2 3; do
    if ! systemctl is-active --quiet cerberus-resolver.service 2>/dev/null; then
      log "Starting resolver daemon..."
      systemctl start cerberus-resolver.service 2>/dev/null || true
      sleep 1
    fi
    if dns_reachable; then
      return 0
    fi
    sleep 1
  done
  log "WARNING: resolver daemon not answering DNS!"
  # Force restart of a process that's alive but not responding
  if systemctl is-active --quiet cerberus-resolver.service 2>/dev/null; then
    log "Resolver process alive but not responding, restarting..."
    systemctl restart cerberus-resolver.service 2>/dev/null || true
  fi
  return 1
}

apply_iptables() {
  local chain
  chain=$(iptables -N CERBERUS 2>/dev/null; echo CERBERUS) || chain=CERBERUS
  iptables -F CERBERUS

  iptables -A CERBERUS -p tcp --dport 853 -j DROP
  iptables -A CERBERUS -d 1.1.1.1,1.0.0.1 -p tcp --dport 443 -j DROP 2>/dev/null || true
  iptables -A CERBERUS -d 8.8.8.8,8.8.4.4 -p tcp --dport 443 -j DROP 2>/dev/null || true
  iptables -A CERBERUS -d 9.9.9.9,149.112.112.112 -p tcp --dport 443 -j DROP 2>/dev/null || true
  iptables -A CERBERUS -d 208.67.222.222,208.67.220.220 -p tcp --dport 443 -j DROP 2>/dev/null || true
  iptables -A CERBERUS -d 1.1.1.1,1.0.0.1 -p udp --dport 443 -j DROP 2>/dev/null || true
  iptables -A CERBERUS -d 8.8.8.8,8.8.4.4 -p udp --dport 443 -j DROP 2>/dev/null || true
  iptables -A CERBERUS -d 9.9.9.9,149.112.112.112 -p udp --dport 443 -j DROP 2>/dev/null || true
  iptables -A CERBERUS -d 208.67.222.222,208.67.220.220 -p udp --dport 443 -j DROP 2>/dev/null || true
  for ip in 45.90.28.0 45.90.30.0 94.140.14.14 94.140.15.15 76.76.2.0 76.76.10.0; do
    iptables -A CERBERUS -d $ip -p tcp --dport 443 -j DROP 2>/dev/null || true
    iptables -A CERBERUS -d $ip -p udp --dport 443 -j DROP 2>/dev/null || true
  done
  iptables -C OUTPUT -j CERBERUS 2>/dev/null || iptables -A OUTPUT -j CERBERUS

  iptables -t nat -N CERBERUS_NAT 2>/dev/null || true
  iptables -t nat -F CERBERUS_NAT
  iptables -t nat -A CERBERUS_NAT -m owner --uid-owner $RESOLVER_UID -j RETURN
  iptables -t nat -A CERBERUS_NAT -p udp --dport 53 -j REDIRECT --to-ports $RESOLVER_PORT
  iptables -t nat -A CERBERUS_NAT -p tcp --dport 53 -j REDIRECT --to-port $RESOLVER_PORT
  iptables -t nat -C OUTPUT -j CERBERUS_NAT 2>/dev/null || iptables -t nat -A OUTPUT -j CERBERUS_NAT

  log "iptables rules applied"
}

remove_iptables() {
  iptables -D OUTPUT -j CERBERUS 2>/dev/null || true
  iptables -F CERBERUS 2>/dev/null || true
  iptables -X CERBERUS 2>/dev/null || true
  iptables -t nat -D OUTPUT -j CERBERUS_NAT 2>/dev/null || true
  iptables -t nat -F CERBERUS_NAT 2>/dev/null || true
  iptables -t nat -X CERBERUS_NAT 2>/dev/null || true
}

nat_redirect_active() {
  # Verify the OUTPUT jump and the REDIRECT rules actually exist
  iptables -t nat -C OUTPUT -j CERBERUS_NAT 2>/dev/null &&   iptables -t nat -L CERBERUS_NAT -n 2>/dev/null | grep -q "REDIRECT"
}

filter_active() {
  iptables -C OUTPUT -j CERBERUS 2>/dev/null &&   iptables -L CERBERUS -n 2>/dev/null | grep -q 'dpt:853'
}

verify_blocking() {
  local failed=0 dirty=0
  if [[ ! -f "$DB_PATH" ]]; then
    log "Database missing, updating..."
    update_db true
    ((failed++)) || true
    dirty=1
  fi
  local entry_count
  entry_count=$(python3 -c "import sqlite3; db=sqlite3.connect('$DB_PATH'); print(db.execute('SELECT count(*) FROM blocked_domains').fetchone()[0])" 2>/dev/null || echo 0)
  if [[ "$entry_count" -lt 100 ]]; then
    log "Database too small ($entry_count entries), re-updating..."
    update_db true
    ((failed++)) || true
    dirty=1
  fi
  if ! filter_active; then
    log "CERBERUS filter rules missing, re-applying..."
    apply_iptables
    ((failed++)) || true
    dirty=1
  fi
  if ! nat_redirect_active; then
    log "CERBERUS NAT redirect missing, re-applying..."
    apply_iptables
    ((failed++)) || true
    dirty=1
  fi
  ensure_resolver || { ((failed++)) || true; dirty=1; }
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
  local entry_count
  entry_count=$(python3 -c "import sqlite3; db=sqlite3.connect('$DB_PATH'); print(db.execute('SELECT count(*) FROM blocked_domains').fetchone()[0])" 2>/dev/null || echo 0)
  echo "db_entries=$entry_count" > "$state_file"
  iptables -L CERBERUS -n 2>/dev/null | grep -q 'dpt:853' && echo "iptables=active" >> "$state_file" || echo "iptables=inactive" >> "$state_file"
  systemctl is-active --quiet cerberus-resolver.service 2>/dev/null && echo "resolver=active" >> "$state_file" || echo "resolver=inactive" >> "$state_file"
  chmod 644 "$state_file" 2>/dev/null || true
}

do_lock() {
  update_db; apply_iptables; ensure_resolver
  for loc in "${BACKUP_LOCATIONS[@]}"; do [[ -f "$loc" ]] && chattr +i "$loc" 2>/dev/null || true; done
  chattr +i "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
  log "System locked"
}

do_update() {
  local git_url="${GIT_REPO_URL:-https://github.com/W84T/Cerberus.git}"
  local tmpdir
  tmpdir=$(mktemp -d)

  log "Fetching latest from $git_url..."
  git clone --depth 1 "$git_url" "$tmpdir" 2>/dev/null || { log "git clone failed"; rm -rf "$tmpdir"; return 1; }

  log "Updating installed files..."
  for f in "$BINDIR/core.sh" "$BINDIR/cli.sh" "$BINDIR/config" "$BINDIR/custom-block.txt" "$BINDIR/resolver.py" "$BINDIR/blocklist_updater.py"; do
    chattr -i "$f" 2>/dev/null || true
  done
  cp "$tmpdir/core.sh" "$BINDIR/core.sh"
  cp "$tmpdir/cli.sh" "$BINDIR/cli.sh"
  cp "$tmpdir/config" "$BINDIR/config"
  cp "$tmpdir/resolver.py" "$BINDIR/resolver.py"
  cp "$tmpdir/blocklist_updater.py" "$BINDIR/blocklist_updater.py"
  [[ -f "$tmpdir/custom-block.txt" ]] && cp "$tmpdir/custom-block.txt" "$BINDIR/custom-block.txt" || true
  chmod +x "$BINDIR/core.sh" "$BINDIR/cli.sh" "$BINDIR/resolver.py" "$BINDIR/blocklist_updater.py"
  rm -rf "$tmpdir"

  log "Re-applying rules..."
  source "$BINDIR/config"
  apply_iptables
  log "Update complete"
}

do_refresh() {
  update_db true
  ensure_resolver || true
  log "Blocklist force-refreshed"
}

block_add() {
  local domain="$1"; [[ -z "$domain" ]] && { echo "Usage: block_add <domain>"; return 1; }
  domain=$(echo "$domain" | sed 's|^https\?://||; s|/.*||; s|#.*||')
  chattr -i "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
  if grep -qxF "$domain" "$CUSTOM_BLOCK_FILE" 2>/dev/null; then echo "Domain already in block list."
  else echo "$domain" >> "$CUSTOM_BLOCK_FILE"; echo "Added $domain to block list."
  fi
  chattr +i "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
  python3 -c "import sqlite3; db=sqlite3.connect('$DB_PATH'); db.execute('INSERT OR IGNORE INTO blocked_domains (domain,source) VALUES (?,?)', ('$domain','custom')); db.commit(); db.close()" 2>/dev/null || true
  python3 -c "import sqlite3; db=sqlite3.connect('$DB_PATH'); db.execute('INSERT OR IGNORE INTO blocked_domains (domain,source) VALUES (?,?)', ('www.$domain','custom')); db.commit(); db.close()" 2>/dev/null || true
  echo "Domain added to resolver."
}

block_rm() {
  local domain="$1"; [[ -z "$domain" ]] && { echo "Usage: block_rm <domain>"; return 1; }
  domain=$(echo "$domain" | sed 's|^https\?://||; s|/.*||; s|#.*||')
  chattr -i "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
  sed -i "/^$domain$/d" "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
  sed -i "/^www\.$domain$/d" "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
  chattr +i "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
  python3 -c "import sqlite3; db=sqlite3.connect('$DB_PATH'); db.execute('DELETE FROM blocked_domains WHERE domain IN (?,?)', ('$domain','www.$domain')); db.commit(); db.close()" 2>/dev/null || true
  echo "Removed $domain from block list."
}

case "${1:-apply}" in
  apply)     update_db; apply_iptables; ensure_resolver; self_heal ;;
  check)     verify_blocking; self_heal ;;
  lock)      do_lock ;;
  block_add) block_add "${2:-}" ;;
  block_rm)  block_rm "${2:-}" ;;
  status)    save_state; cat /var/lib/cerberus/state 2>/dev/null || echo "state unavailable" ;;
  update)    do_update ;;
  refresh)   do_refresh ;;
  remove_iptables) remove_iptables ;;
  *)         echo "Usage: cerberus {apply|check|lock|block_add|block_rm|status|update|refresh|remove_iptables}"; exit 1 ;;
esac
