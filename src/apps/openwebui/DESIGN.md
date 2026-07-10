# OpenWebUI — Design notes

Implementation and operations detail that does not belong in the service-catalog
README or the install guide.

## Architecture

- OpenWebUI runs as a Podman container (image from Docker Hub, version pinned
  in `openwebui.nix`).
- PostgreSQL 17 (user accounts, chat history, settings, prompts) and Redis
  (session state, cache, WebSocket streaming) run natively on the NixOS VM.
- Redis uses AOF persistence — data survives container restarts.
- Secrets are auto-generated on first boot (no placeholder values).
- Service port: 8080. Exposed to the `home` zone through `network:proxy`
  (`proxyAllowedZones: ["home"]` in `openwebui.json`).

## Backup strategy

Daily automated backups, 30-day retention (7-day rotation per backup job):

| Component | Time | Location |
|-----------|------|----------|
| PostgreSQL | 02:00 | `/var/backup/postgresql/` |
| Redis | 02:30 | `/var/backup/redis/` |
| Container data | 02:45 | `/var/backup/openwebui-data/` |
| Secrets | 02:50 | `/var/backup/openwebui-env/` |

The container-data backup excludes `cache/` (embedding models are
regeneratable, not user data). Restore procedures — including automated
TAPPaaS-to-TAPPaaS restore via `restore.sh` — are in [RESTORE.md](./RESTORE.md).

## Related documents

- [ADMIN.md](./ADMIN.md) — operational runbook: health checks, layered
  troubleshooting (infrastructure and application), maintenance.
- [UPGRADE.md](./UPGRADE.md) — version-specific upgrade notes, including the
  automated PostgreSQL 15 → 17 data migration in `update.sh`.
- [RESTORE.md](./RESTORE.md) — application data restore and migration from
  non-TAPPaaS installs.
