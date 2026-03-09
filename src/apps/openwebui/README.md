# OpenWebUI on TAPPaaS

**Version:** 0.8.10
**Author:** @ErikDaniel007
**Release Date:** 2026-03-09
**Status:** Development

## Overview

OpenWebUI is an AI chat interface running on TAPPaaS infrastructure with PostgreSQL, Redis, and automated backups. The system is fully declarative on NixOS, managed by `tappaas-cicd`, and deployed via `update-module.sh`.

## Stack

| Component | Version | Purpose |
|-----------|---------|---------|
| OpenWebUI | v0.8.10 | AI chat interface (Podman container) |
| PostgreSQL | 15 | User accounts, chat history, settings |
| Redis | 7.x | Session state, WebSocket coordination, caching |
| Podman | 5.x | Container runtime |
| NixOS | 25.05 | Operating system (declarative configuration) |

## Infrastructure

| Setting | Value |
|---------|-------|
| VM name | `openwebui` |
| VMID | 311 |
| Node | `tappaas2` |
| Network zone | `srv` (VLAN 210) |
| Proxy domain | `openwebui.test.tapaas.org` |
| Proxy port | 8080 |
| CPU | 2 cores |
| Memory | 4096 MB |
| Disk | 32 GB |

## Module Files

| File | Purpose |
|------|---------|
| `openwebui.json` | Module configuration (VM specs, dependencies, network) |
| `openwebui.nix` | NixOS configuration (services, backups, users, container) |
| `install.sh` | Initial module installation (called by `tappaas-cicd`) |
| `update.sh` | Post-rebuild steps: health checks, container image prune |
| `test.sh` | Health and regression checks (SSH, container, HTTP, PostgreSQL, Redis) |
| `restore.sh` | Application data restore from another instance or backup files |
| `BACKLOG.md` | Product backlog and sprint tracking |
| `RESTORE.md` | Restore documentation for automated and manual procedures |

## Automated Backups

Four backup services run daily via systemd timers:

| Component | File pattern | Schedule | Directory |
|-----------|-------------|----------|-----------|
| PostgreSQL | `openwebui-pg-YYYY-MM-DD.sql.gz` | 02:00 | `/var/backup/postgresql/` |
| Redis | `openwebui-redis-YYYY-MM-DD.rdb` | 02:30 | `/var/backup/redis/` |
| Container data | `openwebui-data-YYYY-MM-DD.tar.gz` | 02:45 | `/var/backup/openwebui-data/` |
| Env secrets | `openwebui-env-YYYY-MM-DD.tar.gz` | 02:50 | `/var/backup/openwebui-env/` |

Retention: 30 days (automatic cleanup via monthly timer).

## Restore

Restore application data from another TAPPaaS instance or from manual backup files:

```bash
# From another TAPPaaS instance
./restore.sh --from-instance 192.168.2.235 --date 2026-03-09

# From local backup files
./restore.sh --from-path /tmp/openwebui-backups/
```

See [RESTORE.md](RESTORE.md) for full documentation, including manual backup creation from non-TAPPaaS sources.

## Deployment

### Install

```bash
install-module.sh openwebui
```

### Update

```bash
update-module.sh openwebui
```

This runs `nixos-rebuild switch` on the target, reboots if needed, then executes `update.sh` which:
1. Runs health checks via `test.sh`
2. Prunes unused container images (only if health checks pass)

### Health Check

```bash
cd ~/TAPPaaS/src/apps/openwebui
./test.sh openwebui
```

Validates:
1. SSH connectivity to `openwebui.srv.internal`
2. OpenWebUI container is running (Podman)
3. HTTP endpoint responding on port 8080
4. PostgreSQL accepting connections
5. Redis responding to ping

### Version Upgrade

Edit the version in `openwebui.nix`:

```nix
versions = {
    openwebui = "v0.8.9";  # Change version here
};
```

Then run `update-module.sh openwebui`. The update flow handles the rebuild, reboot, health check, and old image cleanup automatically.

## Dependencies

Defined in `openwebui.json`:

| Dependency | Purpose |
|------------|---------|
| `cluster:vm` | Proxmox VM provisioning |
| `templates:nixos` | NixOS template and `nixos-rebuild switch` |
| `backup:vm` | Proxmox Backup Server integration |
| `identity:identity` | Secrets and identity management |
| `firewall:proxy` | HAProxy and firewall rules |
| `litellm:models` | LLM model routing (cross-VLAN) |

## NixOS Services

| Service | systemd unit |
|---------|-------------|
| PostgreSQL | `postgresql.service` |
| Redis | `redis-openwebui.service` |
| OpenWebUI container | `openwebui-wrapper.service` |
| PG backup | `postgresqlBackup.service` / `.timer` |
| Redis backup | `redis-backup.service` / `.timer` |
| Data backup | `openwebui-container-backup.service` / `.timer` |
| Env backup | `openwebui-env-backup.service` / `.timer` |
| Cleanup | `backup-cleanup.service` / `.timer` |

## Security Notes

- PostgreSQL uses trust authentication for localhost connections
- Secrets are stored in `/etc/secrets/` (managed by the identity module)
- Network isolation via VLAN 210 (srv zone)
- HAProxy terminates TLS; internal traffic is HTTP on port 8080
- `nix.settings.trusted-users` includes `@wheel` for remote `nixos-rebuild`

## Resource Usage

| Component | Memory | Notes |
|-----------|--------|-------|
| OpenWebUI | ~800 MB | Varies with concurrent users |
| PostgreSQL | ~60 MB | Grows with chat history |
| Redis | ~12 MB | Session and cache data |
| **Total** | **~900 MB** | Idle baseline |
