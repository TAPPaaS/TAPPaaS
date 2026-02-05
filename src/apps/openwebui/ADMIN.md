# OpenWebUI on TAPPaaS - Admin Guide

**Version:** 0.9.0  
**Author:** Erik Daniel
**Release Date:** 2026-02-04  
**Status:** Development (Manual Deployment)

## Overview

This guide shows how to administrate / troubleshoot OpenWebUI on TAPPaaS infrastructure with PostgreSQL database, Redis cache, and automated backups.


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
**Tested On:** NixOS 25.05, Proxmox VE 9.x