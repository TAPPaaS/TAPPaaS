```
# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# This file incorporates work covered by the following copyright and permission notice:
# Copyright (c) 2021-2025 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
```

# UniFi Controller Installation Guide

Complete deployment instructions for the TAPPaaS UniFi Network Controller on Proxmox VE with NixOS.

## Prerequisites

- Proxmox VE cluster with NixOS template
- Network: VLAN configured for management
- DNS: Optional but recommended
- SSH key for `tappaas` user

## Step 1: Validate default TAPPaaS config

```bash
look at ./unifi.json.
- Confirm if this is reflecting how you want this module to be installed in your environments. For instance if:
- you want to have the module to run on a different node than the default "tappaas2" 
- you want the VM to e on a different storage node than "tanka1"
- you want to make it a member of a different LAN zone (VLAN)
Then copy the json to /home/tappaas/config and edit the file to reflect your choices

Then as tappaas use on the tappaas-cicd: run the command:
```
./install.sh unifi
```

## Step 2: Initial Setup

### 2.1 Access admin UI

1. Navigate to `https://<vm-ip>:8443`
2. Accept self-signed certificate warning
3. Follow setup wizard:
   - Create admin account
   - Configure controller name
   - Skip device adoption (do later)

### 2.2 Adopt first device

1. Ensure device is on same network or configure Layer 3 adoption
2. SSH into device: `ssh ubnt@<device-ip>` (default password: `ubnt`)
3. Set inform URL: `set-inform http://<controller-ip>:8080/inform`
4. Approve adoption in controller UI

## Step 3: Verify Backup System

```bash
# Check backup timer is active
sudo systemctl list-timers | grep unifi-backup

# Manually trigger test backup
sudo systemctl start unifi-backup.service

# Verify backup created
ls -lh /var/backup/unifi/

# Check backup content
tar -tzf /var/backup/unifi/unifi-$(date +%F).tar.gz
```

## Backup & Restore

### Manual Backup

```bash
# Stop UniFi service
sudo systemctl stop unifi

# Create backup
sudo tar -czf /tmp/unifi-manual-$(date +%F).tar.gz \
  -C /var/lib/unifi data

# Start UniFi service
sudo systemctl start unifi

# Copy backup off-VM
scp tappaas@<vm-ip>:/tmp/unifi-manual-*.tar.gz ./
```

### Restore from Backup

```bash
# Stop UniFi service
sudo systemctl stop unifi

# Backup current data (safety)
sudo mv /var/lib/unifi/data /var/lib/unifi/data.old

# Extract backup
sudo tar -xzf /var/backup/unifi/unifi-YYYY-MM-DD.tar.gz \
  -C /var/lib/unifi

# Fix permissions
sudo chown -R unifi:unifi /var/lib/unifi/data

# Start UniFi service
sudo systemctl start unifi

# Verify controller accessible
curl -k https://localhost:8443
```

## Troubleshooting

### Controller not accessible

```bash
# Check service status
sudo systemctl status unifi

# Check logs
sudo journalctl -u unifi -n 50 --no-pager

# Check ports
sudo ss -tlnp | grep -E '8080|8443'

# Check firewall
sudo iptables -L -n | grep -E '8080|8443'
```

### Devices not adopting

```bash
# Verify device can reach controller
# On device:
ping <controller-ip>
telnet <controller-ip> 8080

# Check inform URL in device
ssh ubnt@<device-ip>
info

# Set correct inform URL
set-inform http://<controller-ip>:8080/inform
```

### MongoDB issues

```bash
# Check MongoDB embedded process
ps aux | grep mongo

# Check data directory
ls -lh /var/lib/unifi/data/db/

# Repair database (if corrupted)
sudo systemctl stop unifi
sudo -u unifi mongod --repair --dbpath /var/lib/unifi/data/db
sudo systemctl start unifi
```

## Security Hardening (Production)

### 1. Enable HTTPS with valid certificate

```bash
# Option A: Let's Encrypt (requires public DNS)
# See: https://help.ui.com/hc/en-us/articles/115001567747

# Option B: Import certificate manually
# See: https://help.ui.com/hc/en-us/articles/204909374
```

### 2. Restrict firewall (if management VLAN)

```nix
# In configuration.nix
networking.firewall = {
  interfaces.ens18.allowedTCPPorts = [ 22 8443 ];  # Admin only
  interfaces.ens19.allowedTCPPorts = [ 8080 ];     # Devices only
  interfaces.ens19.allowedUDPPorts = [ 3478 10001 ];
};
```

### 3. Enable 2FA

1. Settings → Admins → Select user
2. Enable "Two-Factor Authentication"
3. Scan QR code with authenticator app

## Monitoring

### Resource usage

```bash
# CPU/Memory
htop

# Disk usage
df -h /var/lib/unifi
du -sh /var/lib/unifi/*

# Network connections
sudo ss -tnp | grep java
```

### Log monitoring

```bash
# Real-time logs
sudo journalctl -u unifi -f

# Error logs only
sudo journalctl -u unifi -p err -n 100

# Backup logs
sudo journalctl -u unifi-backup.service
```

## Upgrading

### UniFi Controller version

```bash
# Check current version
nix-env -qa unifi

# Check available versions
nix search nixpkgs unifi

# Update to latest (requires config change)
# Edit configuration.nix versions.unifi
sudo nixos-rebuild switch
```

### NixOS system

```bash
# Update channel
sudo nix-channel --update

# Rebuild with updates
sudo nixos-rebuild switch --upgrade

# Rollback if issues
sudo nixos-rebuild switch --rollback
```

## Migration from Existing Controller

### Export from old controller

1. Settings → Maintenance → Backup
2. Download `.unf` file

### Import to new controller

1. Complete initial setup on new controller
2. Settings → Maintenance → Restore
3. Upload `.unf` file
4. Wait for restore (may take 5-10 minutes)
5. Update device inform URLs to new controller

### Update device inform URLs

```bash
# SSH into each device
ssh ubnt@<device-ip>

# Set new controller
set-inform http://<new-controller-ip>:8080/inform
```

## Off-VM Backup Integration

### Proxmox Backup Server

```bash
# On PVE host - create backup job
# UI: Datacenter → Backup → Add

# Or via CLI
vzdump <vmid> --storage <pbs-storage> --mode snapshot
```

### Remote sync (alternative)

```nix
# Add to configuration.nix
systemd.services.unifi-backup-remote = {
  description = "Sync UniFi backups to remote";
  after = [ "unifi-backup.service" ];
  serviceConfig = {
    Type = "oneshot";
    ExecStart = pkgs.writeShellScript "backup-sync" ''
      ${pkgs.rsync}/bin/rsync -avz --delete \
        /var/backup/unifi/ \
        backup@<remote-host>:/backups/unifi/
    '';
  };
};

systemd.timers.unifi-backup-remote = {
  wantedBy = [ "timers.target" ];
  timerConfig.OnCalendar = "*-*-* 03:00:00";
};
```

## Support Resources

- **TAPPaaS**: https://tappaas.org
- **UniFi Help**: https://help.ui.com
- **NixOS Manual**: https://nixos.org/manual/nixos/stable
- **Community**: https://community.ui.com

## Known Issues

- **MongoDB CVE-2025-14847**: Temporarily permitted via `permittedInsecurePackages`
  - Monitor: https://github.com/NixOS/nixpkgs/issues
  - Remove flag when patched version available

## Changelog

- **2026-02-10**: Initial release (UniFi 10.0.162, MongoDB 7.0.25)
```