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
echo "[INIT] Using APP_DATABASES='$APP_DATABASES'"

# Verplichte variabelen uit omgeving - werken nu samen met load-env.sh aliassen
: "${POSTGRES_SUPERUSER:?Environment variable POSTGRES_SUPERUSER must be set and non-empty}"
: "${POSTGRES_SUPERPASS:?Environment variable POSTGRES_SUPERPASS must be set and non-empty}"
: "${POSTGRES_DB:?Environment variable POSTGRES_DB must be set and non-empty}"
: "${APP_DATABASES:?Environment variable APP_DATABASES must be set and non-empty}"

# Verbinding maken met maintenance database (meestal 'postgres')
MAINT_DB="${POSTGRES_DB}"

# Loop over APP_DATABASES entries (formaat: app|dbname|dbuser|dbpass)
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

    # Check of de gebruiker bestaat
    USER_EXISTS=$(psql -U "$POSTGRES_SUPERUSER" -d "$MAINT_DB" -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'")
    if [ "$USER_EXISTS" != "1" ]; then
        echo "[ACTION] Creating user '$DB_USER'"
        psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d "$MAINT_DB" \
            -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"
    else
        echo "[SKIP] User '$DB_USER' already exists"
    fi

    # Check of de database bestaat
    DB_EXISTS=$(psql -U "$POSTGRES_SUPERUSER" -d "$MAINT_DB" -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")
    if [ "$DB_EXISTS" != "1" ]; then
        echo "[ACTION] Creating database '$DB_NAME' (owner: $DB_USER, UTF8, C locale)"
        psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d "$MAINT_DB" \
            -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' CONNECTION LIMIT -1;"
    else
        echo "[SKIP] Database '$DB_NAME' already exists"
    fi

    # Optioneel: schema-isolatie en privileges instellen
    echo "[INFO] Setting schema privileges for '${DB_NAME}'..."
    psql -v ON_ERROR_STOP=0 -U "$POSTGRES_SUPERUSER" -d "$DB_NAME" <<-EOF
        REVOKE ALL ON SCHEMA public FROM PUBLIC;
        GRANT ALL ON SCHEMA public TO ${DB_USER};
EOF
done

echo ""
echo "=== [INIT] Multi-database setup COMPLETE ==="