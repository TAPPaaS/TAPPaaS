# tappaas/src/modules/openwebui/init-multiple-dbs.sh
# Author: TAPpaas Team / Erik Daniel 
# Date: 2025-08-11
# Description: Securely initialize multiple databases for TAPpaas applications
#
# !/bin/bash
# 
# Create app-specific roles and schemas with limited permissions
# 1. Schema Isolation: Each app gets its own schema
# 2. Least Privilege: Only necessary permissions are granted
# 3. Role Hierarchy: Uses group roles for easier management
# 4. Public Schema Protection: Revokes default public permissions
# 5. Future-Proof: Easy to add more apps with proper isolation
# 
# Benefits:
# - Each app can only access its own schema
# - Easier to add more applications later
# - Better security through isolation
# - Clear separation of responsibilities
# - Easier to audit permissions


set -e
set -u

function create_secure_database() {
    local database=$1
    local app_user=$2
    local app_password=$3
    
    echo "Setting up secure database for '$database'"
    
    # Create read-only group role
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_SUPERUSER" <<-EOSQL
        -- Create group role for read-only access
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${database}_readonly') THEN
                CREATE ROLE ${database}_readonly;
            END IF;
        END
        \$\$;

        -- Create app user with specific permissions
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$app_user') THEN
                CREATE USER $app_user WITH PASSWORD '$app_password';
                GRANT ${database}_readonly TO $app_user;
            END IF;
        END
        \$\$;

        -- Create database and schema
        SELECT 'CREATE DATABASE $database'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$database')\gexec
EOSQL

    # Set up schema and permissions
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_SUPERUSER" -d "$database" <<-EOSQL
        -- Create app-specific schema
        CREATE SCHEMA IF NOT EXISTS ${app_user}_schema;
        
        -- Revoke public schema usage
        REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
        REVOKE ALL ON SCHEMA public FROM PUBLIC;
        
        -- Grant specific permissions
        GRANT USAGE ON SCHEMA ${app_user}_schema TO $app_user;
        GRANT CREATE ON SCHEMA ${app_user}_schema TO $app_user;
        ALTER DEFAULT PRIVILEGES IN SCHEMA ${app_user}_schema 
            GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $app_user;
        ALTER DEFAULT PRIVILEGES IN SCHEMA ${app_user}_schema 
            GRANT SELECT, USAGE ON SEQUENCES TO $app_user;
EOSQL

    echo "Secure setup completed for '$database'"
}

# Create LiteLLM database with secure setup
if [ -n "${POSTGRES_DB_LLM:-}" ] && [ -n "${POSTGRES_USER_LLM:-}" ] && [ -n "${POSTGRES_PASSWORD_LLM:-}" ]; then
    create_secure_database "$POSTGRES_DB_LLM" "$POSTGRES_USER_LLM" "$POSTGRES_PASSWORD_LLM"
fi