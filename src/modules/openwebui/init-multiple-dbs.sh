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
# 
# Benefits:
# - Each app can only access its own schema
# - Easier to add more applications later
# - Better security through isolation
# - Clear separation of responsibilities
# - Easier to audit permissions


#!/bin/bash
set -euo pipefail

echo "=== Starting multi-database initialization ==="
IFS=',' read -ra APP_LIST <<< "$APP_DATABASES"

for APP_ENTRY in "${APP_LIST[@]}"; do
    IFS='|' read -ra APP <<< "$APP_ENTRY"
    APP_NAME="${APP[0]}"
    DB_NAME="${APP[1]}"
    DB_USER="${APP[2]}"
    DB_PASS="${APP[3]}"

    echo "--- Setting up DB: $DB_NAME for app: $APP_NAME ---"

    # Create DB, role, schema
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d postgres <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
                CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
            END IF;
        END
        \$\$;

        CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}
        TEMPLATE template0
        ENCODING 'UTF8'
        LC_COLLATE='en_US.utf8'
        LC_CTYPE='en_US.utf8'
        CONNECTION LIMIT -1;

EOSQL

    # Schema isolation & permissions
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d "$DB_NAME" <<-EOSQL
        CREATE SCHEMA IF NOT EXISTS ${APP_NAME}_schema AUTHORIZATION ${DB_USER};

        -- Restrict public schema
        REVOKE ALL ON SCHEMA public FROM PUBLIC;
        REVOKE ALL ON SCHEMA public FROM ${DB_USER};

        -- Grant rights in own schema
        GRANT USAGE, CREATE ON SCHEMA ${APP_NAME}_schema TO ${DB_USER};
        ALTER DEFAULT PRIVILEGES IN SCHEMA ${APP_NAME}_schema
            GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${DB_USER};
        ALTER DEFAULT PRIVILEGES IN SCHEMA ${APP_NAME}_schema
            GRANT USAGE, SELECT ON SEQUENCES TO ${DB_USER};
EOSQL

    echo "--- Finished setup for: $DB_NAME ---"
done

echo "=== All databases initialized successfully ==="
