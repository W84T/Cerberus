#!/usr/bin/env python3
"""Discovery of adult manga/manhwa domains via certificate-transparency logs.

Queries crt.sh for each MATURE_KEYWORDS pattern and appends matching domains to
ADULT_FOUND_FILE. On the next refresh blocklist_updater.py ingests that file
into the block database (category 'adult'), so adult-title sites that haven't
made it into curated lists yet still get blocked.

False positives can be removed from ADULT_FOUND_FILE before the next refresh.
Requires network. Non-fatal errors are logged and skipped.
"""
import re
import sys
import json
import time
import logging
import subprocess

logging.basicConfig(
    format="[cerberus-finder] %(message)s",
    level=logging.INFO,
    stream=sys.stdout,
)
log = logging.getLogger("cerberus-finder")

CONFIG = "/opt/cerberus/config"
DEFAULT_OUT = "/opt/cerberus/adult-found.txt"
CRT_SH_TIMEOUT = 40
FETCH_DELAY = 2
MAX_NEW_PER_RUN = 4000

DOMAIN_RE = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"
)


def load_config(config_path):
    keywords, out = [], DEFAULT_OUT
    try:
        with open(config_path) as f:
            in_kw = False
            for line in f:
                line = line.strip()
                if line.startswith("MATURE_KEYWORDS=("):
                    in_kw = True
                    continue
                if in_kw:
                    if line.startswith(")"):
                        in_kw = False
                        continue
                    m = re.match(r'"(.+?)"', line)
                    if m:
                        keywords.append(m.group(1))
                if line.startswith("ADULT_FOUND_FILE="):
                    out = line.split("=", 1)[1].strip().strip('"')
    except FileNotFoundError:
        log.warning(f"config not found: {config_path}")
    return keywords, out


def load_existing(out_path):
    seen = set()
    try:
        with open(out_path) as f:
            for line in f:
                name = line.strip().lower().rstrip(".")
                if name and DOMAIN_RE.match(name):
                    seen.add(name)
    except FileNotFoundError:
        pass
    return seen


def fetch_crt(keyword):
    q = f"https://crt.sh/?q={keyword}&output=json"
    try:
        result = subprocess.run(
            ["curl", "-s", "-A", "cerberus-adult-finder/0.1", "--max-time", str(CRT_SH_TIMEOUT), q],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=CRT_SH_TIMEOUT + 10,
        )
        if result.returncode != 0:
            return None
        text = result.stdout.decode("utf-8", errors="replace")
        if text[:1] != "[":
            log.warning(f"  non-JSON response for keyword '{keyword}'")
            return None
        return json.loads(text)
    except Exception as e:
        log.warning(f"  crt.sh query failed for keyword '{keyword}': {e}")
        return None


def names_from_cert(entry):
    # A cert can cover several names, separated by newlines and wildcarded.
    raw = entry.get("name_value") or entry.get("common_name") or ""
    for name in raw.split("\n"):
        name = name.strip()
        if name.startswith("*."):
            name = name[2:]
        yield name.lower().rstrip(".")


def main():
    keywords, out_path = load_config(CONFIG)
    if not keywords:
        log.info("no MATURE_KEYWORDS configured; nothing to do")
        return
    existing = load_existing(out_path)
    found = set()
    failed = 0

    log.info(f"scanning crt.sh for {len(keywords)} keyword(s) -> {out_path}")
    for idx, kw in enumerate(keywords, start=1):
        log.info(f"[{idx}/{len(keywords)}] '{kw}' ...")
        data = fetch_crt(kw)
        if data is None:
            failed += 1
            time.sleep(FETCH_DELAY)
            continue
        for entry in data:
            for name in names_from_cert(entry):
                if DOMAIN_RE.match(name) and len(name.split(".")) >= 2 and name not in existing:
                    found.add(name)
        log.info(f"  {keyword_total(data)} cert(s) for '{kw}'")
        time.sleep(FETCH_DELAY)
        if len(found) > MAX_NEW_PER_RUN:
            log.info(f"hit cap of {MAX_NEW_PER_RUN}, stopping early")
            break

    if not found:
        log.info(f"no new domains found (failed queries: {failed})")
        return

    found = set(found)
    combined = sorted(existing | found)
    try:
        with open(out_path, "w") as f:
            for name in combined:
                f.write(name + "\n")
        log.info(f"wrote {len(combined)} domains to {out_path} ({len(found)} new)")
    except Exception as e:
        log.warning(f"could not write {out_path}: {e}")


def keyword_total(data):
    if isinstance(data, dict):
        return 0 if data.get("error") else 0
    if isinstance(data, list):
        return len(data)
    return 0


if __name__ == "__main__":
    main()