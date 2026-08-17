# Cerberus

A self-hardening content filter for Arch Linux that blocks adult content and locks itself down so even you can't easily undo it.

## Features

- **4.7M+ blocked domains** — downloaded from 16 blocklists, stored in SQLite
- **VPN-proof** — iptables NAT REDIRECT forces all DNS (port 53) through a local resolver, regardless of VPN or network config
- **Mandatory categories** — porn, gambling, drugs, malware, phishing, ransomware, abuse, fraud, scam — always blocked, no override
- **Optional categories** — facebook, twitter, youtube, tiktok, whatsapp, tracking, redirect — configurable in `ENABLED_OPTIONALS`
- **Custom block list** — add your own domains alongside the main list
- **DNS lockdown** — blocks DoT (port 853), and DoH/DoQ (UDP 443) to Cloudflare, Google, Quad9, OpenDNS, NextDNS, AdGuard
- **Self-healing** — hidden backup copies (4 locations) restore the core script if corrupted or deleted
- **Block page server** — serves a "Site Blocked" page on ports 80 (HTTP) and 443 (HTTPS) with a self-signed cert
- **Watchdog** — systemd timer verifies blocking every 5 minutes and re-applies if missing
- **Firefox DoH disabled** — automatically sets `network.trr.mode = 5` in all Firefox profiles
- **Faillock** — 3 wrong sudo attempts = 10 minute lockout
- **Low memory** — ~48 MB RAM for 4.7M domains (vs 2.4 GB with old hosts-file approach)
- **No-password sudo** — `cerberus` CLI runs via passwordless sudo for the configured user only

## Installation

```bash
sudo ./setup.sh
```

This installs everything under `/opt/cerberus/`, creates the `cerberus-resolve` system user, sets up systemd services, and applies the blocklist immediately.

Requires: `curl`, `openssl`, `python-dnslib` (installed automatically).

## Usage

```
cerberus status                  Show blocking status
cerberus lock                    Apply and lock immediately
cerberus block add <domain>      Add domain to custom block list
cerberus block rm <domain>       Remove domain from custom block list
cerberus block list              List custom blocked domains
cerberus update                  Self-update from git and reapply rules
cerberus refresh                 Force refresh blocklist from internet
```

## Categories

**Mandatory** (always blocked, no override):
- Porn, Gambling, Drugs, Malware, Phishing, Ransomware, Abuse, Fraud, Scam

**Optional** (toggle in `ENABLED_OPTIONALS` in config):
- Facebook, Twitter, YouTube, TikTok, WhatsApp, Redirect, Tracking

To disable an optional category, remove it from `ENABLED_OPTIONALS` in `/opt/cerberus/config` and run `cerberus refresh`.

## Architecture

| Component | Location | Role |
|-----------|----------|------|
| `resolver.py` | `/opt/cerberus/resolver.py` | DNS forwarder on 127.0.0.1:5353, checks SQLite DB |
| `blocklist_updater.py` | `/opt/cerberus/blocklist_updater.py` | Downloads blocklists into SQLite database |
| `core.sh` | `/opt/cerberus/core.sh` | Applies iptables rules, updates DB, self-heals |
| `cli.sh` | `/opt/cerberus/cli.sh` | User-facing CLI (`cerberus` command) |
| `blockpage.py` | `/opt/cerberus/blockpage.py` | Block page HTTP/HTTPS server |
| `config` | `/opt/cerberus/config` | Mandatory/optional blocklists, backup locations |
| `custom-block.txt` | `/opt/cerberus/custom-block.txt` | User-defined domains to block |
| `cerberus.db` | `/opt/cerberus/cerberus.db` | SQLite database with blocked domains |
| `cerberus-resolve.service` | systemd | DNS resolver daemon |
| `cerberus.service` | systemd | Applies blocking on boot |
| `cerberus-watchdog.timer` | systemd | Runs every 5 min to verify blocking |
| `cerberus-blockpage.service` | systemd | Serves block page on port 80 |
| `cerberus-blockpage-https.service` | systemd | Serves block page on port 443 |
| `cerberus-refresh.service` | systemd | Fetches fresh blocklist on start |
| `cerberus-refresh.timer` | systemd | Triggers refresh daily at midnight |

### How it works

1. **iptables NAT REDIRECT** — all port 53 traffic (UDP+TCP) is redirected to `127.0.0.1:5353` regardless of network config or VPN
2. **DNS resolver** (`cerberus-resolve` user, UID 950) — queries SQLite DB; returns `127.0.0.1` for blocked domains, forwards allowed domains to upstream DNS
3. **UID exclusion** — resolver's own outbound DNS is excluded from REDIRECT to prevent loops
4. **DoH/DoT/DoQ blocks** — DROP rules block known provider IPs on tcp 853 and tcp/udp 443

Backup copies of `core.sh` are stored in hidden locations (listed in `config`) and are also made immutable. If the main script is altered or deleted, it's restored from backup on the next `check` cycle.

## Full Lockdown

To make it truly irreversible:

1. Run `passwd` and set a password you don't know (mash the keyboard).
2. Delete any saved passwords from your session.
3. The only way out is rebooting from a live USB.

## Uninstall

```bash
sudo ./uninstall.sh
```

Removes all services, iptables rules, resolver, database, system user, and restores DNS config.
