#!/bin/bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  exec sudo -n "$(realpath "$0")" "$@"
fi

CORE="/opt/cerberus/core.sh"
CUSTOM_BLOCK_FILE="/opt/cerberus/custom-block.txt"

usage() {
  cat <<EOF
Usage: cerberus <command>

Commands:
  status                  Show blocking status
  lock                    Apply and lock immediately
  block add <domain>      Add domain to block list
  block rm <domain>       Remove domain from block list
  block list              Show custom blocked domains
  update                  Self-update from git and reinstall
  refresh                 Force refresh blocklist from internet
  penalty                 Show penalty duration
  penalty <minutes>       Set penalty duration (minimum 5 minutes)
  help                    Show this help
EOF
}

case "${1:-help}" in
  status)
    echo "=== Cerberus Status ==="
    source /opt/cerberus/config
    db_path="${DB_PATH:-/opt/cerberus/cerberus.db}"
    if [[ -f "$db_path" ]]; then
      entry_count=$(python3 -c "import sqlite3; db=sqlite3.connect('$db_path'); print(db.execute('SELECT count(*) FROM blocked_domains').fetchone()[0])" 2>/dev/null || echo "?")
      echo "  Database:        ACTIVE ($entry_count domains)"
    else
      echo "  Database:        MISSING"
    fi
    if iptables -L CERBERUS -n 2>/dev/null | grep -q 'dpt:853'; then
      echo "  iptables rules:  ACTIVE"
    else
      echo "  iptables rules:  MISSING"
    fi
    if systemctl is-active --quiet "${UNIT_RESOLVER:-cerberus-resolver.service}" 2>/dev/null; then
      echo "  DNS resolver:    ACTIVE"
    else
      echo "  DNS resolver:    INACTIVE"
    fi
    if [[ -f "$CUSTOM_BLOCK_FILE" ]] && [[ -s "$CUSTOM_BLOCK_FILE" ]]; then
      echo "  Custom blocked:  $(wc -l < "$CUSTOM_BLOCK_FILE") domains"
    fi
    ;;

  lock)
    "$CORE" lock
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

  update)
    echo "=== Cerberus Self-Update ==="
    "$CORE" update || rc=$?
    [[ ${rc:-1} -eq 2 ]] && echo "Nothing to update." || echo "Update complete."
    ;;
  refresh)
    echo "=== Cerberus Force Refresh ==="
    "$CORE" refresh
    echo "Refresh complete."
    ;;

  penalty)
    arg="${2:-}"
    if [[ -z "$arg" ]]; then
      # Show current duration (in minutes)
      source /opt/cerberus/config
      pen_sec="${PENALTY_SECONDS:-}"
      if [[ -n "$pen_sec" ]]; then
        printf "Penalty duration: %s seconds\n" "$pen_sec"
      else
        printf "Penalty duration: %s minutes\n" "${PENALTY_MINUTES:-5}"
      fi
      exit 0
    fi
    # Change duration: interpret as minutes, enforced minimum 5
    if [[ ! "$arg" =~ ^[0-9]+$ ]]; then
      echo "Usage: cerberus penalty <minutes>   (minimum 5)"
      exit 1
    fi
    if (( arg < 5 )); then
      echo "Penalty minimum is 5 minutes (requested: $arg)."
      exit 1
    fi
    # Update installed config (unlock, set PENALTY_MINUTES, clear PENALTY_SECONDS so
    # minutes applies, then re-lock). Disabling is not possible.
    chattr -i /opt/cerberus/config 2>/dev/null || true
    sed -i "s/^PENALTY_MINUTES=.*/PENALTY_MINUTES=$arg/" /opt/cerberus/config
    sed -i "/^PENALTY_SECONDS=/d" /opt/cerberus/config
    chattr +i /opt/cerberus/config 2>/dev/null || true
    echo "Penalty duration set to $arg minutes (minimum enforced: 5)."
    ;;

  help|*)
    usage
    ;;
esac
