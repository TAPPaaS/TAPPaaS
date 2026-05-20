# OpenWebUI — Upgrade Guide

## Upgrading to v0.9.5

### What is new

- OpenWebUI updated from 0.8.10 to 0.9.5
- Container image moved from GHCR to Docker Hub
- PostgreSQL updated from version 15 to 17
- Redis AOF persistence enabled (data survives container restarts)
- Secrets are now auto-generated on first boot (no more placeholder values)
- 7-day backup rotation per backup job

---

### PostgreSQL version upgrade — data migration

When upgrading from a version that used PostgreSQL 15 to one that uses PostgreSQL 17, NixOS initialises a fresh PostgreSQL 17 data directory. **Your existing data (users, chats, settings) lives in the old PostgreSQL 15 directory and must be migrated.**

**This is handled automatically by `update.sh`** since v0.9.5.

`update.sh` runs after `nixos-rebuild switch` and:
1. Detects if an older PostgreSQL data directory exists (`/var/lib/postgresql/15/`)
2. Checks if the new PostgreSQL 17 database is empty
3. If yes: starts a temporary PostgreSQL 15 instance from the old data directory, dumps the live data, and restores it into PostgreSQL 17

The old data directory is kept on disk until you remove it manually.

If you are running `update-os.sh` directly (bypassing `update-module.sh`), run `update.sh` manually afterwards:

```bash
cd TAPPaaS/src/apps/openwebui
./update.sh openwebui
```

---

### Provider credentials

OpenWebUI stores provider API keys (OpenAI, Anthropic, etc.) in the database and in the UI settings. These survive the upgrade as part of the PostgreSQL migration.

---

### Verify after upgrade

```bash
cd TAPPaaS/src/apps/openwebui
./test.sh
```
