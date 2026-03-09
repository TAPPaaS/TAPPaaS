# OpenWebUI Application Data Restore

Restore OpenWebUI application data (users, chats, settings, models, secrets) onto a TAPPaaS instance.

## What Gets Restored

| Component | Backup file | Contains |
|-----------|-------------|----------|
| PostgreSQL | `openwebui-pg-YYYY-MM-DD.sql.gz` | User accounts, chat history, settings, prompts |
| Redis | `openwebui-redis-YYYY-MM-DD.rdb` | Session state, cache |
| Container data | `openwebui-data-YYYY-MM-DD.tar.gz` | Uploaded files, downloaded models |
| Env secrets | `openwebui-env-YYYY-MM-DD.tar.gz` | API keys, OIDC configuration, secrets |

## Automated Restore (TAPPaaS to TAPPaaS)

When both the source and target are TAPPaaS OpenWebUI instances, backups are already in place. One command:

```bash
# Use the latest backups from the source instance
./restore.sh --from-instance openwebui-old.srv.internal

# Use backups from a specific date
./restore.sh --from-instance openwebui-old.srv.internal --date 2026-03-09

# Use an IP address instead of a hostname
./restore.sh --from-instance 192.168.2.235 --date 2026-03-09
```

The script performs the following steps:
1. Connects to the source instance via SSH and fetches all 4 backup files
2. Stops the OpenWebUI container on the target
3. Terminates active PostgreSQL connections and restores the database
4. Stops Redis, restores the RDB snapshot, and restarts it
5. Extracts container data (uploads, models) and environment secrets
6. Starts the OpenWebUI container
7. Runs health checks to verify the restore succeeded

### Prerequisites

- SSH access from `tappaas-cicd` to the source instance (as user `tappaas` with sudo)
- The target VM must already be installed via `install.sh` (services running, database initialised)
- The module configuration must exist in `/home/tappaas/config/openwebui.json`

## Restore from Local Backup Files

If you already have the backup files available locally (from any source):

```bash
./restore.sh --from-path /path/to/backup/files/
```

The directory must contain all 4 files matching these patterns:
- `openwebui-pg-*.sql.gz`
- `openwebui-redis-*.rdb`
- `openwebui-data-*.tar.gz`
- `openwebui-env-*.tar.gz`

## Manual Backup Creation (Non-TAPPaaS Source)

If you are migrating from a standalone OpenWebUI installation (not managed by TAPPaaS), you need to create the 4 backup files manually on the source machine, then use `restore.sh --from-path` to import them.

### 1. PostgreSQL

Identify your database name and user from your OpenWebUI configuration, then run:

```bash
pg_dump -U openwebui openwebui | gzip > openwebui-pg-$(date +%F).sql.gz
```

If PostgreSQL is running inside a Docker container:
```bash
docker exec openwebui-db pg_dump -U openwebui openwebui \
    | gzip > openwebui-pg-$(date +%F).sql.gz
```

### 2. Redis

```bash
redis-cli --rdb openwebui-redis-$(date +%F).rdb
```

If Redis is running inside a Docker container:
```bash
docker exec openwebui-redis redis-cli --rdb /tmp/dump.rdb
docker cp openwebui-redis:/tmp/dump.rdb openwebui-redis-$(date +%F).rdb
```

If your OpenWebUI installation does not use Redis, create an empty placeholder file:
```bash
touch openwebui-redis-$(date +%F).rdb
```

### 3. Container Data (Uploads, Models)

The data directory location depends on your setup. Common paths:
- **Docker volume**: `/var/lib/docker/volumes/openwebui_data/_data`
- **Docker Compose bind mount**: check the `volumes:` section in your `docker-compose.yml`
- **Podman (TAPPaaS)**: `/var/lib/openwebui/data` and `/var/lib/openwebui/models`

```bash
tar -czf openwebui-data-$(date +%F).tar.gz \
    -C / var/lib/openwebui/data var/lib/openwebui/models
```

For Docker Compose setups, first identify your volume paths:
```bash
docker inspect openwebui | grep -A5 Mounts
```

Then create the archive. The paths inside the tar **must** be relative to `/` and match the TAPPaaS target layout:

```
var/lib/openwebui/data/...
var/lib/openwebui/models/...
```

If your source uses different paths, restructure them before creating the archive:
```bash
mkdir -p /tmp/openwebui-export/var/lib/openwebui
cp -a /your/source/data /tmp/openwebui-export/var/lib/openwebui/data
cp -a /your/source/models /tmp/openwebui-export/var/lib/openwebui/models
tar -czf openwebui-data-$(date +%F).tar.gz -C /tmp/openwebui-export var/lib/openwebui/data var/lib/openwebui/models
rm -rf /tmp/openwebui-export
```

### 4. Environment Secrets

TAPPaaS stores environment secrets in `/etc/secrets/`. The expected files are:
- `openwebui.env` — OpenWebUI environment variables (API keys, OIDC settings)
- `postgres.env` — PostgreSQL credentials
- `redis.env` — Redis configuration

```bash
tar -czf openwebui-env-$(date +%F).tar.gz -C / etc/secrets
```

For Docker setups, the equivalent is typically your `.env` file. Map it to the TAPPaaS layout:
```bash
mkdir -p /tmp/openwebui-export/etc/secrets
cp .env /tmp/openwebui-export/etc/secrets/openwebui.env
tar -czf openwebui-env-$(date +%F).tar.gz -C /tmp/openwebui-export etc/secrets
rm -rf /tmp/openwebui-export
```

### 5. Transfer and Restore

Copy all 4 files to the TAPPaaS `tappaas-cicd` host and run the restore:

```bash
# From the source machine
scp openwebui-pg-*.sql.gz \
    openwebui-redis-*.rdb \
    openwebui-data-*.tar.gz \
    openwebui-env-*.tar.gz \
    tappaas@tappaas-cicd:/tmp/openwebui-backups/

# On the tappaas-cicd host
ssh tappaas@tappaas-cicd
cd ~/TAPPaaS/src/apps/openwebui
./restore.sh --from-path /tmp/openwebui-backups/
```

## Backup File Locations on a TAPPaaS Instance

The automated backup services store files in these directories on the OpenWebUI VM:

| Component | Directory | Service | Schedule |
|-----------|-----------|---------|----------|
| PostgreSQL | `/var/backup/postgresql/` | `postgresqlBackup.timer` | Daily 02:00 |
| Redis | `/var/backup/redis/` | `redis-backup.timer` | Daily 02:30 |
| Container data | `/var/backup/openwebui-data/` | `openwebui-container-backup.timer` | Daily 02:45 |
| Env secrets | `/var/backup/openwebui-env/` | `openwebui-env-backup.timer` | Daily 02:50 |

## Troubleshooting

### Health checks fail after restore

```bash
# Check if the container is running
ssh tappaas@openwebui.srv.internal "sudo podman ps"

# Check container logs for errors
ssh tappaas@openwebui.srv.internal "sudo podman logs openwebui --tail 50"

# Verify PostgreSQL is accepting connections
ssh tappaas@openwebui.srv.internal "pg_isready -h 127.0.0.1 -p 5432 -U openwebui"

# Verify Redis is responding
ssh tappaas@openwebui.srv.internal "redis-cli -h 127.0.0.1 -p 6379 ping"
```

### PostgreSQL restore fails with "database is being accessed"

The restore script terminates active connections automatically. If it still fails, stop the container first:
```bash
ssh tappaas@openwebui.srv.internal "sudo podman stop openwebui"
```

Then check for remaining sessions:
```bash
ssh tappaas@openwebui.srv.internal \
    "sudo -u postgres psql -c \"SELECT pid, usename, application_name FROM pg_stat_activity WHERE datname='openwebui';\""
```

### Schema mismatch errors during PostgreSQL restore

If the source and target run different OpenWebUI versions, the database schema may differ. The restore drops and recreates the database, so this should not be an issue. If you see `relation already exists` errors, verify that the `dropdb` step succeeded.

### Container data paths do not match

The tar archive must contain paths relative to `/`:
```bash
# Verify the archive structure
tar -tzf openwebui-data-*.tar.gz | head
# Expected output:
# var/lib/openwebui/data/...
# var/lib/openwebui/models/...
```

### Permission issues after restore

The TAPPaaS NixOS configuration declares the following ownership:
- Container data: `svc_openwebui_admin:svc_openwebui`
- PostgreSQL data: `postgres:postgres`
- Redis data: `redis:redis`
- Environment secrets: `root:root`

If you restored from a non-TAPPaaS source, ownership may need to be corrected:
```bash
ssh tappaas@openwebui.srv.internal "
    sudo chown -R svc_openwebui_admin:svc_openwebui /var/lib/openwebui/data /var/lib/openwebui/models
    sudo chown redis:redis /var/lib/redis-openwebui/dump.rdb
"
```

### Redis service name

On TAPPaaS NixOS, the Redis service is named `redis-openwebui` (not `redis`). The data directory is `/var/lib/redis-openwebui/`.

```bash
# Check Redis service status
ssh tappaas@openwebui.srv.internal "systemctl status redis-openwebui"

# Restart Redis
ssh tappaas@openwebui.srv.internal "sudo systemctl restart redis-openwebui"
```
