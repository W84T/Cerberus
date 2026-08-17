# Cerberus Android — Planned Architecture

## Device Specs (tested)

| Property | Value |
|---|---|
| Model | 2201117TG (Xiaomi) |
| Android | 13 (SDK 33) |
| Kernel | 4.19.157-perf |
| Root | Not rooted |
| iptables | v1.8.7 (legacy) — exists but needs root |
| nf_conntrack | Available |
| ip_tables | Available in /proc/net |
| SELinux | Unknown enforcement status |

## Architecture

```
Cerberus Android
       │
       ▼
Platform Detection Layer
       │
       ├── Detect: iptables / nftables / no root
       │
       ▼
Enforcement Backend (pluggable)
       │
       ├── iptables backend (rooted, legacy kernels)
       ├── nftables backend (rooted, modern kernels)
       ├── VPNService backend (no root, API 21+)
       └── Private DNS wrapper (limited, API 29+)
       │
       ▼
SQLite Resolver (shared with Linux version)
```

## Detection Logic

1. Try `iptables -L` → works? use iptables backend
2. Try `nft list ruleset` → works? use nftables backend
3. No root? → VPNService backend (user-space DNS interception)
4. Android 10+? → Private DNS override as last resort

## Platform Differences

Android iptables varies significantly across:
- Device manufacturers (Samsung, Xiaomi, Pixel, etc.)
- Android versions
- Kernel configs
- SELinux policies
- Vendor modifications

The platform detection layer must test what actually works,
not assume a specific iptables command set.

## Notes

- Rooting requires bootloader unlock → wipes all data
- Magisk is the standard root method
- VPNService approach (no root) is more compatible
- Same SQLite database can be shared between Linux and Android
