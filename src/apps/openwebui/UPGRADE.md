# OpenWebUI — Upgrade Guide

## Upgrading to v0.10.2

### What is new

- OpenWebUI updated from 0.9.6 to 0.10.2
- Upstream 0.10.x reportedly introduces a database schema migration and
  changes the default tool-calling mode from Legacy to Native — **this could
  not be independently verified from the authoring session** (web-fetch tools
  returned internally inconsistent results for this repo in this environment).
  Validate both via the `--test` variant before any production rollout, and
  re-check the real upstream CHANGELOG at deploy time.
- No PostgreSQL major-version change required — already on PostgreSQL 17

---

### Validation path

This upgrade must be validated via a throwaway `--test` variant before any
production instance (`openwebui`, `openwebui-a3k`) is touched:

```bash
install-module.sh openwebui --variant test --zone0 srvWork
tappaas-module-manager.sh test --module <assigned-vmname> --deep
```

Confirm the container is running the `0.10.2` image tag and all 5 health
checks pass before considering a production upgrade of vm311/vm315.

---

### PostgreSQL version upgrade — data migration

Not applicable for this upgrade (already on PostgreSQL 17). See the `0.9.5`
section below for the historical 15→17 migration mechanism, which remains in
`update.sh` for reference.

---

### Verify after upgrade

```bash
cd TAPPaaS/src/apps/openwebui
./test.sh
```

---

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
