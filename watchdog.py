#!/usr/bin/env python3
"""
Cerberus instant watchdog.
Watches iptables state and resolver health continuously.
When disablement is detected (rules flushed, resolver stopped), it immediately
re-applies Cerberus policing. Event-driven reaction in <interval seconds.
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


def load_config():
    d = {"RESOLVER_PORT": "5353"}
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
    log.info("instant watchdog started (interval=%ss, port=%s)", INTERVAL, port)

    while True:
        try:
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
