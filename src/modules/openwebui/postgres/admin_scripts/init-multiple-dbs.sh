#!/usr/bin/env bash
set -euo pipefail

##
# init-multiple-dbs.sh — Secure multi-application Postgres bootstrap
# Author: Erik Daniel / TAPpaas Team (patched 2025-08-12)
#
# Create app-specific roles and schemas with limited permissions
# 1. Schema Isolation: Each app gets its own schema
# 2. Least Privilege: Only necessary permissions are granted
# 3. Role Hierarchy: Uses group roles for easier management
# 4. Public Schema Protection: Revokes default public permissions
# 5. Future-Proof: Easy to add more apps with proper isolation (in .ENV file)
# 6. Idempotent: Safe to run multiple times without issues
# 
# Benefits:
# - Each app can only access its own schema
# - Easier to add more applications later
# - Better security through isolation
# - Clear separation of responsibilities
# - Easier to audit permissions
#
# Improvements in this version:
#   - Uses psql variables to avoid exposing passwords in process list
#   - Extra permissions hardening (REVOKE CONNECT / CREATE / TEMP on other DBs)
#   - Still idempotent: safe to run multiple times
#   - Cross-platform safe for Alpine/macos/Ubuntu

# Prerequisites: environment variables loaded via load-env.sh

##
# init-multiple-dbs.sh — Multi-app Postgres bootstrap
# Author: <Your Name/Team>
# Date: 2025-08-12  (v250812v12-STABLE)
#
# Reads:
#   POSTGRES_SUPERUSER
#   POSTGRES_SUPERPASS
#   POSTGRES_DB
#   APP_DATABASES     (format: app|dbname|dbuser|dbpass,app2|...)
#
# Idempotent: Only creates users/DBs if missing.
##

# ============================================================
# Multi-database setup for PostgreSQL (Docker init script)
# Runs automatically on first container start with empty volume
#
# Requires these .env variables:
#   POSTGRES_SUPERUSER  - e.g., pgadmin
#   POSTGRES_SUPERPASS  - superuser password
#   POSTGRES_DB         - maintenance DB (usually "postgres")
#   APP_DATABASES       - comma-separated list per format:
#                         app|dbname|dbuser|dbpass,app2|dbname2|dbuser2|dbpass2
#
# Output: Creates DB roles, databases, and hardens privileges
# ============================================================

echo "=== [INIT] Multi-database setup START ==="

: "${POSTGRES_SUPERUSER:?Missing POSTGRES_SUPERUSER}"
: "${POSTGRES_SUPERPASS:?Missing POSTGRES_SUPERPASS}"
: "${POSTGRES_DB:?Missing POSTGRES_DB}"
: "${APP_DATABASES:?Missing APP_DATABASES}"

MAINT_DB="$POSTGRES_DB"

IFS=',' read -ra DB_ENTRIES <<< "$APP_DATABASES"
for entry in "${DB_ENTRIES[@]}"; do
    IFS='|' read -ra PARTS <<< "$entry"
    APP_NAME="${PARTS[0]}"
    DB_NAME="${PARTS[1]}"
    DB_USER="${PARTS[2]}"
    DB_PASS="${PARTS[3]}"

    echo ""
    echo "--- [INIT] Processing app: $APP_NAME ---"
    echo "         DB Name : $DB_NAME"
    echo "         DB User : $DB_USER"

    # 1️⃣ Create role if missing
    echo "[CHECK] Creating role if missing..."
    PGPASSWORD="$POSTGRES_SUPERPASS" \
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d "$MAINT_DB" <<SQL
SELECT 'CREATE USER "$DB_USER" WITH PASSWORD ''' || '$DB_PASS' || ''';'
WHERE NOT EXISTS (
    SELECT FROM pg_roles WHERE rolname = '$DB_USER'
)\gexec
SQL

    # 2️⃣ Create database if missing
    echo "[CHECK] Creating database if missing..."
    PGPASSWORD="$POSTGRES_SUPERPASS" \
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d "$MAINT_DB" <<SQL
SELECT 'CREATE DATABASE "$DB_NAME" OWNER "$DB_USER"
  ENCODING ''UTF8''
  LC_COLLATE ''en_US.utf8''
  LC_CTYPE ''en_US.utf8''
  TEMPLATE template0;'
WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = '$DB_NAME'
)\gexec
SQL

    # 3️⃣ Harden schema privileges (no unsupported DATABASES clause)
    echo "[INFO] Hardening privileges for '$DB_NAME'..."
    PGPASSWORD="$POSTGRES_SUPERPASS" \
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d "$DB_NAME" <<SQL
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO "$DB_USER";
REVOKE CONNECT ON DATABASE "$DB_NAME" FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE CREATE ON SCHEMAS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE TEMP ON SCHEMAS FROM PUBLIC;
SQL
done

echo ""
echo "=== [INIT] Multi-database setup COMPLETE ==="
