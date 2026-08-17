#!/usr/bin/env python3
import sqlite3, sys, os, tempfile, subprocess, time, re, logging

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
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("PRAGMA cache_size=-16")
    db.execute("""
        CREATE TABLE IF NOT EXISTS blocked_domains (
            domain TEXT PRIMARY KEY,
            source TEXT NOT NULL DEFAULT 'blocklist'
        )
    """)
    db.execute("CREATE INDEX IF NOT EXISTS idx_domain ON blocked_domains(domain)")
    db.commit()
    return db

def load_blocklist_urls(config_path):
    urls = []
    in_blocklist = False
    try:
        with open(config_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("BLOCKLIST_URLS=("):
                    in_blocklist = True
                    continue
                if in_blocklist:
                    if line == ")":
                        break
                    m = re.match(r'"(.+?)"', line)
                    if m:
                        urls.append(m.group(1))
    except FileNotFoundError:
        log.error(f"config not found: {config_path}")
    return urls

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

def load_whitelist(config_path):
    domains = []
    in_whitelist = False
    try:
        with open(config_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("WHITELIST_DOMAINS=("):
                    in_whitelist = True
                    continue
                if in_whitelist:
                    if line == ")":
                        break
                    m = re.match(r'"(.+?)"', line)
                    if m:
                        domains.append(m.group(1))
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

def update_blocklist(db_path, config_path, custom_path):
    db = init_db(db_path)
    urls = load_blocklist_urls(config_path)
    whitelist = load_whitelist(config_path)
    custom_domains = load_custom_blocklist(custom_path)

    log.info(f"blocklist URLs: {len(urls)}")
    log.info(f"custom domains: {len(custom_domains)}")
    log.info(f"whitelist: {len(whitelist)}")

    all_domains = set()
    for url in urls:
        name = url.split("/")[-1]
        log.info(f"downloading {name}...")
        text = download_list(url)
        if text is None:
            log.warning(f"  failed: {name}")
            continue
        count = 0
        for line in text.splitlines():
            domain = parse_hosts_line(line)
            if domain:
                all_domains.add(domain)
                count += 1
        log.info(f"  parsed {count} domains from {name}")

    for domain in custom_domains:
        all_domains.add(domain.lower().strip())

    for domain in whitelist:
        d = domain.lower().strip()
        all_domains.discard(d)
        all_domains.discard(f"www.{d}")

    log.info(f"total unique domains: {len(all_domains)}")

    log.info("writing to database...")
    db.execute("DELETE FROM blocked_domains")
    db.close()

    db = sqlite3.connect(db_path)
    db.execute("PRAGMA synchronous=OFF")
    db.execute("PRAGMA journal_mode=OFF")

    count = 0
    batch = []
    for domain in sorted(all_domains):
        batch.append((domain, "blocklist"))
        count += 1
        if len(batch) >= 50000:
            db.executemany("INSERT INTO blocked_domains (domain, source) VALUES (?, ?)", batch)
            db.commit()
            batch = []
            log.info(f"  inserted {count}...")
    if batch:
        db.executemany("INSERT INTO blocked_domains (domain, source) VALUES (?, ?)", batch)
        db.commit()

    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA optimize")

    final = db.execute("SELECT count(*) FROM blocked_domains").fetchone()[0]
    log.info(f"done: {final} domains in database")
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
