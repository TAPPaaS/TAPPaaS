# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# OpenWebUI — Admin Guide

**Version:** 0.9.5
**Maintainer:** @ErikDaniel007
**Updated:** 2026-05-21

## Quick reference

| Item | Value |
|---|---|
| VM | openwebui (VMID 311) on tappaas2 |
| Zone | srv-work |
| Host | openwebui.srv-work.internal |
| Port | 8080 |
| Proxy | openwebui.test.tapaas.org |

---

## Operations

### Update
```bash
/home/tappaas/bin/update-module.sh openwebui
```
Handles: nixos-rebuild, PostgreSQL version migration, image prune.

### Health check
```bash
cd TAPPaaS/src/apps/openwebui && ./test.sh
```
Checks (in order): SSH, container running, HTTP :8080, PostgreSQL, Redis.

### Manual install / reinstall
```bash
/home/tappaas/bin/install-module.sh openwebui
```

---

## Troubleshooting

Work through checks in order. Stop at the first failure.

### 1. VM reachable?
```bash
ssh tappaas@openwebui.srv-work.internal
```
If not: check Proxmox — is VM running on tappaas2?

### 2. Wrong IP (192.168.2.x instead of 192.168.210.x)?
Cloud-init or NetworkManager overriding VLAN config.
```bash
grep -E "cloud-init.network|networkmanager" /etc/nixos/configuration.nix
# Must show:
# services.cloud-init.network.enable = false;
# networking.networkmanager.enable = false;
```
Fix, then `sudo nixos-rebuild switch`.

### 3. No internet on the VM?
```bash
ip addr show ens18.210   # must have 192.168.210.x/24
ip route                 # must show default via 192.168.210.1
cat /etc/resolv.conf     # must show nameserver 192.168.210.1
ping 8.8.8.8
```

### 4. Container not running?
```bash
sudo podman ps                          # use sudo — container runs as root
sudo journalctl -u openwebui-wrapper -n 50
```
Common cause: DNS failure during image pull (check internet first).

### 5. PostgreSQL not responding?
```bash
systemctl status postgresql
pg_isready -h 127.0.0.1 -p 5432 -U openwebui -d openwebui
sudo -u postgres psql openwebui -c "\dt"
```

### 6. Redis not responding?
```bash
systemctl status redis-openwebui
redis-cli -h 127.0.0.1 -p 6379 ping    # expect PONG
```

### 7. HTTP not responding (port 8080)?
```bash
curl -v http://localhost:8080/
sudo podman logs openwebui --tail 50
```

---

## Maintenance

### View logs
```bash
sudo podman logs -f openwebui
sudo journalctl -u openwebui-wrapper
sudo journalctl -u postgresql
```

### Manual database backup
```bash
sudo -u postgres pg_dump openwebui > openwebui-$(date +%Y%m%d).sql
```
Automated backups run daily; backups are at `/var/backup/openwebui` (7-day rotation).

### Manual database restore
```bash
sudo -u postgres psql openwebui < openwebui-<date>.sql
```

---

## Known issues

- **MongoDB CVE-2025-14847** — temporarily permitted via `permittedInsecurePackages`. Monitor upstream.
- **PBS backup** — VM not yet included in PBS backup jobs (`backup:vm` not implemented). See tracking issue.

---

**Tested on:** NixOS 25.05, Proxmox VE 9.x, PostgreSQL 17, Redis with AOF
