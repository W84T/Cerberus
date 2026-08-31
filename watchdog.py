#!/usr/bin/env python3
"""
Cerberus instant watchdog (guardian of the entire chain).

Continuously verifies and enforces Cerberus policing:
  - iptables filtering chains + OUTPUT jumps
  - iptables NAT redirect + OUTPUT jump
  - resolver (DNS) health via real UDP probe
  - re-enables/restarts its own guardian units if someone stops them

Unit names are loaded from /opt/cerberus/config (randomized per install),
so this works regardless of the generated names on any given machine.
"""
import sys
import time
import os
import subprocess
import logging

logging.basicConfig(
    format="[cerberus-watchdog] %(message)s",
    level=logging.INFO,
    stream=sys.stdout,
)
log = logging.getLogger("cerberus-watchdog")

CORE = "/opt/cerberus/core.sh"
CONFIG = "/opt/cerberus/config"
INTERVAL = 2


def load_config():
    d = {
        "RESOLVER_PORT": "5353",
        "UNIT_RESOLVER": "cerberus-resolver.service",
        "UNIT_WD_TIMER": "cerberus-watchdog.timer",
        "UNIT_WDW_TIMER": "cerberus-watchdog-watcher.timer",
        "UNIT_WDI": "cerberus-watchdog2.service",
        "UNIT_WDW": "cerberus-watchdog-watcher.service",
        "PENALTY_SIGNAL_FILE": "/var/lib/cerberus/penalty_signal",
        "PENALTY_STATE_FILE": "/var/lib/cerberus/penalty_state",
    }
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
RESOLVER_PORT = int(cfg.get("RESOLVER_PORT", "5353"))
UNIT_RESOLVER = cfg.get("UNIT_RESOLVER")
UNIT_WD_TIMER = cfg.get("UNIT_WD_TIMER")
UNIT_WDW_TIMER = cfg.get("UNIT_WDW_TIMER")
UNIT_WDI = cfg.get("UNIT_WDI")
UNIT_WDW = cfg.get("UNIT_WDW")
PENALTY_SIGNAL_FILE = cfg.get("PENALTY_SIGNAL_FILE", "/var/lib/cerberus/penalty_signal")
PENALTY_STATE_FILE = cfg.get("PENALTY_STATE_FILE", "/var/lib/cerberus/penalty_state")

# Guardian units this daemon keeps alive (and which keep THIS alive)
GUARDIANS = [UNIT_WD_TIMER, UNIT_WDW_TIMER]


def unit_is_active(name):
    r = subprocess.run(
        ["systemctl", "is-active", "--quiet", name], capture_output=True
    )
    return r.returncode == 0


def unit_is_enabled(name):
    r = subprocess.run(["systemctl", "is-enabled", name], capture_output=True)
    return r.returncode == 0


def ensure_unit(name, activate=True):
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
        ["systemctl", "is-active", "--quiet", UNIT_RESOLVER],
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


def penalty_signal_pending():
    return os.path.exists(PENALTY_SIGNAL_FILE)


def handle_penalty():
    try:
        if penalty_signal_pending():
            log.warning("blocked query detected - applying internet penalty")
            subprocess.run([CORE, "penalty_hit"], capture_output=True)
        # Reconcile expiry regardless each cycle
        subprocess.run([CORE, "penalty_check"], capture_output=True)
    except Exception as e:
        log.warning("penalty error: %s", e)


def main():
    log.info("guardian watchdog started (interval=%ss, port=%s)", INTERVAL, RESOLVER_PORT)
    log.info("units: resolver=%s wd_timer=%s wdw_timer=%s wdi=%s", UNIT_RESOLVER, UNIT_WD_TIMER, UNIT_WDW_TIMER, UNIT_WDI)

    while True:
        try:
            handle_penalty()

            guardians_repaired = ensure_guardians()

            nat = nat_redirect_active()
            filt = filter_active()
            resv = resolver_active()
            dns = dns_reachable(RESOLVER_PORT)

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