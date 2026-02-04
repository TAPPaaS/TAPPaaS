# OpenWebUI on TAPPaaS - Installation Guide

**Version:** 0.9.0  
**Author:** Erik Daniel
**Release Date:** 2026-02-04  
**Status:** Development (Manual Deployment)

## Overview

This guide shows how to install OpenWebUI on TAPPaaS infrastructure with PostgreSQL database, Redis cache, and automated backups.

## Known limitations
Steps 2-4 will be replaced by ./install.sh openwebui - when the trunk issue is resolved!
pfSense router --> OPNsense
192.168 range --> 10. range
configuration.nix not modular --> flake based structure


**Target Setup:**
- VM on Proxmox with VLAN trunk mode
- OpenWebUI v0.7.2 in Podman container
- PostgreSQL 15 database
- Redis 7 for resource management
- Automated daily backups

## Prerequisites

- Proxmox VE host with bridge (vmbr0)
- VLAN 210 configured (srv zone)
- pfSense firewall with DHCP on VLAN 210
- Template VM 8080 with NixOS installed

## Network Requirements

### VLAN Configuration

OpenWebUI runs on VLAN 210 (srv zone) with trunk mode:
- No VLAN tag on VM network device
- VLAN interface created inside VM
- DHCP provides IP address

### Firewall Rules

Required pfSense rules on SRV interface:
```
Action: Pass
Source: SRV subnets
Destination: This Firewall (self)
Port: 53 (DNS)

Action: Pass  
Source: SRV subnets
Destination: Any
Port: Any (Internet access)
```

### Bridge Configuration (Critical)

Remove `bridge-vids` from Proxmox bridge config:
```bash
# On Proxmox host
nano /etc/network/interfaces

# Find and REMOVE this line:
# bridge-vids 2-4094

# Apply changes
ifreload -a
```

**Why:** `bridge-vids 2-4094` breaks VLAN trunk mode by adding all VLANs with wrong flags.

## Installation Steps

### Step 1: Prepare Configuration File

Get the openwebui.nix configuration:
```bash
# On tappaas-cicd
cd ~/TAPPaaS/nix-modules/apps
```

**Critical settings in openwebui.nix:**
```nix
# Cloud-init MUST have network disabled
services.cloud-init = {
  enable = true;
  network.enable = false;  # CRITICAL!
};

# NetworkManager MUST be disabled
networking.networkmanager.enable = false;

# Use ens18 interface (NixOS default)
networking = {
  interfaces.ens18.useDHCP = false;
  
  vlans."ens18.210" = {
    id = 210;
    interface = "ens18";
  };
  
  interfaces."ens18.210".useDHCP = true;
  
  defaultGateway = {
    address = "192.168.210.1";
    interface = "ens18.210";
  };
};
```

### Step 2: Create VM


### Step 3: Deploy Configuration
```bash
# Option A: Direct SCP (if SSH keys configured)
scp openwebui.nix tappaas@openwebui.srv.internal:/tmp/configuration.nix
ssh tappaas@openwebui.srv.internal
sudo mv /tmp/configuration.nix /etc/nixos/configuration.nix

# Option B: Via Proxmox (if SSH not working)
# On tappaas-cicd
scp openwebui.nix root@tappaas2.mgmt.internal:/tmp/

# On tappaas2
ssh root@tappaas2.mgmt.internal
qm guest exec 999 -- tee /etc/nixos/configuration.nix < /tmp/openwebui.nix
```

### Step 4: Build System
```bash
# Via qm terminal or SSH
qm terminal 999
# Login as tappaas

# Build NixOS configuration
sudo nixos-rebuild switch
```

**Expected build time:** 10-20 minutes (first time)

**What happens:**
1. Downloads packages (PostgreSQL, Redis, Podman)
2. Pulls OpenWebUI container image (~500MB-1GB)
3. Configures services
4. Starts containers

### Step 5: Fix Network (If Needed)

After rebuild, parent interface may still have old IP:
```bash
# Remove old IP from parent interface
sudo ip addr flush dev ens18

# Verify VLAN interface has IP
ip addr show ens18.210
# Should show: inet 192.168.210.x/24

# Test connectivity
ping -c 3 8.8.8.8
```

### Step 6: Verify Installation

Run health check:
```bash
# Check services
systemctl status postgresql redis-openwebui openwebui-wrapper

# Check container (run as root)
sudo podman ps

# Check network
ip addr show ens18.210

# Test web interface
curl http://localhost:8080
```

**Expected results:**
- All services: active (running)
- Container: Up X minutes
- IP: 192.168.210.x/24
- HTTP: 200 OK

### Step 7: Access Web Interface

**From browser:**
```
http://192.168.210.159:8080
http://openwebui.srv.internal:8080
```

**First login:**
1. Create admin account
2. Configure AI backend (optional)
3. Test interface

## Configuration

### Database Connection

PostgreSQL uses trust authentication for localhost (no password required):
```bash
# Connection string in /etc/secrets/openwebui.env
DATABASE_URL=postgresql://openwebui:REPLACE_PASSWORD@127.0.0.1:5432/openwebui
```

**Note:** Password is ignored due to trust auth. This is safe for localhost-only connections.

### LiteLLM Integration (Optional)

To connect to LiteLLM backend:

**Via Web UI:**
```
Settings → Connections → OpenAI API
- API Base URL: http://192.168.2.234:4000/v1
- API Key: [your-litellm-key]
- Save
```

**Via Config File:**
```nix
environment.etc."secrets/openwebui.env".text = ''
  # ... existing config ...
  OPENAI_API_BASE_URL=http://192.168.2.234:4000/v1
  OPENAI_API_KEY=sk-your-key-here
'';
```

Then rebuild: `sudo nixos-rebuild switch && sudo systemctl restart openwebui-wrapper`

### Backup Configuration

Automated backups run daily:

| Service | Time | Location | Retention |
|---------|------|----------|-----------|
| PostgreSQL | 02:00 | /var/backup/postgresql/ | 30 days |
| Redis | 02:30 | /var/backup/redis/ | 30 days |
| Container data | 02:45 | /var/backup/openwebui-data/ | 30 days |
| Environment files | 02:50 | /var/backup/openwebui-env/ | 30 days |

Cleanup runs monthly (removes files older than 30 days).

## Troubleshooting

### Container Won't Start
```bash
# Check logs
sudo journalctl -u openwebui-wrapper -n 100

# Common issue: DNS failure during image pull
# Solution: Verify internet connectivity
ping 8.8.8.8
curl https://ghcr.io
```

### Wrong IP Address (192.168.2.x instead of 192.168.210.x)

**Cause:** Cloud-init or NetworkManager overriding VLAN config

**Solution:**
```bash
# Check configuration
grep -E "(network.enable|networkmanager.enable)" /etc/nixos/configuration.nix

# Must show:
# services.cloud-init.network.enable = false;
# networking.networkmanager.enable = false;

# If wrong, fix and rebuild
sudo nano /etc/nixos/configuration.nix
sudo nixos-rebuild switch
```

### No Internet Access
```bash
# Check VLAN interface
ip addr show ens18.210
# Must have IP: 192.168.210.x/24

# Check gateway
ip route
# Must show: default via 192.168.210.1 dev ens18.210

# Check DNS
cat /etc/resolv.conf
# Must show: nameserver 192.168.210.1

# Test connectivity
ping -c 3 192.168.210.1  # Gateway (may be blocked by firewall)
ping -c 3 8.8.8.8        # Internet (must work)
```

### PostgreSQL Not Used
```bash
# Check if PostgreSQL is running
systemctl status postgresql

# Check database tables
sudo -u postgres psql openwebui -c "\dt"

# Should show 31 tables

# Check active connections
sudo -u postgres psql openwebui -c "SELECT count(*) FROM pg_stat_activity WHERE datname='openwebui';"

# Should show active connections (4-6)
```

### Redis Not Used
```bash
# Check if Redis is running
systemctl status redis-openwebui

# Check connections
redis-cli -p 6379 INFO clients

# Check activity
redis-cli -p 6379 MONITOR
# Should show openwebui:* keys
```

## Security Notes

### Current Setup

- PostgreSQL: Trust authentication (localhost only)
- Passwords: Placeholder values (REPLACE_PASSWORD)
- Network: VLAN isolation

**This is acceptable for:**
- Development environments
- Internal/private networks
- Single-user setups

### Production Hardening (Future)

For production deployments:

1. Generate secure passwords:
```bash
openssl rand -base64 32
```

2. Update secrets in configuration.nix
3. Change PostgreSQL authentication from trust to scram-sha-256
4. Enable SSL/TLS for web interface
5. Configure firewall restrictions
6. Set up monitoring/alerting

## Maintenance

### Updating OpenWebUI
```bash
# Edit configuration.nix
sudo nano /etc/nixos/configuration.nix

# Change version in 'let versions' section:
versions = {
  openwebui = "v0.7.3";  # Update version
  ...
};

# Rebuild
sudo nixos-rebuild switch

# Restart service
sudo systemctl restart openwebui-wrapper

# Verify new version
sudo podman inspect openwebui | grep -i version
```

### Database Backup/Restore

**Manual backup:**
```bash
sudo -u postgres pg_dump openwebui > openwebui-backup.sql
```

**Restore:**
```bash
sudo -u postgres psql openwebui < openwebui-backup.sql
```

### Log Management

**View container logs:**
```bash
sudo podman logs openwebui
sudo podman logs -f openwebui  # Follow mode
```

**View service logs:**
```bash
sudo journalctl -u openwebui-wrapper
sudo journalctl -u postgresql
sudo journalctl -u redis-openwebui
```

## Known Issues

### Issue: Interface Name Confusion

**Symptom:** Configuration uses eth0 but VM has ens18

**Cause:** NixOS uses systemd predictable naming (ens18) by default

**Solution:** Always use ens18 in configuration files

### Issue: Cloud-Init Network Conflict

**Symptom:** VLAN interface not created, NetworkManager takes over

**Cause:** cloud-init.network.enable overrides declarative config

**Solution:** Always set `services.cloud-init.network.enable = false;`

### Issue: Container Shows as Running but podman ps Empty

**Symptom:** systemctl shows active but `podman ps` shows nothing

**Cause:** Container runs as root, not user

**Solution:** Use `sudo podman ps` to see container

## Support

For issues or questions:
- Check logs: `sudo journalctl -u openwebui-wrapper -n 100`
- Review configuration: `/etc/nixos/configuration.nix`
- Check network: `ip addr show ens18.210`
- Verify services: `systemctl status postgresql redis-openwebui openwebui-wrapper`

---

**Document Version:** 1.0  
**Last Updated:** 2026-02-04  
**Tested On:** NixOS 25.05, Proxmox VE 8.x