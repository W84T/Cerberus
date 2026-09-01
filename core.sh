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

PENALTY_MINUTES="${PENALTY_MINUTES:-1}"
PENALTY_SECONDS="${PENALTY_SECONDS:-}"
PENALTY_SIGNAL_FILE="${PENALTY_SIGNAL_FILE:-/var/lib/cerberus/penalty_signal}"
PENALTY_STATE_FILE="${PENALTY_STATE_FILE:-/var/lib/cerberus/penalty_state}"
PENALTY_LOG_FILE="${PENALTY_LOG_FILE:-/var/lib/cerberus/penalty.log}"
DESKTOP_USER="${DESKTOP_USER:-}"

# Permanent human-readable log of every penalty trigger (with the domain that
# caused it) and each unblock. Independent of journald, so there's a durable
# record of WHY the internet was cut even if the journal is cleared.
penalty_log() {
  local stamp; stamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "$stamp $*" >> "$PENALTY_LOG_FILE" 2>/dev/null || true
}

penalty_duration() {
  # Duration in seconds. PENALTY_SECONDS wins if set, else PENALTY_MINUTES*60.
  if [[ -n "$PENALTY_SECONDS" ]]; then echo "$PENALTY_SECONDS"; else echo "$(( PENALTY_MINUTES * 60 ))"; fi
}

penalty_text() {
  # Human label, e.g. "30 seconds" or "5 minutes".
  if [[ -n "$PENALTY_SECONDS" ]]; then echo "${PENALTY_SECONDS} seconds"; else echo "${PENALTY_MINUTES} minutes"; fi
}

# Safety net: hard ceiling on a *continuous* block, so repeated hits can never
# leave the machine permanently offline (e.g. runaway/stale reset loop). Even if
# the user keeps hitting blocked sites, the block is force-lifted once this
# ceiling is reached since the penalty first started.
MAX_PENALTY_SECONDS="${MAX_PENALTY_SECONDS:-600}"

penalty_started_at() {
  # First-seen time persisted the first time a penalty engages. Empty if none.
  # `|| true` keeps this from returning non-zero (missing file) so callers using
  # `var=$(penalty_started_at)` under `set -e` don't abort.
  sed -n 's/^penalty_started=//p' "$PENALTY_STATE_FILE" 2>/dev/null || true
}

penalty_active() {
  [[ -f "$PENALTY_STATE_FILE" ]] || return 1
  local until start now
  until=$(sed -n 's/^penalty_until=//p' "$PENALTY_STATE_FILE" 2>/dev/null)
  [[ -n "$until" ]] || return 1
  now=$(date +%s)
  # Safety net: even if the state file is corrupted/huge, never consider the
  # block active beyond the hard ceiling since it first started.
  start=$(sed -n 's/^penalty_started=//p' "$PENALTY_STATE_FILE" 2>/dev/null)
  if [[ -n "$start" ]] && (( now >= start + MAX_PENALTY_SECONDS )); then
    return 1
  fi
  [[ "$now" -lt "$until" ]]
}

penalty_rule_present() {
  # Guarded so the (expected) iptables exit code 2 when the chain is absent
  # can never trigger `set -e` and abort the script.
  if iptables -C OUTPUT -j CERBERUS_PENALTY 2>/dev/null; then
    return 0
  fi
  return 1
}

penalty_block() {
  local now; now=$(date +%s)
  local start; start=$(penalty_started_at)
  [[ -z "$start" ]] && start="$now"   # first engagement records the ceiling start
  local dur; dur=$(penalty_duration)
  local until=$(( now + dur ))
  # Cap so a continuous block never exceeds the safety-net ceiling
  local cap=$(( start + MAX_PENALTY_SECONDS ))
  if (( until > cap )); then until="$cap"; fi
  printf 'penalty_until=%s\npenalty_started=%s\n' "$until" "$start" > "$PENALTY_STATE_FILE"
  chmod 644 "$PENALTY_STATE_FILE" 2>/dev/null || true
  iptables -N CERBERUS_PENALTY 2>/dev/null || true
  iptables -F CERBERUS_PENALTY 2>/dev/null || true
  iptables -A CERBERUS_PENALTY -o lo -j RETURN 2>/dev/null || true
  iptables -A CERBERUS_PENALTY -j DROP 2>/dev/null || true
  penalty_rule_present || iptables -I OUTPUT 1 -j CERBERUS_PENALTY 2>/dev/null || true
  log "PENALTY: internet disabled for $(penalty_text)"
}

penalty_unblock() {
  iptables -D OUTPUT -j CERBERUS_PENALTY 2>/dev/null || true
  iptables -F CERBERUS_PENALTY 2>/dev/null || true
  iptables -X CERBERUS_PENALTY 2>/dev/null || true
  rm -f "$PENALTY_STATE_FILE" 2>/dev/null || true
  penalty_log "PENALTY LIFTED: internet restored"
  log "PENALTY: internet restored"
}

notify_penalty() {
  local du="${DESKTOP_USER:-}"
  [[ -z "$du" ]] && du=$(loginctl list-sessions --no-legend 2>/dev/null | awk 'NF>=4 && $4!="-"{print $3; exit}')
  # No desktop user detected: skip the popup (portable; a wrong guess would only
  # notify a non-existent account). The internet cut still applies.
  [[ -z "$du" ]] && return 0
  local uid; uid=$(id -u "$du" 2>/dev/null || echo 1000)
  local msg="Cerberus: blocked content detected. Internet disabled for $(penalty_text)."
  local envs="DISPLAY=${DISPLAY:-:0} XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus"
  sudo -u "$du" env $envs notify-send -u critical "Cerberus" "$msg" 2>/dev/null || \
  env $envs notify-send -u critical "Cerberus" "$msg" 2>/dev/null || true
}

penalty_hit() {
  # Called by the watchdog when a fresh blocked query is detected.
  # Extends the penalty window to now+MINUTES, applies the block, clears the
  # signal, and notifies (only when transitioning from inactive -> active).
  local was_active=0; penalty_active && was_active=1
  # Capture the triggering domain from the resolver's signal file before clearing.
  local domain=""
  [[ -f "$PENALTY_SIGNAL_FILE" ]] && domain=$(head -1 "$PENALTY_SIGNAL_FILE" 2>/dev/null | tr -d '\r\n')
  [[ -z "$domain" ]] && domain="(unknown)"
  penalty_block
  penalty_log "PENALTY TRIGGERED by blocked domain: $domain -> internet cut for $(penalty_text)"
  rm -f "$PENALTY_SIGNAL_FILE" 2>/dev/null || true
  (( was_active == 0 )) && notify_penalty
}

ensure_penalty() {
  # Lightweight reconcile: enforce an active penalty, or lift an expired one.
  # Always returns 0 so callers under `set -e` (e.g. self_heal) don't abort.
  if penalty_active; then
    penalty_rule_present || penalty_block
  else
    penalty_rule_present && penalty_unblock
  fi
  return 0
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
    if ! systemctl is-active --quiet "$UNIT_RESOLVER" 2>/dev/null; then
      log "Starting resolver daemon..."
      systemctl start "$UNIT_RESOLVER" 2>/dev/null || true
      sleep 1
    fi
    if dns_reachable; then
      return 0
    fi
    sleep 1
  done
  log "WARNING: resolver daemon not answering DNS!"
  # Force restart of a process that's alive but not responding
  if systemctl is-active --quiet "$UNIT_RESOLVER" 2>/dev/null; then
    log "Resolver process alive but not responding, restarting..."
    systemctl restart "$UNIT_RESOLVER" 2>/dev/null || true
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
  ensure_penalty
  save_state
}

ensure_guardians() {
  # Keep the redundant watchdog units armed so no single `systemctl stop`
  # (or even stop of two units) can take Cerberus down for more than a few
  # seconds. This runs from the 60s timer, the instant watchdog, and the
  # watcher-of-the-watcher, providing mutual trampoline recovery.
  for u in "$UNIT_WDI" "$UNIT_WD_TIMER" "$UNIT_WDW" "$UNIT_WDW_TIMER"; do
    if ! systemctl is-enabled --quiet "$u" 2>/dev/null; then
      systemctl enable "$u" 2>/dev/null || true
      log "re-enabled $u"
    fi
    if [[ "$u" == *.timer ]] && ! systemctl is-active --quiet "$u" 2>/dev/null; then
      systemctl start "$u" 2>/dev/null || true
      log "restarted $u"
    fi
  done
  # Explicitly ensure the two persistent daemons that matter are up
  for d in "$UNIT_WDI" "$UNIT_RESOLVER"; do
    if ! systemctl is-active --quiet "$d" 2>/dev/null; then
      systemctl start "$d" 2>/dev/null || true
      log "restarted $d"
    fi
  done
}

save_state() {
  local state_file="/var/lib/cerberus/state"
  local entry_count
  entry_count=$(python3 -c "import sqlite3; db=sqlite3.connect('$DB_PATH'); print(db.execute('SELECT count(*) FROM blocked_domains').fetchone()[0])" 2>/dev/null || echo 0)
  echo "db_entries=$entry_count" > "$state_file"
  iptables -L CERBERUS -n 2>/dev/null | grep -q 'dpt:853' && echo "iptables=active" >> "$state_file" || echo "iptables=inactive" >> "$state_file"
  systemctl is-active --quiet "$UNIT_RESOLVER" 2>/dev/null && echo "resolver=active" >> "$state_file" || echo "resolver=inactive" >> "$state_file"
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
  # Preserve the per-install randomized unit mapping across the config update
  local saved_units=""
  if grep -qF "# ==BEGIN RANDOMIZED UNIT MAPPING==" "$BINDIR/config" 2>/dev/null; then
    saved_units=$(sed -n "/# ==BEGIN RANDOMIZED UNIT MAPPING==/,/# ==END RANDOMIZED UNIT MAPPING==/p" "$BINDIR/config")
  fi
  for f in "$BINDIR/core.sh" "$BINDIR/cli.sh" "$BINDIR/config" "$BINDIR/custom-block.txt" "$BINDIR/resolver.py" "$BINDIR/blocklist_updater.py" "$BINDIR/watchdog.py" "$BINDIR/watcher.py"; do
    chattr -i "$f" 2>/dev/null || true
  done
  cp "$tmpdir/core.sh" "$BINDIR/core.sh"
  cp "$tmpdir/cli.sh" "$BINDIR/cli.sh"
  cp "$tmpdir/config" "$BINDIR/config"
  cp "$tmpdir/resolver.py" "$BINDIR/resolver.py"
  cp "$tmpdir/blocklist_updater.py" "$BINDIR/blocklist_updater.py"
  [[ -f "$tmpdir/watchdog.py" ]] && cp "$tmpdir/watchdog.py" "$BINDIR/watchdog.py" || true
  [[ -f "$tmpdir/watcher.py" ]] && cp "$tmpdir/watcher.py" "$BINDIR/watcher.py" || true
  [[ -f "$tmpdir/custom-block.txt" ]] && cp "$tmpdir/custom-block.txt" "$BINDIR/custom-block.txt" || true
  if [[ -n "$saved_units" ]] && ! grep -qF "# ==BEGIN RANDOMIZED UNIT MAPPING==" "$BINDIR/config"; then
    printf '\n%s\n' "$saved_units" >> "$BINDIR/config"
  fi
  # Rewrite any template home paths in BACKUP_LOCATIONS to this machine's user
  # so a self-update doesn't reset per-user backup copies to a template account.
  local _home
  _home=$(getent passwd "${SUDO_USER:-$(loginctl list-sessions --no-legend 2>/dev/null | awk 'NF>=4 && $4!="-"{print $3; exit}')}" 2>/dev/null | cut -d: -f6)
  [[ -z "$_home" ]] && _home=$(getent passwd root | cut -d: -f6)
  if [[ -n "$_home" ]]; then
    sed -i "s#/home/[a-zA-Z0-9_.-]*/.config/systemd/user/.helper#$_home/.config/systemd/user/.helper#g" "$BINDIR/config"
    sed -i "s#/home/[a-zA-Z0-9_.-]*/.local/share/applications/.update#$_home/.local/share/applications/.update#g" "$BINDIR/config"
  fi
  chmod +x "$BINDIR/core.sh" "$BINDIR/cli.sh" "$BINDIR/resolver.py" "$BINDIR/blocklist_updater.py"
  rm -rf "$tmpdir"

  log "Re-applying rules..."
  source "$BINDIR/config"
  apply_iptables
  # Re-lock the protected files
  for f in "$BINDIR/core.sh" "$BINDIR/resolver.py" "$BINDIR/config" "$BINDIR/watchdog.py"; do
    chattr +i "$f" 2>/dev/null || true
  done
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
  check)     verify_blocking; self_heal; ensure_guardians ;;
  lock)      do_lock ;;
  block_add) block_add "${2:-}" ;;
  block_rm)  block_rm "${2:-}" ;;
  status)    save_state; cat /var/lib/cerberus/state 2>/dev/null || echo "state unavailable" ;;
  update)    do_update ;;
  refresh)   do_refresh ;;
  remove_iptables) remove_iptables ;;
  penalty_hit)     penalty_hit ;;
  penalty_check)   ensure_penalty ;;
  penalty_clear)   penalty_unblock ;;
  *)         echo "Usage: cerberus {apply|check|lock|block_add|block_rm|status|update|refresh|remove_iptables|penalty_hit|penalty_check|penalty_clear}"; exit 1 ;;
esac
