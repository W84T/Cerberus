#!/usr/bin/env python3
"""Cerberus Virtual Browser Blocker — search the web, verify, and block cloud/virtual browser services."""
import sys, os, re, html, time, json, socket, sqlite3, subprocess, argparse, urllib.request, urllib.parse, base64, logging

logging.basicConfig(format="%(message)s", level=logging.INFO, stream=sys.stdout)
log = logging.getLogger("vbb")

CONFIG = "/opt/cerberus/config"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

# Confirmed virtual/cloud browser service domains (curated, always included).
SEED_DOMAINS = [
    "browser.lol", "browserling.com", "corsproxy.io", "kasmweb.com", "kasm.cloud",
    "send.win", "oceanbrowser.co", "litebrowser.net", "alphabrowser.xyz",
    "virtualshield.com", "proxybrowser.xyz", "browsertoweb.com", "browsercam.com",
    "browserstack.com", "lambdatest.com", "saucelabs.com", "testingbot.com",
    "networkchuck.com", "virtualbrowser.cc",
]

BYPASS_QUERIES = [
    "virtual browser blocked website",
    "virtual browser no download",
    "cloud browser blocked sites",
    "cloud browser browse the web",
    "remote browser online free",
    "online browser visit blocked websites",
    "browser runs on cloud server online",
    "stream a browser in the cloud",
    "virtual browser bypass censorship",
    "browse blocked websites online browser",
    "open blocked sites virtual browser",
    "remote browser isolation online service",
    "Kasm cloud browser",
    "browserling virtual browser",
    "cloud web browser sandbox",
]

PUBLIC_SUFFIXES = {
    "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "edu.au",
    "co.nz", "org.nz", "net.nz", "com.br", "com.mx", "com.ar", "com.co", "com.ve",
    "com.pe", "com.ec", "com.uy", "com.cl", "com.tr", "com.cn", "co.jp", "co.in",
    "com.sg", "com.my", "com.hk", "com.tw", "com.ph", "com.pk", "com.eg", "co.za",
    "com.ng", "com.gh", "com.ke", "co.ke", "com.sa", "co.th", "com.vn", "co.id",
    "com.ua", "co.il", "co.kr", "com.pl", "com.ro", "com.gr",
}

DEFINITELY_NOT = {
    "google.com", "googleusercontent.com", "gstatic.com", "googleapis.com", "googlevideo.com",
    "bing.com", "microsoft.com", "msn.com", "live.com", "office.com", "windows.com",
    "duckduckgo.com", "ddg.gg", "mojeek.com", "startpage.com", "wikipedia.org",
    "yandex.com", "yandex.ru", "baidu.com", "qwant.com", "ecosia.org", "brave.com",
    "github.com", "github.io", "gitlab.com", "bitbucket.org",
    "cloudflare.com", "cloudflare-dns.com", "cloudflareclient.com",
    "akamai.com", "akamaiedge.net", "amazon.com", "amazonaws.com",
    "facebook.com", "meta.com", "youtube.com", "x.com", "twitter.com", "instagram.com",
    "reddit.com", "tiktok.com", "whatsapp.com", "wa.me", "telegram.org", "discord.com",
    "archive.org", "archive.ph", "mail.ru", "yahoo.com", "aol.com", "apple.com",
    "mozilla.org", "chromium.org", "opera.com", "openai.com", "anthropic.com",
    "oracle.com", "oraclecloud.com", "rackspacecloud.com", "myqnapcloud.com",
    "huaweicloud.com", "alibabacloud.com", "digitalocean.com", "heroku.com",
    "cloudflare.net", "cloudfare.com", "cloudns.be", "cloudns.nz",
    "booking.com", "tripadvisor.com", "tripadvisor.de", "tripadvisor.at",
    "hotels.com", "kayak.com", "expedia.com",
    "remote.com", "remote.co", "anydesk.com", "teamviewer.com", "remotepc.com",
    "indeed.com", "weworkremotely.com", "glassdoor.com", "linkedin.com",
    "softonic.com", "lifewire.com", "howtogeek.com", "tomsguide.com",
    "open.ac.uk", "cambridge.org", "merriam-webster.com", "britannica.com",
    "firefox.com", "steampowered.com", "twitch.tv", "justwatch.com",
    "tennis.nl", "online.nl", "ou.nl",
    "torrenting.com", "thepiratebay.org", "kickasstorrents.to",
    "expressvpn.com", "nordvpn.com", "surfshark.com", "protonvpn.com",
    "torproject.org", "tails.net",
}

EVIDENCE = [
    r"virtual\s+browser",
    r"cloud\s+browser",
    r"(remote|online)\s+browser",
    r"browser\s+in\s+the\s+cloud",
    r"browser\s+island",
    r"streamed?\s+browser",
    r"browser\s+(is\s+)?streamed",
    r"browser\s+runs?\s+(on|in)\s+(our\s+)?(server|cloud|virtual)",
    r"browse\w*\s+(on|in)\s+(our\s+)?(cloud|server)",
    r"(cloud|remote|virtual)[\w\s]{0,15}?browser",
    r"browser[\w\s]{0,15}?(cloud|virtual|remote|stream)",
    r"browser\s+sandbox",
    r"browser\s+without\s+(install|download)",
    r"(no\s+download|no\s+install\w*)[\w\s]{0,15}?browser",
    r"open\s+blocked\s+(site|website|web ?page|site)",
    r"visit\s+blocked\s+(site|website|web ?page)",
    r"browse\s+blocked",
    r"bypass\s+(censorship|filter)",
    r"access\s+blocked\s+(website|site|web ?page)",
    r"open\s+(any|blocked)\s+website[^\n.]{0,40}?browser",
    r"browser[\w\s]{0,20}?on\s+our\s+servers?",
]
EVIDENCE_RE = re.compile("|".join(EVIDENCE), re.I)

SYSTEMJARGON_URL = "https://raw.githubusercontent.com/SystemJargon/filters/main/restrict-bypass.txt"

def get_cfg():
    out = {"CUSTOM_BLOCK_FILE": "/opt/cerberus/custom-block.txt",
           "DB_PATH": "/opt/cerberus/cerberus.db", "ALWAYS_ALLOW": [], "UNIT_RESOLVER": ""}
    try:
        with open(CONFIG) as f:
            text = f.read()
        m = re.search(r'CUSTOM_BLOCK_FILE="([^"]+)"', text)
        if m: out["CUSTOM_BLOCK_FILE"] = m.group(1)
        m = re.search(r'DB_PATH="([^"]+)"', text)
        if m: out["DB_PATH"] = m.group(1)
        m = re.search(r'UNIT_RESOLVER=(\S+)', text)
        if m: out["UNIT_RESOLVER"] = m.group(1).strip('"')
        allow = re.search(r"ALWAYS_ALLOW=\((.*?)\)", text, re.S)
        if allow:
            out["ALWAYS_ALLOW"] = re.findall(r'"([^"]+)"', allow.group(1))
    except FileNotFoundError:
        pass
    return out

def fetch(uri, timeout=15):
    req = urllib.request.Request(uri, headers={
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        if r.status != 200:
            raise RuntimeError("HTTP %s" % r.status)
        return r.read().decode("utf-8", "ignore")

def _decode_bing(url):
    m = re.search(r"[?&]u=(a1[\w\-]+)", url)
    if not m:
        return None
    b64 = m.group(1)[2:]
    b64 += "=" * (-len(b64) % 4)
    try:
        return base64.urlsafe_b64decode(b64).decode("utf-8", "ignore")
    except Exception:
        return None

def collect_bing(q):
    raw = html.unescape(fetch("https://www.bing.com/search?q=" + urllib.parse.quote(q) + "&count=30"))
    urls = []
    for m in re.finditer(r'href="(https?://www\.bing\.com/ck/a[^"]*)"', raw):
        d = _decode_bing(m.group(1))
        if d and d.startswith("http"):
            nl = urllib.parse.urlsplit(d).netloc
            if nl not in ("www.bing.com", "bing.com", "go.microsoft.com"):
                urls.append(d)
    return urls

def collect_ddg(q):
    raw = fetch("https://lite.duckduckgo.com/lite/?q=" + urllib.parse.quote(q))
    return [m.group(1) for m in re.finditer(r'href="(http[^"]+)"', raw)]

def search_all(query):
    found = []
    for name, fn in (("bing", collect_bing), ("ddg", collect_ddg)):
        try:
            urls = fn(query)
            log.info("  [%s] %d results for: %s", name, len(set(urls)), query)
            found.extend(urls)
        except Exception as e:
            log.info("  [%s] failed: %s", name, e)
    return found

def block_domain(hostname):
    labels = hostname.lower().rstrip(".").split(".")
    while labels and labels[0] in ("www", "m", "mobile", "web", "app"):
        labels.pop(0)
    if len(labels) <= 2:
        return ".".join(labels) if labels else None
    if ".".join(labels[-2:]) in PUBLIC_SUFFIXES:
        return ".".join(labels[-3:])
    return ".".join(labels[-2:])

def alive_status(domain):
    try:
        rai = socket.getaddrinfo(domain, 443, socket.AF_UNSPEC, socket.SOCK_STREAM)
    except socket.gaierror:
        return None
    ips = {ai[4][0] for ai in rai}
    if ips.issubset({"127.0.0.1", "::1"}):
        return "blocked-already"
    return "alive"

def page_text(domain, limit=60000):
    for scheme in ("https", "http"):
        try:
            data = fetch(scheme + "://" + domain + "/", timeout=12)
            data = re.sub(r"<script[\s\S]*?</script>|<style[\s\S]*?</style>", " ", data)
            text = re.sub(r"<[^>]+>", " ", data)
            return html.unescape(text)[:limit]
        except Exception:
            continue
    return None

def is_virtual_browser(domain):
    text = page_text(domain)
    if text is None:
        return None
    return bool(EVIDENCE_RE.search(text))

def load_blocked(db_path):
    try:
        db = sqlite3.connect("file:" + db_path + "?mode=ro", uri=True)
        rows = db.execute("SELECT domain FROM blocked_domains").fetchall()
        db.close()
        return {r[0].lower().rstrip(".") for r in rows}
    except Exception:
        return set()

def systemjargon_virtual_browsers():
    try:
        raw = fetch(SYSTEMJARGON_URL, timeout=30)
        out = []
        for m in re.finditer(r"^\|\|([a-z0-9\-\.]+)\^", raw, re.M):
            d = m.group(1).lower()
            if len(d.split(".")) > 2:
                d = block_domain(d)
            if not d:
                continue
            name = d.split(".")[0]
            if re.search(r"browser|browse|browsec", name):
                out.append(d)
        return sorted(set(out))
    except Exception as e:
        log.info("  [systemjargon] failed: %s", e)
        return []

def block(cfg, domains):
    f = cfg["CUSTOM_BLOCK_FILE"]
    dbp = cfg["DB_PATH"]
    subprocess.run(["chattr", "-i", f], capture_output=True)
    existing = set()
    try:
        with open(f) as fh:
            for line in fh:
                d = line.strip().lower().rstrip(".")
                if d:
                    existing.add(d)
    except FileNotFoundError:
        pass
    new = [d for d in sorted(set(domains)) if d not in existing]
    with open(f, "a") as fh:
        fh.write("\n".join(new) + "\n")
    subprocess.run(["chattr", "+i", f], capture_output=True)
    db = sqlite3.connect(dbp)
    for d in set(domains):
        db.execute("INSERT OR IGNORE INTO blocked_domains (domain, source, category) VALUES (?,?,?)",
                   (d, "custom", "custom"))
    db.commit()
    db.close()
    unit = cfg["UNIT_RESOLVER"]
    ok = False
    if unit:
        try:
            subprocess.run(["systemctl", "restart", unit], check=True, capture_output=True)
            ok = True
        except Exception:
            pass
    if not ok:
        subprocess.run(["pkill", "-f", "/opt/cerberus/resolver.py"], capture_output=True)
        subprocess.Popen(["/usr/bin/python3", "/opt/cerberus/resolver.py"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return len(new)

def main():
    ap = argparse.ArgumentParser(description="Find & block virtual/cloud browser services")
    ap.add_argument("--queries", nargs="*", default=None, help="Extra search queries")
    ap.add_argument("--max", type=int, default=0, help="Max live candidates to process (0=all)")
    ap.add_argument("--dry-run", action="store_true", help="Only report, do not block")
    ap.add_argument("--no-verify", action="store_true", help="Skip homepage evidence check")
    ap.add_argument("--no-seeds", action="store_true", help="Skip curated seed domains")
    ap.add_argument("--no-bypass-list", action="store_true", help="Skip SystemJargon bypass list")
    ap.add_argument("--json", type=str, help="Write report JSON to this file")
    args = ap.parse_args()

    if os.geteuid() != 0 and not args.dry_run:
        os.execvp("sudo", ["sudo", "-n", "python3", os.path.abspath(__file__)] + sys.argv[1:])

    cfg = get_cfg()
    queries = list(BYPASS_QUERIES) + (args.queries or [])
    blocked_set = load_blocked(cfg["DB_PATH"])
    deny = DEFINITELY_NOT | {d.lower() for d in cfg["ALWAYS_ALLOW"]}

    candidates = {}
    if not args.no_seeds:
        for d in SEED_DOMAINS:
            candidates[d] = {"url": "", "src": "seed", "trusted": True}
    for q in queries:
        for u in search_all(q):
            try:
                host = urllib.parse.urlsplit(u).netloc
            except Exception:
                continue
            if not host:
                continue
            host = host.lower().split("@")[-1].split(":")[0]
            d = block_domain(host)
            if d and d not in deny and d not in candidates:
                candidates[d] = {"url": u, "src": q, "trusted": False}
    if not args.no_bypass_list:
        for d in systemjargon_virtual_browsers():
            if d not in deny and d not in candidates:
                candidates[d] = {"url": SYSTEMJARGON_URL, "src": "systemjargon", "trusted": True}

    log.info("=== %d unique candidate domains ===", len(candidates))
    report = []
    for d, info in candidates.items():
        st = alive_status(d)
        if st is None:
            continue
        evidence = None
        ok = st == "alive"
        if ok and not info["trusted"]:
            if not args.no_verify:
                evidence = is_virtual_browser(d)
            else:
                evidence = True
            if not evidence:
                ok = False
        report.append({"domain": d, "status": st, "query": info["src"],
                       "evidence": evidence, "block": ok})
        log.info("  %-26s %-14s %s", d, st,
                 "EVIDENCE-OK" if evidence else ("trusted" if info["trusted"] else ("no-evidence|blocked" if st=="blocked-already" else "REJECT")))
        if args.max and sum(1 for r in report if r["block"]) >= args.max:
            break

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(report, fh, indent=2)

    to_block = [r["domain"] for r in report if r["block"]]
    log.info("=== %d domains to block ===", len(to_block))
    for d in to_block:
        log.info("  + %s", d)
    if args.dry_run:
        log.info("dry-run: nothing changed on disk")
        return
    if not to_block:
        log.info("nothing new to block")
        return
    n = block(cfg, to_block)
    log.info("blocked %d new domains; resolver restarted", n)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)