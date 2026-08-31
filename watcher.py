#!/usr/bin/env python3
"""
Cerberus watcher-of-the-watcher.

Runs on a 30s timer (cerberus-watchdog-watcher.timer). It is the redundant
backstop that guarantees the instant watchdog (cerberus-watchdog2) and the
resolver stay alive, and that all guardian units stay armed. Combined with
the instant watchdog guarding the timers back, no single `systemctl stop`
can take Cerberus down for more than a few seconds.
"""
import subprocess
import sys
import logging

logging.basicConfig(format="[cerberus-watcher] %(message)s", level=logging.INFO)
log = logging.getLogger("cerberus-watcher")

GUARDIANS = [
    "cerberus-watchdog2.service",
    "cerberus-resolver.service",
    "cerberus-watchdog.timer",
    "cerberus-watchdog-watcher.timer",
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
