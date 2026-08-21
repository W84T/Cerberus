#!/usr/bin/env python3
import sqlite3, sys, os, subprocess, time, re, logging

logging.basicConfig(
    format="[cerberus-updater] %(message)s",
    level=logging.INFO,
    stream=sys.stdout,
)
log = logging.getLogger("cerberus-updater")

DEFAULT_DB = "/opt/cerberus/cerberus.db"
CURL_TIMEOUT = 60

def init_db(db_path):
    db = sqlite3.connect(db_path)
    db.execute("PRAGMA journal_mode=DELETE")
    db.execute("PRAGMA synchronous=OFF")
    db.execute("""
        CREATE TABLE IF NOT EXISTS blocked_domains (
            domain TEXT PRIMARY KEY,
            source TEXT NOT NULL DEFAULT 'blocklist',
            category TEXT NOT NULL DEFAULT 'mandatory'
        )
    """)
    db.execute("CREATE INDEX IF NOT EXISTS idx_domain ON blocked_domains(domain)")
    db.commit()
    return db

def load_list_section(config_path, section_name):
    urls = []
    in_section = False
    try:
        with open(config_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith(f"{section_name}=("):
                    in_section = True
                    continue
                if in_section:
                    if line == ")":
                        break
                    m = re.match(r'"(.+?)"', line)
                    if m:
                        urls.append(m.group(1))
    except FileNotFoundError:
        log.error(f"config not found: {config_path}")
    return urls

def load_always_allow(config_path):
    entries = []
    in_section = False
    try:
        with open(config_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("ALWAYS_ALLOW=("):
                    in_section = True
                    continue
                if in_section:
                    if line.startswith(")"):
                        break
                    entry = line.strip('"').strip()
                    if entry and not entry.startswith("#"):
                        entries.append(entry.lower())
    except FileNotFoundError:
        pass
    return set(entries)


def load_enabled_optionals(config_path):
    names = []
    in_section = False
    try:
        with open(config_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("ENABLED_OPTIONALS=("):
                    in_section = True
                    continue
                if in_section:
                    if line == ")":
                        break
                    m = re.match(r'"(.+?)"', line)
                    if m:
                        names.append(m.group(1))
    except FileNotFoundError:
        pass
    return names

def load_custom_blocklist(path):
    domains = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                domains.append(line)
    except FileNotFoundError:
        pass
    return domains

def parse_hosts_line(line):
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    parts = line.split()
    if len(parts) >= 2 and parts[0] in ("0.0.0.0", "127.0.0.1"):
        domain = parts[1].lower()
        if domain in ("0.0.0.0", "localhost", "local", "ip6-localhost", "ip6-local", "ip6-loopback", "broadcasthost"):
            return None
        return domain
    return None

def download_list(url):
    try:
        result = subprocess.run(
            ["curl", "-sL", "--max-time", str(CURL_TIMEOUT), url],
            capture_output=True, timeout=CURL_TIMEOUT + 10,
        )
        if result.returncode != 0:
            return None
        text = result.stdout.decode("utf-8", errors="replace")
        if "<!DOCTYPE" in text[:200] or "<html" in text[:200]:
            log.warning(f"  404/HTML response for {url.split('/')[-1]}, skipping")
            return None
        return text
    except Exception as e:
        log.warning(f"  download failed: {e}")
        return None

def url_to_name(url):
    return url.split("/")[-1].replace(".txt", "")

def update_blocklist(db_path, config_path, custom_path):
    db = init_db(db_path)

    mandatory_urls = load_list_section(config_path, "MANDATORY_BLOCKLIST_URLS")
    optional_urls = load_list_section(config_path, "OPTIONAL_BLOCKLIST_URLS")
    enabled_optionals = load_enabled_optionals(config_path)
    always_allow = load_always_allow(config_path)
    custom_domains = load_custom_blocklist(custom_path)

    log.info(f"mandatory blocklists: {len(mandatory_urls)}")
    log.info(f"optional blocklists: {len(optional_urls)} (enabled: {len(enabled_optionals)})")
    log.info(f"custom domains: {len(custom_domains)}")
    log.info(f"always-allow entries: {len(always_allow)}")

    all_mandatory = set()
    all_optional = set()

    for url in mandatory_urls:
        name = url_to_name(url)
        log.info(f"[mandatory] downloading {name}...")
        text = download_list(url)
        if text is None:
            log.warning(f"  failed: {name}")
            continue
        count = 0
        for line in text.splitlines():
            domain = parse_hosts_line(line)
            if domain:
                all_mandatory.add(domain)
                count += 1
        log.info(f"  parsed {count} domains from {name}")

    for url in optional_urls:
        name = url_to_name(url)
        category = name
        is_enabled = category in enabled_optionals
        if not is_enabled:
            log.info(f"[optional:disabled] skipping {name}")
            continue
        status = "enabled"
        log.info(f"[optional:{status}] downloading {name}...")
        text = download_list(url)
        if text is None:
            log.warning(f"  failed: {name}")
            continue
        count = 0
        for line in text.splitlines():
            domain = parse_hosts_line(line)
            if domain:
                if is_enabled:
                    all_optional.add(domain)
                count += 1
        log.info(f"  parsed {count} domains from {name}")

    all_domains = all_mandatory | all_optional
    for domain in custom_domains:
        all_domains.add(domain.lower().strip())

    def is_allowed(domain):
        for allowed in always_allow:
            if domain == allowed or domain.endswith("." + allowed):
                return True
        return False

    exempted = {d for d in all_domains if is_allowed(d)}
    all_domains -= exempted

    log.info(f"total unique domains: {len(all_domains)} (mandatory: {len(all_mandatory)}, optional: {len(all_optional)}, custom: {len(custom_domains)}, exempted: {len(exempted)})")

    log.info("writing to database...")
    db.execute("DELETE FROM blocked_domains")
    db.close()

    db = sqlite3.connect(db_path)
    db.execute("PRAGMA synchronous=OFF")
    db.execute("PRAGMA journal_mode=OFF")
    db.execute("DELETE FROM blocked_domains")
    db.commit()

    count = 0
    batch = []
    for domain in sorted(all_domains):
        if domain in all_mandatory:
            category = "mandatory"
        elif domain in custom_domains:
            category = "custom"
        else:
            category = "optional"
        batch.append((domain, "blocklist", category))
        count += 1
        if len(batch) >= 50000:
            db.executemany("INSERT OR REPLACE INTO blocked_domains (domain, source, category) VALUES (?, ?, ?)", batch)
            db.commit()
            batch = []
            log.info(f"  inserted {count}...")
    if batch:
        db.executemany("INSERT OR REPLACE INTO blocked_domains (domain, source, category) VALUES (?, ?, ?)", batch)
        db.commit()

    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("PRAGMA journal_mode=DELETE")
    db.execute("PRAGMA optimize")

    final = db.execute("SELECT count(*) FROM blocked_domains").fetchone()[0]
    mandatory_count = db.execute("SELECT count(*) FROM blocked_domains WHERE category='mandatory'").fetchone()[0]
    optional_count = db.execute("SELECT count(*) FROM blocked_domains WHERE category='optional'").fetchone()[0]
    custom_count = db.execute("SELECT count(*) FROM blocked_domains WHERE category='custom'").fetchone()[0]
    log.info(f"done: {final} domains (mandatory: {mandatory_count}, optional: {optional_count}, custom: {custom_count})")
    db.close()

def main():
    db_path = os.environ.get("CERBERUS_DB", DEFAULT_DB)
    config_path = os.environ.get("CERBERUS_CONFIG", "/opt/cerberus/config")
    custom_path = os.environ.get("CERBERUS_CUSTOM", "/opt/cerberus/custom-block.txt")

    if "--init-only" in sys.argv:
        db = init_db(db_path)
        log.info(f"initialized empty database at {db_path}")
        db.close()
        return

    update_blocklist(db_path, config_path, custom_path)

if __name__ == "__main__":
    main()
