# OpenWebUI on TAPPaaS - Release Notes

**Version:** 0.9.0  
**Author:** Erik Daniel
**Release Date:** 2026-02-04  
**Status:** Development (Manual Deployment)

## Overview

This release provides a complete OpenWebUI stack on TAPPaaS infrastructure with PostgreSQL database, Redis caching, and automated backups. The system runs on NixOS with declarative configuration and VLAN trunk mode networking.

## Key Products

### Core Stack
- **OpenWebUI:** v0.7.2 (AI interface)
- **PostgreSQL:** 15.14 (persistent database)
- **Redis:** 7.x (resource coordination)
- **Podman:** 5.4.1 (container runtime)
- **NixOS:** 25.05 (operating system)

### Infrastructure
- **Proxmox VE:** Virtualization platform
- **pfSense:** Network firewall/router
- **VLAN 210:** Service network zone

## Key Features

### ✅ Multi-Service Architecture

**Database Layer:**
- PostgreSQL with 31 tables
- Trust authentication for localhost
- Automatic database initialization
- Daily automated backups

**Caching Layer:**
- Redis for resource management
- Distributed locking support
- Usage tracking and rate limiting
- Ephemeral key management (60s TTL)

**Application Layer:**
- OpenWebUI container via Podman
- Host networking mode
- Persistent data volumes
- WebSocket support (Redis-backed)

### ✅ Network Configuration

**VLAN Trunk Mode:**
- Single physical interface (ens18)
- VLAN 210 subinterface (ens18.210)
- DHCP IP assignment
- Internet access via pfSense

**Cross-VLAN Access:**
- Firewall rules for service communication
- LiteLLM integration (VLAN 2 → VLAN 210)
- DNS resolution via pfSense

### ✅ Automated Backups

**5 Backup Services:**
| Component | Schedule | Location |
|-----------|----------|----------|
| PostgreSQL | Daily 02:00 | /var/backup/postgresql/ |
| Redis | Daily 02:30 | /var/backup/redis/ |
| Container data | Daily 02:45 | /var/backup/openwebui-data/ |
| Environment files | Daily 02:50 | /var/backup/openwebui-env/ |
| Cleanup old backups | Monthly | All backup dirs |

**Retention:** 30 days (automatic cleanup)

### ✅ System Integration

**NixOS Features:**
- Declarative configuration
- Atomic updates
- Automatic rollback support
- Package version pinning

**Systemd Services:**
- PostgreSQL server
- Redis server  
- OpenWebUI wrapper
- Backup timers (5 services)

## What Works

### ✅ Fully Operational

- VM deployment on Proxmox
- VLAN trunk mode networking
- DHCP IP assignment (192.168.210.x)
- Internet connectivity
- PostgreSQL database (31 tables, active connections)
- Redis cache (4+ connections, resource tracking)
- OpenWebUI container (HTTP 200)
- Web interface access (port 8080)
- LiteLLM integration (cross-VLAN)
- Automated daily backups
- Log management (journald)

### ✅ Verified Components

**Database:**
```
- 31 PostgreSQL tables created
- Active connections: 4-6 concurrent
- Commands processed: 2600+
- Data persistence confirmed
```

**Cache:**
```
- Redis clients: 4 connected
- Memory usage: 1.37MB
- Command throughput: 2600+
- Lock coordination active
```

**Container:**
```
- Status: Up 60+ minutes
- Image: ghcr.io/open-webui/open-webui:v0.7.2
- Network: Host mode (port 8080)
- Logs: No errors
```

## Known Limitations

### ⚠️ Manual Deployment Required

**Current State:**
- No automated VM creation
- Manual configuration file deployment
- Manual NixOS rebuild step
- Manual network verification

**Workaround:** Follow INSTALL.md step-by-step

**Future:** See Roadmap (cloud-init automation)

### ⚠️ Configuration Requirements

**Critical Settings:**

These settings are REQUIRED and must not be changed:
```nix
# Cloud-init network MUST be disabled
services.cloud-init.network.enable = false;

# NetworkManager MUST be disabled  
networking.networkmanager.enable = false;

# Interface name MUST be ens18 (not eth0)
networking.vlans."ens18.210" = { ... };
```

**Why:** Cloud-init network autoconfiguration conflicts with VLAN trunk mode and causes:
- Interface rename failures
- NetworkManager override
- Wrong IP assignment (192.168.2.x instead of 192.168.210.x)

### ⚠️ Security Notes

**Current Setup:**
- PostgreSQL: Trust authentication (no password)
- Secrets: Placeholder passwords
- Network: VLAN isolation only

**Acceptable For:**
- Development environments
- Internal/private networks
- Demo/testing systems

**Not Recommended For:**
- Public-facing deployments
- Multi-tenant systems
- Compliance-sensitive environments

**Hardening Required:** See INSTALL.md Security Notes

### ⚠️ Template VM Not Updated

**Issue:** Template VM 8080 still has hardcoded configuration

**Impact:**
- Cannot use template directly
- Must manually deploy openwebui.nix
- No dynamic VLAN support yet

**Workaround:** Use complete openwebui.nix replacement

**Future:** Template will support dynamic cloud-init config

## Breaking Changes

### From Previous Setup

**Interface Name Change:**
- Old: eth0, eth0.210
- New: ens18, ens18.210
- Reason: NixOS systemd predictable naming

**Cloud-Init Behavior:**
- Old: network.enable = true (default)
- New: network.enable = false (required)
- Reason: Conflicts with VLAN trunk mode

**Container Runtime:**
- Old: Docker
- New: Podman
- Reason: Better systemd integration, rootless support

## Upgrade Notes

### From Development Version

No upgrade path available. This is the first production-ready release.

### Future Upgrades

OpenWebUI version updates:
```nix
# Edit /etc/nixos/configuration.nix
let
  versions = {
    openwebui = "v0.7.3";  # Change version here
    ...
  };
```

Then: `sudo nixos-rebuild switch && sudo systemctl restart openwebui-wrapper`

## Performance

### Resource Usage

**VM Specifications:**
- CPU: 2-4 vCPU recommended
- Memory: 4GB minimum (8GB recommended)
- Disk: 20GB minimum (50GB recommended)

**Actual Usage (Idle):**
- Memory: ~800MB (OpenWebUI) + 60MB (PostgreSQL) + 12MB (Redis)
- CPU: <5% idle, varies with usage
- Disk I/O: Low (mostly container data)

### Scaling Notes

**Single VM Limits:**
- Users: 10-50 concurrent (depends on AI backend)
- Requests: Limited by backend capacity
- Storage: Grows with conversations and files

**Not Suitable For:**
- High-availability requirements
- Multi-region deployments
- >100 concurrent users

## Testing

### Validation Tests

All tests passed:
```
✅ Network connectivity (VLAN 210)
✅ Internet access (8.8.8.8)
✅ PostgreSQL active (31 tables)
✅ Redis active (4 connections)
✅ Container running (60+ min uptime)
✅ Web interface (HTTP 200)
✅ LiteLLM connectivity (cross-VLAN)
✅ Backup services (5 timers configured)
```

### Test Environment

- Proxmox VE 9.x
- pfSense firewall
- NixOS 25.05
- VLAN 210 network
