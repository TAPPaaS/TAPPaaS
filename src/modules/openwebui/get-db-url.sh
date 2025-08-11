# ============================================================================
# File: get-db-url.sh
# Project: Local AI Platform (OpenWebUI, Searxng, LiteLLM, Postgres)
# script to generate the database URL for application: LiteLLM
# based on the APP_DATABASES environment variable

#!/bin/sh
set -e

# Find first entry for 'litellm'
ENTRY=$(echo "$APP_DATABASES" | tr ',' '\n' | grep '^litellm|' | xargs)

if [ -z "$ENTRY" ]; then
    echo "Error: No APP_DATABASES entry found for 'litellm'." >&2
    exit 1
fi

IFS='|' read -r APP DB USER PASS <<EOF
$ENTRY
EOF

# Trim whitespace from each variable
APP=$(echo "$APP" | xargs)
DB=$(echo "$DB" | xargs)
USER=$(echo "$USER" | xargs)
PASS=$(echo "$PASS" | xargs)

# Default host/port if not set
POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"

# Output the cleaned Database URL (no extra spaces!)
echo "postgresql://${USER}:${PASS}@${POSTGRES_HOST}:${POSTGRES_PORT}/${DB}"