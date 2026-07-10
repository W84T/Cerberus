# Cerberus

A self-hardening content filter for Arch Linux that blocks adult content and locks itself down so even you can't easily undo it.

## Features

- **1.5M+ blocked domains** — downloads and periodically refreshes from blocklistproject.github.io
- **Custom block list** — add your own domains alongside the main list
- **Whitelist** — exempt specific domains from blocking
- **DNS lockdown** — iptables blocks port 53 (DNS), 853 (DoT), and 443 (DoH) to prevent circumvention
- **DNS provider blocking** — drops traffic to Cloudflare, Google, Quad9, OpenDNS, NextDNS, AdGuard, ControlD
- **Immutable hosts** — `/etc/hosts` is set `chattr +i` to prevent tampering
- **Self-healing** — hidden backup copies (4 locations) restore the core script if corrupted or deleted
- **Block page server** — serves a "Site Blocked" page on ports 80 (HTTP) and 443 (HTTPS) with a self-signed cert
- **Timed unlock** — request a temporary unlock (default 24h); automatically re-locks when expired
- **Watchdog** — systemd timer verifies blocking every 5 minutes and re-applies if missing
- **Firefox DoH disabled** — automatically sets `network.trr.mode = 5` in all Firefox profiles
- **Faillock** — 3 wrong sudo attempts = 10 minute lockout
- **SafeSearch enforcement** — redirects Google, YouTube, and Bing to their SafeSearch IPs via hosts entries
- **No-password sudo** — `cerberus` CLI runs via passwordless sudo for the configured user only

## Installation

```bash
sudo ./setup.sh
```

This installs everything under `/opt/cerberus/`, sets up systemd services, creates the `cerberus` CLI command, and applies the blocklist immediately.

## Usage

```
cerberus status                  Show blocking status
cerberus lock                    Apply and lock immediately
cerberus unlock [duration]       Request unlock (default: 24h, e.g. 1h, 30m)
cerberus cancel                  Cancel pending unlock
cerberus block add <domain>      Add domain to custom block list
cerberus block rm <domain>       Remove domain from custom block list
cerberus block list              List custom blocked domains
cerberus whitelist add <domain>  Add domain to whitelist
cerberus whitelist rm <domain>   Remove domain from whitelist
cerberus safesearch list         Show SafeSearch redirects
cerberus safesearch apply        Apply SafeSearch redirects
cerberus update                  Refresh blocklist from internet
```

## Architecture

| Component | Location | Role |
|-----------|----------|------|
| `core.sh` | `/opt/cerberus/core.sh` | Applies hosts, iptables, self-heals |
| `cli.sh` | `/opt/cerberus/cli.sh` | User-facing CLI (`cerberus` command) |
| `blockpage.py` | `/opt/cerberus/blockpage.py` | Block page HTTP/HTTPS server |
| `unlock-now.sh` | `/opt/cerberus/unlock-now.sh` | Removes all blocking rules |
| `config` | `/opt/cerberus/config` | Whitelist, blocklist URL, backup locations |
| `custom-block.txt` | `/opt/cerberus/custom-block.txt` | User-defined domains to block |
| `cerberus.service` | systemd | Applies blocking on boot |
| `cerberus-watchdog.timer` | systemd | Runs every 5 min to verify blocking |
| `cerberus-blockpage.service` | systemd | Serves block page on port 80 |
| `cerberus-blockpage-https.service` | systemd | Serves block page on port 443 |

Backup copies of `core.sh` are stored in hidden locations (listed in `config`) and are also made immutable. If the main script is altered or deleted, it's restored from backup on the next `check` cycle.

## Full Lockdown

To make it truly irreversible:

1. Run `passwd` and set a password you don't know (mash the keyboard).
2. Delete any saved passwords from your session.
3. The only way out is waiting for the unlock timer or rebooting from a live USB.

## Requirements

- Arch Linux
- `curl`, `openssl` (installed automatically by `setup.sh`)
- `systemd-resolved` for DNS
