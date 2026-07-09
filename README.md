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
- **No-password sudo** — `blocker` CLI runs via passwordless sudo for the configured user only

## Installation

```bash
sudo ./setup.sh
```

This installs everything under `/opt/blocker/`, sets up systemd services, creates the `blocker` CLI command, and applies the blocklist immediately.

## Usage

```
blocker status                  Show blocking status
blocker lock                    Apply and lock immediately
blocker unlock [duration]       Request unlock (default: 24h, e.g. 1h, 30m)
blocker cancel                  Cancel pending unlock
blocker block add <domain>      Add domain to custom block list
blocker block rm <domain>       Remove domain from custom block list
blocker block list              List custom blocked domains
blocker whitelist add <domain>  Add domain to whitelist
blocker whitelist rm <domain>   Remove domain from whitelist
blocker update                  Refresh blocklist from internet
```

## Architecture

| Component | Location | Role |
|-----------|----------|------|
| `core.sh` | `/opt/blocker/core.sh` | Applies hosts, iptables, self-heals |
| `cli.sh` | `/opt/blocker/cli.sh` | User-facing CLI (`blocker` command) |
| `blockpage.py` | `/opt/blocker/blockpage.py` | Block page HTTP/HTTPS server |
| `unlock-now.sh` | `/opt/blocker/unlock-now.sh` | Removes all blocking rules |
| `config` | `/opt/blocker/config` | Whitelist, blocklist URL, backup locations |
| `custom-block.txt` | `/opt/blocker/custom-block.txt` | User-defined domains to block |
| `blocker.service` | systemd | Applies blocking on boot |
| `blocker-watchdog.timer` | systemd | Runs every 5 min to verify blocking |
| `blocker-blockpage.service` | systemd | Serves block page on port 80 |
| `blocker-blockpage-https.service` | systemd | Serves block page on port 443 |

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
