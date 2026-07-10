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
  lsattr /etc/hosts 2>/dev/null | grep -q '^....i' && chattr -i /etc/hosts 2>/dev/null || true
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
  local tmp="" marker_found=false custom_domains="" old_hash="" new_hash=""
  grep -qF "$MARKER" /etc/hosts 2>/dev/null && marker_found=true
  if [[ -f "$CUSTOM_BLOCK_FILE" ]]; then
    custom_domains=$(grep -v '^#' "$CUSTOM_BLOCK_FILE" | grep -v '^[[:space:]]*$' 2>/dev/null || true)
    new_hash=$(echo "$custom_domains" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "none")
  fi
  old_hash=$(grep "# Custom hash:" /etc/hosts 2>/dev/null | cut -d: -f2 | tr -d ' ') || true
  local need_refresh=false
  ! $marker_found && need_refresh=true
  [[ -n "$custom_domains" ]] && [[ "$new_hash" != "$old_hash" ]] && need_refresh=true
  [[ -z "$custom_domains" ]] && grep -q "# Custom blocked domains" /etc/hosts 2>/dev/null && need_refresh=true
  if $need_refresh; then
    log "Refreshing hosts blocklist..."
    lsattr /etc/hosts 2>/dev/null | grep -q '^....i' && chattr -i /etc/hosts 2>/dev/null || true
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
    lsattr /etc/hosts 2>/dev/null | grep -q '^....i' || chattr +i /etc/hosts 2>/dev/null || true
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
  lsattr /etc/hosts 2>/dev/null | grep -q '^....i' || chattr +i /etc/hosts 2>/dev/null || true
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

block_add() {
  local domain="$1"; [[ -z "$domain" ]] && { echo "Usage: block_add <domain>"; return 1; }
  lsattr "$CUSTOM_BLOCK_FILE" 2>/dev/null | grep -q '^....i' && chattr -i "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
  if grep -qxF "$domain" "$CUSTOM_BLOCK_FILE" 2>/dev/null; then echo "Domain already in block list."
  else echo "$domain" >> "$CUSTOM_BLOCK_FILE"; echo "Added $domain to block list."
  fi
  chattr +i "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
}

block_rm() {
  local domain="$1"; [[ -z "$domain" ]] && { echo "Usage: block_rm <domain>"; return 1; }
  lsattr "$CUSTOM_BLOCK_FILE" 2>/dev/null | grep -q '^....i' && chattr -i "$CUSTOM_BLOCK_FILE" 2>/dev/null || true
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
  *)         echo "Usage: cerberus {apply|check|lock|block_add|block_rm|safesearch|status}"; exit 1 ;;
esac
