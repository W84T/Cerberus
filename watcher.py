#!/usr/bin/env python3
"""
Cerberus watcher-of-the-watcher (redundant backstop).

Runs on a timer (cerberus-watchdog-watcher.timer). It is the redundant
backstop that guarantees the instant watchdog and the resolver stay alive,
and that all guardian units stay armed. Unit names are loaded from
/opt/cerberus/config (randomized per install).
"""
import subprocess
import sys
import logging

logging.basicConfig(format="[cerberus-watcher] %(message)s", level=logging.INFO)
log = logging.getLogger("cerberus-watcher")

CONFIG = "/opt/cerberus/config"

DEFAULTS = {
    "UNIT_WDI": "cerberus-watchdog2.service",
    "UNIT_RESOLVER": "cerberus-resolver.service",
    "UNIT_WD_TIMER": "cerberus-watchdog.timer",
    "UNIT_WDW_TIMER": "cerberus-watchdog-watcher.timer",
    "UNIT_CORE": "cerberus.service",
}


def load_config():
    d = dict(DEFAULTS)
    try:
        with open(CONFIG) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                k, v = k.strip(), v.strip().strip('"')
                if k in d:
                    d[k] = v
    except FileNotFoundError:
        pass
    return d


cfg = load_config()
GUARDIANS = [
    cfg["UNIT_WDI"],
    cfg["UNIT_RESOLVER"],
    cfg["UNIT_WD_TIMER"],
    cfg["UNIT_WDW_TIMER"],
]


def is_active(name):
    return subprocess.run(["systemctl", "is-active", "--quiet", name],
                          capture_output=True).returncode == 0


def is_enabled(name):
    return subprocess.run(["systemctl", "is-enabled", name],
                          capture_output=True).returncode == 0


def ensure(name, must_be_running=True):
    try:
        if not is_enabled(name):
            subprocess.run(["systemctl", "enable", name], capture_output=True)
            log.info("re-enabled %s", name)
        if must_be_running and not is_active(name):
            subprocess.run(["systemctl", "start", name], capture_output=True)
            log.info("restarted %s", name)
    except Exception as e:
        log.warning("ensure(%s) error: %s", name, e)


def main():
    for g in GUARDIANS:
        ensure(g)
    log.info("guardian check complete")


if __name__ == "__main__":
    main()