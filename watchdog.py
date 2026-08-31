#!/usr/bin/env python3
"""
Cerberus instant watchdog (guardian of the entire chain).

Continuously verifies and enforces Cerberus policing:
  - iptables CERBERUS filter chain (DoH blocking) + OUTPUT jump
  - iptables CERBERUS_NAT REDIRECT chain + OUTPUT jump
  - cerberus-resolver.service (DNS) health via real UDP probe
  - re-enables/restarts its own guardian timers if someone stops them

Any disablement (rules flushed, resolver stopped, guardian stopped) is
re-applied within `INTERVAL` seconds. This daemon is itself guarded by a
60s mutual watcher, and it guards that watcher back, so stopping any
single unit gets undone by the others.
"""
import sys
import time
import subprocess
import logging

logging.basicConfig(
    format="[cerberus-watchdog] %(message)s",
    level=logging.INFO,
    stream=sys.stdout,
)
log = logging.getLogger("cerberus-watchdog")

CORE = "/opt/cerberus/core.sh"
INTERVAL = 2

# Guardian units this daemon keeps alive (and which keep THIS alive)
GUARDIANS = [
    "cerberus-watchdog.timer",
    "cerberus-watchdog-watcher.timer",
]


def load_config():
    d = {"RESOLVER_PORT": "5353", "DB_PATH": "/opt/cerberus/cerberus.db"}
    try:
        with open("/opt/cerberus/config") as f:
            for line in f:
                line = line.strip()
                if line.startswith("RESOLVER_PORT="):
                    d["RESOLVER_PORT"] = line.split("=", 1)[1].strip('"')
                elif line.startswith("DB_PATH="):
                    d["DB_PATH"] = line.split("=", 1)[1].strip('"')
    except FileNotFoundError:
        pass
    return d


def unit_is_active(name):
    r = subprocess.run(
        ["systemctl", "is-active", "--quiet", name], capture_output=True
    )
    return r.returncode == 0


def unit_is_enabled(name):
    r = subprocess.run(["systemctl", "is-enabled", name], capture_output=True)
    return r.returncode == 0


def ensure_unit(name, activate=True):
    """Ensure a unit exists (is-enabled) and is running/armed."""
    try:
        if not unit_is_enabled(name):
            subprocess.run(["systemctl", "enable", name], capture_output=True)
            log.info("re-enabled %s", name)
        if activate and not unit_is_active(name):
            subprocess.run(["systemctl", "start", name], capture_output=True)
            log.info("restarted %s", name)
            return True
    except Exception as e:
        log.warning("ensure_unit(%s) error: %s", name, e)
    return False


def ensure_guardians():
    """Reality-check that the guardian/backstop units are armed."""
    changed = False
    for g in GUARDIANS:
        if ensure_unit(g):
            changed = True
    return changed


def nat_redirect_active():
    r = subprocess.run(
        ["iptables", "-t", "nat", "-C", "OUTPUT", "-j", "CERBERUS_NAT"],
        capture_output=True,
    )
    if r.returncode != 0:
        return False
    r2 = subprocess.run(
        ["iptables", "-t", "nat", "-L", "CERBERUS_NAT", "-n"],
        capture_output=True, text=True,
    )
    return "REDIRECT" in r2.stdout


def filter_active():
    r = subprocess.run(
        ["iptables", "-C", "OUTPUT", "-j", "CERBERUS"],
        capture_output=True,
    )
    if r.returncode != 0:
        return False
    r2 = subprocess.run(
        ["iptables", "-L", "CERBERUS", "-n"],
        capture_output=True, text=True,
    )
    return "dpt:853" in r2.stdout


def resolver_active():
    r = subprocess.run(
        ["systemctl", "is-active", "--quiet", "cerberus-resolver.service"],
        capture_output=True,
    )
    return r.returncode == 0


def dns_reachable(port):
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(1.2)
        labels = b"\x03www\x06google\x03com\x00"
        q = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + labels + b"\x00\x01\x00\x01"
        s.sendto(q, ("127.0.0.1", port))
        datum, _ = s.recvfrom(512)
        s.close()
        return len(datum) >= 12
    except Exception:
        return False


def apply():
    subprocess.run([CORE, "check"], capture_output=True)


def main():
    cfg = load_config()
    port = int(cfg.get("RESOLVER_PORT", 5353))
    log.info("guardian watchdog started (interval=%ss, port=%s)", INTERVAL, port)

    while True:
        try:
            # 1. Keep the guardian timers armed (so the chain survives)
            guardians_repaired = ensure_guardians()

            # 2. Verify+enforce iptables and resolver
            nat = nat_redirect_active()
            filt = filter_active()
            resv = resolver_active()
            dns = dns_reachable(port)

            if not (nat and filt):
                log.warning("iptables incomplete (nat=%s, filter=%s) - re-applying", nat, filt)
                apply()
            elif not resv or not dns:
                log.warning("resolver unhealthy (active=%s, dns=%s) - re-applying", resv, dns)
                apply()
        except Exception as e:
            log.warning("watchdog error: %s", e)

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
