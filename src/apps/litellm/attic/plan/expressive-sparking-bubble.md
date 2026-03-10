# Plan: LiteLLM Module Operational Maturity

## Context

The OpenWebUI module was recently brought to production-grade with: consistent backup naming, restore.sh, RESTORE.md, proper update.sh, and version sync. The LiteLLM module needs the same treatment. The user wants a prioritized BACKLOG.md stored in the repo folder.

**Key difference from OpenWebUI:** LiteLLM has no container data volumes — all persistent data lives in PostgreSQL, Redis, and config files (`/etc/secrets/`, `/etc/litellm/`). So only **3 backup layers** are needed (not 4 like OpenWebUI).

## Files to Modify/Create

| File | Action | Story |
|------|--------|-------|
| `litellm.nix` | Edit backup sections (lines 368-438) | LLM-001 |
| `restore.sh` | Create new | LLM-002 |
| `RESTORE.md` | Create new | LLM-003 |
| `update.sh` | Rewrite (currently a stub) | LLM-004 |
| `README.md` | Fix version + inaccuracies | LLM-005 |
| `BACKLOG.md` | Create new (captures all stories + attic/review.md phases) | LLM-006 |

All paths relative to `/home/tappaas/TAPPaaS/src/apps/litellm/`

## Implementation Order

### 1. LLM-001: Fix backup naming in litellm.nix (P1)

**Problem:** Backup filenames don't follow TAPPaaS convention `<module>-<type>-YYYY-MM-DD.<ext>`

**Changes to `litellm.nix`:**

| Current | Target |
|---------|--------|
| `services.postgresqlBackup` (NixOS default, produces `litellm.sql.gz` with NO date) | Custom `systemd.services.postgresqlBackup` using `pg_dump \| gzip > litellm-pg-$(date +%F).sql.gz` |
| `dump-$(date +%Y%m%d_%H%M%S).rdb` | `litellm-redis-$(date +%F).rdb` |
| `litellm-env-$(date +%F).tar.gz` | Keep (already compliant) |

- Replace `services.postgresqlBackup` block (lines 369-375) with custom oneshot service + timer matching openwebui.nix pattern (lines 255-273)
- Fix Redis backup filename (line 388)
- Add explicit `${pkgs.coreutils}/bin/date` in env backup (line 411) for NixOS PATH safety

**Reference:** openwebui.nix lines 255-366 for backup service pattern

### 2. LLM-004: Rewrite update.sh (P1, parallel with LLM-001)

**Problem:** Current file is a stub that only prints config values. No health checks, no image prune.

**Rewrite** following openwebui `update.sh` pattern:
1. Source common-install-routines.sh
2. Run `test.sh` as quality gate
3. On success: `podman image prune -a -f`
4. On failure: exit 1, preserve old images for rollback

**Reference:** `/home/tappaas/TAPPaaS/src/apps/openwebui/update.sh`

### 3. LLM-002: Create restore.sh (P1, depends on LLM-001)

**Create** following openwebui `restore.sh` pattern, adapted for LiteLLM:

- Two modes: `--from-instance <host>` and `--from-path <dir>`
- Pre-load `litellm.json` before sourcing common-install-routines.sh
- 3-component restore: PostgreSQL → Redis → Env/Config
- LiteLLM-specific: container=`litellm`, db=`litellm`, redis=`redis-litellm`, data at `/var/lib/redis-litellm/`, port 4000
- Health check via `test.sh` after restore

**Reference:** `/home/tappaas/TAPPaaS/src/apps/openwebui/restore.sh`

### 4. LLM-003: Create RESTORE.md (P1, depends on LLM-002)

**Create** following openwebui `RESTORE.md` structure:
- What Gets Restored table (3 components)
- Automated restore (TAPPaaS-to-TAPPaaS)
- Local backup files restore
- Manual backup creation (non-TAPPaaS sources)
- Troubleshooting (redis-litellm service name, permissions, etc.)

**Reference:** `/home/tappaas/TAPPaaS/src/apps/openwebui/RESTORE.md`

### 5. LLM-005: Fix README.md (P2)

**Issues found:**
- Line 246: Version says `v1.81.3.rc.2` → should be `v1.81.14`
- Line 44: "Current Configuration (8GB VM)" → JSON says 4096 MB (4GB)
- Line 46: "2GB shared_buffers" → nix says "1GB"
- Line 48: "1GB maxmemory" → nix says "512mb"
- Line 112: "WAL archives" → WAL archiving is disabled (removed in v0.9.1)
- Line 257: Stray closing ``` at end of file
- Lines 225-238: Manual restore commands → replace with reference to restore.sh and RESTORE.md
- Missing: module file table, deployment commands, version upgrade instructions
- Add `/var/backup/litellm-data/` to file structure (if we add data layer) — actually NOT needed since we keep 3 layers

### 6. LLM-006: Create BACKLOG.md (P2, depends on all above)

**Create** capturing:
- Completed stories from this sprint (LLM-001 through LLM-005)
- Phase 2 items from `attic/review.md`: resource limits, health checks in systemd, PostgreSQL tuning
- Phase 3 items: replace `--network=host`, integrate 40-Identity, implement scram-sha-256 auth
- services/models/ implementation stubs

## Verification

After implementation:
1. `bash -n restore.sh && bash -n update.sh` — syntax check
2. Run bash-script-validator on restore.sh and update.sh
3. `update-module.sh litellm` — deploys nix changes, runs update.sh (health checks + prune)
4. SSH to litellm VM, manually trigger each backup, verify naming:
   - `sudo systemctl start postgresqlBackup && ls /var/backup/postgresql/`
   - `sudo systemctl start redis-backup && ls /var/backup/redis/`
   - `sudo systemctl start litellm-env-backup && ls /var/backup/litellm-env/`
5. Test restore.sh `--help` for usage output
6. Full restore test if a second instance is available
