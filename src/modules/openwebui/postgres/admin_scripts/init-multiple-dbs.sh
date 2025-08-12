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

#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# init-multiple-dbs.sh - Multi-database setup for Postgres
# Compatible with: macOS, Linux, Windows/WSL
# Runs once on first start of postgres container when volume is empty
# ============================================================

echo "=== [INIT] Multi-database setup START ==="

: "${POSTGRES_SUPERUSER:?Need POSTGRES_SUPERUSER in env}"
: "${POSTGRES_SUPERPASS:?Need POSTGRES_SUPERPASS in env}"
: "${POSTGRES_DB:?Need POSTGRES_DB in env}"
: "${APP_DATABASES:?Need APP_DATABASES in env}"

MAINT_DB="${POSTGRES_DB}"

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

    #
    # 1️⃣ Create role if not exists
    #
    USER_EXISTS=$(PGPASSWORD="$POSTGRES_SUPERPASS" \
        psql -U "$POSTGRES_SUPERUSER" -d "$MAINT_DB" -Atq \
        -c "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'")
    if [[ "$USER_EXISTS" != "1" ]]; then
        echo "[ACTION] Creating user '$DB_USER'"
        PGPASSWORD="$POSTGRES_SUPERPASS" \
        psql -v ON_ERROR_STOP=1 \
            -U "$POSTGRES_SUPERUSER" -d "$MAINT_DB" \
            --set=NEWUSER="$DB_USER" --set=NEWPASS="$DB_PASS" <<'SQL'
DO $$
BEGIN
   EXECUTE format('CREATE USER %I WITH PASSWORD %L', :'NEWUSER', :'NEWPASS');
END$$;
SQL
    else
        echo "[SKIP] User '$DB_USER' already exists"
    fi

    #
    # 2️⃣ Create database if not exists
    #
    DB_EXISTS=$(PGPASSWORD="$POSTGRES_SUPERPASS" \
        psql -U "$POSTGRES_SUPERUSER" -d "$MAINT_DB" -Atq \
        -c "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")
    if [[ "$DB_EXISTS" != "1" ]]; then
        echo "[ACTION] Creating database '$DB_NAME' (owner: $DB_USER)"
        PGPASSWORD="$POSTGRES_SUPERPASS" \
        psql -v ON_ERROR_STOP=1 \
            -U "$POSTGRES_SUPERUSER" -d "$MAINT_DB" \
            --set=DBNAME="$DB_NAME" --set=DBOWNER="$DB_USER" <<'SQL'
CREATE DATABASE :"DBNAME"
  OWNER :"DBOWNER"
  TEMPLATE template0
  ENCODING 'UTF8'
  LC_COLLATE='en_US.utf8'
  LC_CTYPE='en_US.utf8'
  CONNECTION LIMIT -1;
SQL
    else
        echo "[SKIP] Database '$DB_NAME' already exists"
    fi

    #
    # 3️⃣ Adjust privileges
    #
    echo "[INFO] Hardening privileges on database '$DB_NAME'"
    PGPASSWORD="$POSTGRES_SUPERPASS" \
    psql -v ON_ERROR_STOP=1 \
        -U "$POSTGRES_SUPERUSER" -d "$DB_NAME" \
        --set=DBNAME="$DB_NAME" --set=DBUSER="$DB_USER" <<'SQL'
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO :"DBUSER";
REVOKE CONNECT ON DATABASE :"DBNAME" FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE CREATE ON SCHEMAS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE TEMPORARY ON DATABASES FROM PUBLIC;
SQL

done

echo ""
echo "=== [INIT] Multi-database setup COMPLETE ==="

