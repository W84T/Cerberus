#!/bin/bash
set -euo pipefail

# Re-exec with sudo if not already root
if [[ "$EUID" -ne 0 ]]; then
  exec sudo -n "$(realpath "$0")" "$@"
fi

CORE="/opt/cerberus/core.sh"
CONFIG="/opt/cerberus/config"
UNLOCK_FILE="/opt/cerberus/.unlock"
CUSTOM_BLOCK_FILE="/opt/cerberus/custom-block.txt"

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
  update                  Refresh blocklist from internet
  help                    Show this help
EOF
}

parse_duration() {
  local input num unit
  input="${1:-24h}"
  num="${input//[a-zA-Z]/}"
  unit="${input//[0-9]/}"
  case "$unit" in
    s|S) echo $((num * 1)) ;;
    m|M) echo $((num * 60)) ;;
    h|H) echo $((num * 3600)) ;;
    d|D) echo $((num * 86400)) ;;
    *)   echo $((num * 3600)) ;;
  esac
}

case "${1:-help}" in
  status)
    echo "=== Cerberus Status ==="
    if grep -q "# Blocked domains - Cerberus" /etc/hosts 2>/dev/null; then
      echo "  Hosts blocklist: ACTIVE ($(grep -c '^127\.0\.0\.1' /etc/hosts 2>/dev/null || echo '?') entries)"
    else
      echo "  Hosts blocklist: MISSING"
    fi
    if iptables -L CERBERUS -n 2>/dev/null | grep -q 'dpt:53'; then
      echo "  iptables rules:  ACTIVE"
    else
      echo "  iptables rules:  MISSING"
    fi
    if lsattr /etc/hosts 2>/dev/null | grep -q '^....i'; then
      echo "  Hosts immutable: YES"
    else
      echo "  Hosts immutable: NO"
    fi
    if [[ -f "$UNLOCK_FILE" ]]; then
      expiry=$(cat "$UNLOCK_FILE" 2>/dev/null || echo "0")
      now=$(date +%s)
      if (( now < expiry )); then
        remain=$(( expiry - now ))
        echo "  Unlock pending:  ${remain}s remaining"
      else
        echo "  Unlock pending:  expired (will apply on next check)"
      fi
    else
      echo "  Unlock pending:  NO"
    fi
    if [[ -f "$CUSTOM_BLOCK_FILE" ]] && [[ -s "$CUSTOM_BLOCK_FILE" ]]; then
      echo "  Custom blocked:  $(wc -l < "$CUSTOM_BLOCK_FILE") domains"
    fi
    if grep -q "# Cerberus SafeSearch" /etc/hosts 2>/dev/null; then
      echo "  SafeSearch:      ACTIVE ($(grep -c '^216\.239\.38\.120\|^13\.107\.21\.200' /etc/hosts 2>/dev/null || echo '?') redirects)"
    else
      echo "  SafeSearch:      OFF"
    fi
    ;;

  lock)
    "$CORE" lock
    ;;

  unlock)
    duration="${2:-24h}"
    seconds=$(parse_duration "$duration")
    expiry=$(($(date +%s) + seconds))
    echo "Unlock requested in $duration (expires $(date -d "@$expiry" '+%Y-%m-%d %H:%M'))"
    echo "Cancel with: cerberus cancel"
    echo "$expiry" > "$UNLOCK_FILE"
    ;;

  cancel)
    if [[ -f "$UNLOCK_FILE" ]]; then
      echo "Cancelling unlock request..."
      echo "Are you sure you want to cancel? This is why you set this up."
      echo "Waiting 10 seconds. Press Ctrl+C to abort."
      sleep 10
      rm -f "$UNLOCK_FILE"
      echo "Cancelled."
    else
      echo "No pending unlock request."
    fi
    ;;

  block)
    action="${2:-}"
    domain="${3:-}"
    case "$action" in
      add)
        if [[ -z "$domain" ]]; then
          echo "Usage: cerberus block add <domain>"
          exit 1
        fi
        "$CORE" block_add "$domain"
        "$CORE" apply
        ;;
      rm)
        if [[ -z "$domain" ]]; then
          echo "Usage: cerberus block rm <domain>"
          exit 1
        fi
        "$CORE" block_rm "$domain"
        "$CORE" apply
        ;;
      list)
        if [[ -f "$CUSTOM_BLOCK_FILE" ]] && [[ -s "$CUSTOM_BLOCK_FILE" ]]; then
          echo "=== Custom Blocked Domains ==="
          cat "$CUSTOM_BLOCK_FILE"
        else
          echo "No custom blocked domains."
        fi
        ;;
      *)
        echo "Usage: cerberus block add|rm|list <domain>"
        ;;
    esac
    ;;

  whitelist)
    action="${2:-}"
    domain="${3:-}"
    if [[ -z "$action" || -z "$domain" ]]; then
      echo "Usage: cerberus whitelist add|rm <domain>"
      exit 1
    fi
    case "$action" in
      add)
        if grep -qF "$domain" "$CONFIG" 2>/dev/null; then
          echo "Domain already in whitelist."
        else
          sed -i "/^WHITELIST_DOMAINS=(/a\\  \"$domain\"" "$CONFIG"
          echo "Added $domain to whitelist."
          "$CORE" apply
        fi
        ;;
      rm)
        sed -i "/\"$domain\"/d" "$CONFIG"
        echo "Removed $domain from whitelist."
        "$CORE" apply
        ;;
      *)
        echo "Usage: cerberus whitelist add|rm <domain>"
        ;;
    esac
    ;;

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

  update)
    echo "Updating blocklist..."
    "$CORE" apply
    echo "Done."
    ;;

  help|*)
    usage
    ;;
esac
