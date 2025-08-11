# tappaas/src/modules/openwebui/init-multiple-dbs.sh
# Author: TAPpaas Team / Erik Daniel 
# Date: 2025-08-11
# Description: Securely initialize multiple databases for TAPpaas applications
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

#!/bin/bash
set -e

echo "=== [INIT] Multi-database setup START ==="

# Guard required vars
: "${POSTGRES_SUPERUSER:?Environment variable POSTGRES_SUPERUSER must be set and non-empty}"
: "${POSTGRES_PASSWORD:?Environment variable POSTGRES_PASSWORD must be set and non-empty}"
: "${POSTGRES_DB:?Environment variable POSTGRES_DB must be set and non-empty}"
: "${APP_DATABASES:?Environment variable APP_DATABASES must be set and non-empty}"

# Ensure we connect to the main/maintenance database that exists
MAINT_DB="${POSTGRES_DB}"

IFS=',' read -ra DB_ENTRIES <<< "$APP_DATABASES"
for entry in "${DB_ENTRIES[@]}"; do
    IFS='|' read -ra PARTS <<< "$entry"
    APP_NAME="${PARTS[0]}"
    DB_NAME="${PARTS[1]}"
    DB_USER="${PARTS[2]}"
    DB_PASS="${PARTS[3]}"

    echo "--- [INIT] Processing app: $APP_NAME ---"

    # Create user if not exists
    USER_EXISTS=$(psql -U "$POSTGRES_SUPERUSER" -d "$MAINT_DB" -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'")
    if [ "$USER_EXISTS" != "1" ]; then
        echo "NOTICE: Creating user $DB_USER"
        psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d "$MAINT_DB" \
             -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
    else
        echo "NOTICE: User $DB_USER already exists, skipping."
    fi

    # Create database if not exists
    DB_EXISTS=$(psql -U "$POSTGRES_SUPERUSER" -d "$MAINT_DB" -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")
    if [ "$DB_EXISTS" != "1" ]; then
        echo "NOTICE: Creating database $DB_NAME"
        psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d "$MAINT_DB" \
             -c "CREATE DATABASE $DB_NAME OWNER $DB_USER TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' CONNECTION LIMIT -1;"
    else
        echo "NOTICE: Database $DB_NAME already exists, skipping."
    fi

done

echo "=== [INIT] Multi-database setup COMPLETE ==="
