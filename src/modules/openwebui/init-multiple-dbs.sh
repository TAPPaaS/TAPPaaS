#!/bin/bash
# ============================================================================
# PostgreSQL Multi-Database Initialization Script
# Creates multiple databases and users for the AI platform
# ============================================================================

set -e
set -u

function create_user_and_database() {
    local database=$1
    local user=$2
    local password=$3
    
    echo "Creating user '$user' and database '$database'"
    
    # Create user if it doesn't exist
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$user') THEN
                CREATE USER $user WITH PASSWORD '$password';
            END IF;
        END
        \$\$;
EOSQL

    # Create database if it doesn't exist
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        SELECT 'CREATE DATABASE $database OWNER $user'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$database')\gexec
EOSQL

    # Grant all privileges on database to user
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        GRANT ALL PRIVILEGES ON DATABASE $database TO $user;
EOSQL

    echo "User '$user' and database '$database' created successfully"
}

if [ -n "${POSTGRES_DB_N8N:-}" ] && [ -n "${POSTGRES_USER_N8N:-}" ] && [ -n "${POSTGRES_PASSWORD_N8N:-}" ]; then
    create_user_and_database "$POSTGRES_DB_N8N" "$POSTGRES_USER_N8N" "$POSTGRES_PASSWORD_N8N"
fi

if [ -n "${POSTGRES_DB_LLM:-}" ] && [ -n "${POSTGRES_USER_LLM:-}" ] && [ -n "${POSTGRES_PASSWORD_LLM:-}" ]; then
    create_user_and_database "$POSTGRES_DB_LLM" "$POSTGRES_USER_LLM" "$POSTGRES_PASSWORD_LLM"
fi

echo "Database initialization completed"