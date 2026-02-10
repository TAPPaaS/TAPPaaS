```markdown
# UniFi Network Controller - TAPPaaS

**Version:** 0.9.0  
**Author:** @ErikDaniel007
**Release Date:** 2026-02-10 
**Status:** Development

NixOS-based UniFi Network Controller for managing Ubiquiti network devices.

## Overview

This deployment provides a declarative UniFi Network Controller with:
- Automated daily backups
- PVE integration (cloud-init, serial console, QEMU guest agent)
- Full firewall configuration for device adoption and management

## Features

- **UniFi Controller**: Version 10.0.162
- **Backup Strategy**: Daily backups to `/var/backup/unifi` with 30-day retention
- **Network Ports**: Pre-configured for device discovery, adoption, and guest portal
- **PVE Ready**: Auto-resize disk, serial console access, NetworkManager networking

## Architecture

```
┌─────────────────────────────────┐
│   UniFi Controller (Java)       │
│   - Port 8443 (Admin UI)        │
│   - Port 8080 (Device Comm)     │
└─────────────────────────────────┘
          ↓
┌─────────────────────────────────┐
│   MongoDB 7.0.25 (Embedded)     │
│   - Data: /var/lib/unifi        │
└─────────────────────────────────┘
          ↓
┌─────────────────────────────────┐
│   Backup System                 │
│   - Daily: 02:00                │
│   - Retention: 30 days          │
│   - Location: /var/backup/unifi │
└─────────────────────────────────┘
```

## VM Specifications

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| vCPU     | 1       | 2           |
| Memory   | 2GB     | 4GB         |
| Disk     | 20GB    | 32GB        |
| Network  | 1 NIC   | 1 NIC       |

## Security Notice

⚠️ **MongoDB CVE-2025-14847**: This deployment temporarily allows an insecure MongoDB version due to upstream dependencies. Monitor [NixOS packages](https://github.com/NixOS/nixpkgs) for patched versions.

## Quick Start

See [INSTALL.md](INSTALL.md) for deployment instructions.

## Access

After deployment:
- Admin UI: `https://<vm-ip>:8443`
- Default credentials: Set during initial setup wizard

## Ports

| Port  | Protocol | Purpose                    |
|-------|----------|----------------------------|
| 22    | TCP      | SSH management             |
| 8080  | TCP      | Device communication       |
| 8443  | TCP      | Controller admin UI        |
| 8880  | TCP      | Guest portal HTTP redirect |
| 8843  | TCP      | Guest portal HTTPS         |
| 6789  | TCP      | Mobile app throughput test |
| 3478  | UDP      | STUN (device discovery)    |
| 10001 | UDP      | Device discovery           |

## Backup & Recovery

**Backup Location**: `/var/backup/unifi`  
**Schedule**: Daily at 02:00 UTC  
**Retention**: 30 days  

Restore procedure: See [INSTALL.md](INSTALL.md#backup-restore)

## Support

- TAPPaaS Documentation: [tappaas.org](https://tappaas.org)
- UniFi Documentation: [help.ui.com](https://help.ui.com)
- NixOS Manual: [nixos.org/manual](https://nixos.org/manual)

## License

Copyright (c) 2025 TAPPaaS org  
MPL 2.0 | https://mozilla.org/MPL/2.0/
```