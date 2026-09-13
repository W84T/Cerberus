#!/bin/bash
# Cerberus: harden browsers via system policy.
#   firefox-policy.sh enforce   write Firefox + Chromium hardening policies
#   firefox-policy.sh check     verify policies are in place
#   firefox-policy.sh remove    remove all hardening (restore default browser)
set -euo pipefail
source /opt/cerberus/config
BINDIR="/opt/cerberus"
FIREFOX_POLICY="/usr/lib/firefox/distribution/policies.json"
CHROMIUM_POLICY_DIR="/etc/chromium/policies/managed"
CHROMIUM_POLICY="$CHROMIUM_POLICY_DIR/cerberus.json"
MODE="${1:-enforce}"

log() { echo "[cerberus-firefox-policy] $*"; }

# ─────────────────────────────────────────────────────────────────────
# Firefox: disable Private Browsing so filters can't be sidestepped.
# (DNS filtering already applies in private windows; this removes the
#  escape-hatch UI entirely and is enforced via enterprise policy.)
# ─────────────────────────────────────────────────────────────────────
write_firefox() {
  chattr -i "$FIREFOX_POLICY" 2>/dev/null || true
  mkdir -p "$(dirname "$FIREFOX_POLICY")"
  cat > "$FIREFOX_POLICY" << 'EOF'
{
  "policies": {
    "DisablePrivateBrowsing": true
  }
}
EOF
  chmod 644 "$FIREFOX_POLICY"
  chattr +i "$FIREFOX_POLICY" 2>/dev/null || true
  log "wrote $FIREFOX_POLICY (Private Browsing disabled)"
}

# ─────────────────────────────────────────────────────────────────────
# Chromium: disable Incognito mode (available if chromium is installed).
# ─────────────────────────────────────────────────────────────────────
write_chromium() {
  chattr -i "$CHROMIUM_POLICY" 2>/dev/null || true
  mkdir -p "$CHROMIUM_POLICY_DIR"
  cat > "$CHROMIUM_POLICY" << 'EOF'
{
  "IncognitoModeAvailability": 1
}
EOF
  chmod 644 "$CHROMIUM_POLICY"
  chattr +i "$CHROMIUM_POLICY" 2>/dev/null || true
  log "wrote $CHROMIUM_POLICY (Incognito mode disabled)"
}

check() {
  local ok=1
  if [ -f "$FIREFOX_POLICY" ] && grep -q DisablePrivateBrowsing "$FIREFOX_POLICY"; then
    echo "firefox private browsing: disabled (policy)"
  else
    echo "firefox private browsing: ENABLED (no policy)"; ok=0
  fi
  if [ -f "$CHROMIUM_POLICY" ] && grep -q IncognitoModeAvailability "$CHROMIUM_POLICY"; then
    echo "chromium incognito: disabled (policy)"
  else
    echo "chromium incognito: ENABLED (no policy)"; ok=0
  fi
  return $ok
}

remove() {
  chattr -i "$FIREFOX_POLICY" "$CHROMIUM_POLICY" 2>/dev/null || true
  rm -f "$FIREFOX_POLICY" "$CHROMIUM_POLICY"
  log "removed browser policies (Private Browsing / Incognito restored)"
}

case "$MODE" in
  enforce) write_firefox; write_chromium ;;
  check)   check ;;
  remove)  remove ;;
  *) echo "usage: firefox-policy.sh [enforce|check|remove]"; exit 1 ;;
esac