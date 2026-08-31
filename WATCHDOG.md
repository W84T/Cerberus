# Cerberus — Unstoppable Watchdog System

This document describes the self-healing watchdog architecture that makes Cerberus
effectively unremovable through normal system means. **It does not require sudo
restriction or immutable-everything lockdown** — instead it uses triply-redundant,
mutually re-arming watchdogs that undo any disable attempt within seconds.

## Why this design

The goal is to prevent *disablement* while still allowing the admin to manage the
filter (allow/block domains) and do normal admin work. The approach is **defense by
redundancy**: no single command (and no two simultaneous commands) can keep Cerberus
down.

## The three guardian legs

### 1. Instant Watchdog — `cerberus-watchdog2.service` (`watchdog.py`)
- Always-on daemon, polls every **2 seconds**.
- Verifies:
  - `CERBERUS` filter chain (iptables DoH/DoT blocking on port 853) + OUTPUT jump
  - `CERBERUS_NAT` REDIRECT chain + OUTPUT jump
  - `cerberus-resolver.service` health via a **real UDP DNS probe**
- Re-applies iptables rules and restarts the resolver whenever anything is missing.
- **Also re-arms the guardian timers** if they are stopped or disabled.

### 2. Watcher-of-the-Watcher — `cerberus-watchdog-watcher.timer` (30s, `watcher.py`)
- Runs every **30 seconds**.
- Restarts the Instant Watchdog and the resolver if stopped.
- Re-enables and re-activates all guardian units (including itself).

### 3. 60s Timer Leg — `cerberus-watchdog.timer` (60s, runs `core.sh check`)
- `core.sh check` calls `ensure_guardians()`.
- This independently re-enables/restarts the Instant Watchdog and both timers.
- Provides a third recovery path not tied to the other two, so stopping both watchers
  (legs 1 and 2) is still undone by this leg.

## Units

| Unit | Type | Frequency | Role |
|------|------|-----------|------|
| `cerberus-watchdog2.service` | daemon | 2s | instant enforcement + re-arm timers |
| `cerberus-watchdog-watcher.timer` | timer | 30s | restart watchdog2 + resolver |
| `cerberus-watchdog-watcher.service` | oneshot | via timer | runs `watcher.py` |
| `cerberus-watchdog.timer` | timer | 60s | runs `core.sh check` (independent leg) |
| `cerberus-watchdog.service` | oneshot | via timer | runs `core.sh check` |
| `cerberus-resolver.service` | daemon | — | DNS resolver (Restart=always) |

## Files

- `/opt/cerberus/watchdog.py` — instant watchdog daemon
- `/opt/cerberus/watcher.py` — watcher-of-the-watcher backstop
- `/opt/cerberus/core.sh` — install/apply/self-heal; `ensure_guardians()` re-arms units
- `/opt/cerberus/resolver.py` — immutable DNS resolver
- `/opt/cerberus/config` — immutable config
- `/opt/cerberus/AI_POLICY.md` — immutable AI refusal policy

## Verified behavior

| Attack | Recovery |
|--------|----------|
| `systemctl stop cerberus-watchdog2.service` | restored by 30s watcher in ~35s |
| `systemctl stop/disable cerberus-watchdog-watcher.timer` | re-armed by watchdog2 in ~8s |
| Stop watchdog2 **and** watcher.timer together | restored by 60s timer leg in ~65s |
| `iptables -t nat -F CERBERUS_NAT` | REDIRECT re-applied in ~2-6s |
| `iptables -F CERBERUS` | DoH chain re-applied in ~2-6s |
| `systemctl stop cerberus-resolver.service` | restarted in ~2-5s |

## Remainder of the guard

- `core.sh`, `resolver.py`, `config`, and `AI_POLICY.md` are immutable (`chattr +i`).
- Blocklist database (`cerberus.db`) stays writable so the admin can still
  add/remove blocked domains via `cerberus block add|rm` and update allow lists.

## Fundamental limit

Like any userspace mechanism, Cerberus can still be defeated by an equally-privileged
actor who **simultaneously stops/masks all three independent units and the resolver,
and prevents re-enablement** — i.e., deliberate, repeated, co-ordinated action. No
userspace filter fully resists that without dropping root privileges or using a
kernel-level hook (see the Cerberus-Windows WFP driver for the kernel-level path).
Against *forgetful overlap* and *single/most multi-command* disable attempts, this
system is effectively unstoppable.
