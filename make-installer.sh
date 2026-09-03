#!/bin/bash
# Developer-side generator for the Cerberus single-file installer.
#
# Usage (run from the repo root, does NOT require the end user's machine):
#   ./make-installer.sh
#
# Emits a single self-contained ./cerberus-install.sh that embeds every
# component setup.sh needs. The end user downloads and runs ONLY that one file;
# they never receive the readable source repo, so there is nothing left to
# tinker with in order to weaken Cerberus. On a successful install the installer
# also deletes itself, so no readable payload remains on disk.
set -euo pipefail
cd "$(dirname "$0")"

OUT="cerberus-install.sh"

# Everything setup.sh reads from $SCRIPT_DIR. Keep in sync with setup.sh.
COMPONENTS=(
  setup.sh
  core.sh
  cli.sh
  config
  custom-block.txt
  blockpage.py
  resolver.py
  blocklist_updater.py
  watchdog.py
  watcher.py
  AI_POLICY.md
)

for f in "${COMPONENTS[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: required component missing: $f" >&2
    exit 1
  fi
done

read -r -d '' STUB <<'STUB' || true
#!/bin/bash
# Cerberus Content Filter - single self-contained installer.
# Run as root or with sudo. Extracts its embedded components, runs the install,
# then removes itself so no readable source is left behind.
set -euo pipefail

# Re-exec as root if needed, preserving the invoking (human) user so setup.sh's
# sudoers rule and per-user backup paths resolve to the right account.
if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

TMP="$(mktemp -d /tmp/cerberus-install.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "Cerberus - extracting installer components..."
MARKER_LINE=$(grep -an '^#__PAYLOAD_BELOW__$' "$0" | tail -1 | cut -d: -f1)
tail -n +"$((MARKER_LINE+1))" "$0" | tar xz -C "$TMP"

echo "Cerberus - running setup (installing, this may take a moment)..."
"$TMP/setup.sh"

echo ""
echo "Cerberus is installed and active. The installer has removed itself so"
echo "there is no readable source on this machine to tinker with."
echo "Use: cerberus status"
echo ""
if [[ -f "$0" ]]; then
  rm -f "$0"
fi
exit 0

#__PAYLOAD_BELOW__
STUB

PAYLOAD="/tmp/cerberus-payload.$$.tar.gz"
trap 'rm -f "$PAYLOAD"' EXIT

tar -czf "$PAYLOAD" "${COMPONENTS[@]}"

{
  printf '%s\n' "$STUB"
  cat "$PAYLOAD"
} > "$OUT"

chmod +x "$OUT"
echo "Built $OUT: $(wc -c < "$OUT") bytes, ${#COMPONENTS[@]} components embedded."
