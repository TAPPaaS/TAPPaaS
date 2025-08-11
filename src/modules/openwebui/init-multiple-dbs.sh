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


#!/bin/sh
set -euo pipefail

echo "=== [INIT] Multi-database setup START ==="

IFS=',' read -ra DB_PAIRS <<< "$APP_DATABASES"

for APP_ENTRY in "${DB_PAIRS[@]}"; do
    APP_ENTRY=$(echo "$APP_ENTRY" | xargs)  # trim whitespace
    [ -z "$APP_ENTRY" ] && continue        # skip lege regels

    IFS='|' read -ra FIELDS <<< "$APP_ENTRY"
    APP_NAME="${FIELDS[0]}"
    DB_NAME="${FIELDS[1]}"
    DB_USER="${FIELDS[2]}"
    DB_PASS="${FIELDS[3]}"

    echo "--- [INIT] $APP_NAME: DB=$DB_NAME, User=$DB_USER ---"

    # 1. Maak user aan indien niet bestaat
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d postgres <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
                RAISE NOTICE 'Creating user ${DB_USER}';
                CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
            ELSE
                RAISE NOTICE 'User ${DB_USER} already exists. Skipping.';
            END IF;
        END
        \$\$;
EOSQL

    # 2. Maak database indien niet bestaat
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d postgres <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}') THEN
                RAISE NOTICE 'Creating database ${DB_NAME}';
                CREATE DATABASE ${DB_NAME}
                    OWNER ${DB_USER}
                    TEMPLATE template0
                    ENCODING 'UTF8'
                    LC_COLLATE='C'
                    LC_CTYPE='C'
                    CONNECTION LIMIT -1;
            ELSE
                RAISE NOTICE 'Database ${DB_NAME} already exists. Skipping.';
            END IF;
        END
        \$\$;
EOSQL

    # 3. Schema-isolatie en permissies (idempotent)
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

    echo "--- [INIT] ${APP_NAME}: Setup complete ---"
done

echo "=== [INIT] Multi-database setup DONE ==="
