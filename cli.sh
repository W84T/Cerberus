#!/bin/bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  exec sudo -n "$(realpath "$0")" "$@"
fi

CORE="/opt/cerberus/core.sh"
CUSTOM_BLOCK_FILE="/opt/cerberus/custom-block.txt"

banner() {
  cat <<'EOF'
     ██████╗███████╗██████╗ ██████╗ ███████╗██████╗ ██╗   ██╗███████╗
    ██╔════╝██╔════╝██╔══██╗██╔══██╗██╔════╝██╔══██╗██║   ██║██╔════╝
    ██║     █████╗  ██████╔╝██████╔╝█████╗  ██████╔╝██║   ██║███████╗
    ██║     ██╔══╝  ██╔══██╗██╔══██╗██╔══╝  ██╔══██╗██║   ██║╚════██║
    ╚██████╗███████╗██║  ██║██████╔╝███████╗██║  ██║╚██████╔╝███████║
     ╚═════╝╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝
EOF
  echo "     Guarding your internet — every query, always."
}

usage() {
  banner
  cat <<EOF

Usage: cerberus <command>

Commands:
  status                  Show blocking status
  lock                    Apply and lock immediately
  block add <domain>      Add domain to block list
  block list              Show custom blocked domains
  update                  Self-update from git and reinstall
  refresh                 Force refresh blocklist from internet
  adult-find              Discover & block adult manga/manhwa sites (crt.sh)
  private on|off|status   Disable/enable Firefox Private Browsing + Chromium Incognito
  help                    Show this help
  menu                    Open the interactive menu
EOF
}

menu() {
  # Interactive control panel: clears the screen, presents a numbered menu, and
  # keeps looping until the user chooses Exit (0/q) or presses Ctrl+C.
  trap 'clear; echo "Goodbye."; exit 0' INT
  local choice=""
  clear
  while true; do
    clear
    banner
    cat <<EOF

  ┌──────────────────────────────────────────────────────┐
  │              CERBERUS CONTROL CENTER                 │
  ├──────────────────────────────────────────────────────┤
  │   1)  Status                   5)  Refresh List      │
  │   2)  Lock                      6)  Update           │
  │   3)  Block List                                      │
  │   4)  Add Blocked Domain                             │
  ├──────────────────────────────────────────────────────┤
  │   0)  Exit                                           │
  └──────────────────────────────────────────────────────┘

EOF
    printf "  Select an option (0 to exit): "
    read -r choice || exit 0
    case "$choice" in
      1) "$0" status ;;
      2) "$0" lock ;;
      3) "$0" block list ;;
      4) printf "  Domain to block: "; read -r d; [[ -n "$d" ]] && "$0" block add "$d" ;;
      5) "$0" refresh ;;
      6) "$0" update ;;
      0|q|Q) clear; echo "Goodbye."; exit 0 ;;
      *) echo "  Invalid option: $choice" ;;
    esac
    printf "\n  Press Enter to continue... "
    read -r _
  done
}

case "${1:-}" in
  status)
    banner
    echo ""
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
      list)
        if [[ -f "$CUSTOM_BLOCK_FILE" ]] && [[ -s "$CUSTOM_BLOCK_FILE" ]]; then
          echo "=== Custom Blocked Domains ==="
          cat "$CUSTOM_BLOCK_FILE"
        else
          echo "No custom blocked domains."
        fi
        ;;
      *)
        echo "Usage: cerberus block add|list <domain>"
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
  adult-find)
    echo "=== Cerberus Adult-Site Discovery ==="
    "$CORE" adult_find
    echo "Discovery complete."
    ;;

  private)
    action="${2:-status}"
    case "$action" in
      on)  "$CORE" browser_policy enforce; echo "Private Browsing / Incognito disabled across browsers." ;;
      off) "$CORE" browser_policy remove; echo "Private Browsing / Incognito re-enabled." ;;
      status) "$CORE" browser_policy check ;;
      *)   echo "Usage: cerberus private on|off|status" ;;
    esac
    ;;

  ""|menu)
    menu
    ;;

  help|*)
    usage
    ;;
esac
