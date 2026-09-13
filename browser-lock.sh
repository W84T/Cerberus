#!/bin/bash
# Cerberus browser lockdown: force-installs the keyword-blocker extension into
# Firefox via enterprise policy, so it cannot be disabled or removed from the
# browser UI. Generates the extension from embedded sources, builds the .xpi,
# serves keywords to the extension through the block-page server, and locks
# all artefacts with the immutable flag.
#
# Usage:
#   browser-lock.sh            build + enforce (install/pin the extension)
#   browser-lock.sh check      verify policy, xpi and keywords JSON exist
set -euo pipefail
source /opt/cerberus/config
BINDIR="/opt/cerberus"
EXT_SRC="$BINDIR/ext"
MODE="${1:-enforce}"

log() { echo "[cerberus-browser-lock] $*"; }

# ── find keywords in config's SEARCH_BLOCK_KEYWORDS array ──────────
config_keywords() {
  python3 - "$BINDIR/config" << 'PY'
import sys
kws = []
in_sec = False
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith("SEARCH_BLOCK_KEYWORDS=("):
        in_sec = True
        continue
    if in_sec:
        if line == ")":
            break
        s = line.strip('"')
        if s and not s.startswith("#"):
            kws.append(s)
print(" ".join(f'"{k}"' for k in kws))
PY
}

# ── write the JSON the extension polls (served by blockpage.py) ────
gen_keywords_json() {
  python3 - "$BINDIR/config" "$SEARCH_KEYWORDS_JSON" << 'PY'
import sys, json
kws = []
in_sec = False
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith("SEARCH_BLOCK_KEYWORDS=("):
        in_sec = True
        continue
    if in_sec:
        if line == ")":
            break
        s = line.strip('"')
        if s and not s.startswith("#"):
            kws.append(s)
with open(sys.argv[2], "w") as f:
    json.dump({"keywords": kws}, f)
PY
  chmod 644 "$SEARCH_KEYWORDS_JSON"
  log "wrote $SEARCH_KEYWORDS_JSON ($(config_keywords | wc -w) keywords)"
}

# ── embedded extension sources ─────────────────────────────────────
write_ext_sources() {
  rm -rf "$EXT_SRC"; mkdir -p "$EXT_SRC"
  cat > "$EXT_SRC/manifest.json" << 'MFEOF'
{
  "manifest_version": 3,
  "name": "Cerberus Keyword Blocker",
  "version": "1.0.0",
  "description": "Cerberus content filter: blocks pages and searches whose URL contains a blocked keyword.",
  "permissions": ["webRequest", "webRequestBlocking", "storage"],
  "host_permissions": ["<all_urls>", "http://127.0.0.1/*"],
  "background": { "scripts": ["background.js"] },
  "browser_specific_settings": {
    "gecko": {
      "id": "cerberus-keyword-block@cerberus.local",
      "strict_min_version": "109.0"
    }
  }
}
MFEOF
  cat > "$EXT_SRC/background.js" << 'BJEOF'
const KW_URL = "http://127.0.0.1/cerberus/keywords.json";
const REFRESH_MS = 60000;
let KEYWORDS = [];

function trim(list) {
  return (list || []).map(s => String(s).toLowerCase().trim()).filter(s => s.length);
}

async function loadBundled() {
  try {
    const r = await fetch(browser.runtime.getURL("keywords.json"));
    const j = await r.json();
    return trim(j.keywords);
  } catch (e) { return []; }
}

async function refreshKeywords() {
  try {
    const r = await fetch(KW_URL, { cache: "no-store" });
    if (r.ok) {
      const j = await r.json();
      if (Array.isArray(j.keywords) && j.keywords.length) { KEYWORDS = trim(j.keywords); return; }
    }
  } catch (e) { /* block page server offline: fall through to cache */ }
  try {
    const s = await browser.storage.local.get("keywords");
    if (Array.isArray(s.keywords) && s.keywords.length) { KEYWORDS = s.keywords; return; }
  } catch (e) {}
  if (!KEYWORDS.length) KEYWORDS = await loadBundled();
}

setInterval(refreshKeywords, REFRESH_MS);
refreshKeywords();

browser.webRequest.onBeforeRequest.addListener(
  (details) => {
    if (details.type !== "main_frame" && details.type !== "sub_frame") return;
    let u;
    try { u = decodeURIComponent(details.url).toLowerCase(); }
    catch (e) { u = details.url.toLowerCase(); }
    for (const kw of KEYWORDS) {
      if (kw && u.includes(kw)) {
        console.log("[cerberus] blocked URL containing '" + kw + "'");
        return { redirectUrl: "http://127.0.0.1/" };
      }
    }
  },
  { urls: ["<all_urls>"] },
  ["blocking"]
);

console.log("[cerberus] keyword blocker active");
BJEOF
  chmod 644 "$EXT_SRC/manifest.json" "$EXT_SRC/background.js"
}

# ── build the .xpi (extension zip) with bundled keyword defaults ──
build_xpi() {
  python3 - "$BINDIR/config" "$EXT_SRC/keywords.json" << 'PY'
import sys, json
kws = []
in_sec = False
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith("SEARCH_BLOCK_KEYWORDS=("):
        in_sec = True
        continue
    if in_sec:
        if line == ")":
            break
        s = line.strip('"')
        if s and not s.startswith("#"):
            kws.append(s)
with open(sys.argv[2], "w") as f:
    json.dump({"keywords": kws}, f)
PY
  rm -f "$EXTENSION_XPI"
  python3 - "$EXT_SRC" "$EXTENSION_XPI" << 'PY'
import sys, os, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _dirs, files in os.walk(src):
        for name in sorted(files):
            p = os.path.join(root, name)
            arc = os.path.relpath(p, src)
            z.write(p, arc)
PY
  chmod 644 "$EXTENSION_XPI"
  log "built $EXTENSION_XPI"
}

# ── enterprise policy: force-installed, no uninstall in the UI ─────
write_policy() {
  python3 - "$FIREFOX_POLICY" "$EXTENSION_ID" "$EXTENSION_XPI" << 'PY'
import sys, json
path, eid, xpi = sys.argv[1], sys.argv[2], sys.argv[3]
policy = {
    "policies": {
        "ExtensionSettings": {
            eid: {
                "installation_mode": "force_installed",
                "install_url": "file://" + xpi,
                "updates_disabled": True,
            },
            "*": {
                "blocked_install_types": ["temporary"],
                "install_sources": ["https://addons.mozilla.org/*"],
            },
        }
    }
}
with open(path, "w") as f:
    json.dump(policy, f, indent=2)
PY
  chmod 644 "$FIREFOX_POLICY"
  log "wrote $FIREFOX_POLICY (force_installed, UI uninstall disabled)"
}

check() {
  local ok=1
  [[ -f "$FIREFOX_POLICY" ]] && grep -q force_installed "$FIREFOX_POLICY" || { echo "policy: MISSING"; ok=0; }
  [[ -f "$EXTENSION_XPI" ]] && python3 -c "import zipfile; zipfile.ZipFile('$EXTENSION_XPI')" 2>/dev/null || { echo "xpi: INVALID"; ok=0; }
  [[ -f "$SEARCH_KEYWORDS_JSON" ]] || { echo "keywords json: MISSING"; ok=0; }
  if [[ $ok -eq 1 ]]; then
    echo "browser lockdown: OK"
    echo "keywords: $(config_keywords)"
  fi
  return $ok
}

do_enforce() {
  chattr -i "$FIREFOX_POLICY" "$EXTENSION_XPI" "$SEARCH_KEYWORDS_JSON" \
         "$EXT_SRC/manifest.json" "$EXT_SRC/background.js" 2>/dev/null || true
  gen_keywords_json
  write_ext_sources
  build_xpi
  write_policy
  chattr +i "$FIREFOX_POLICY" "$EXTENSION_XPI" "$SEARCH_KEYWORDS_JSON" "$EXT_SRC/manifest.json" "$EXT_SRC/background.js" 2>/dev/null || true
  log "done. Fully restart Firefox (not just the window) to apply."
}

case "$MODE" in
  check) check ;;
  enforce|"") do_enforce ;;
  *) echo "usage: browser-lock.sh [enforce|check]"; exit 1 ;;
esac