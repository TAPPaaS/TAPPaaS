# ============================================================================
# File: get-db-url.sh
# Project: Local AI Platform (OpenWebUI, Searxng, LiteLLM, Postgres)
# script to generate the database URL for application: LiteLLM
# based on the APP_DATABASES environment variable

#!/bin/sh
set -e

# Find first entry in APP_DATABASES starting with 'litellm|'
ENTRY=$(echo "$APP_DATABASES" | tr ',' '\n' | grep '^litellm|' | xargs)

if [ -z "$ENTRY" ]; then
    echo "Error: No APP_DATABASES entry found for 'litellm'." >&2
    exit 1
fi

IFS='|' read -r APP DB USER PASS <<EOF
$ENTRY
EOF

# Trim each variable to strip internal padding
APP=$(echo "$APP" | xargs)
DB=$(echo "$DB" | xargs)
USER=$(echo "$USER" | xargs)
PASS=$(echo "$PASS" | xargs)

# Defaults if not set
POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"

# Output URL without extra spaces
echo "postgresql://${USER}:${PASS}@${POSTGRES_HOST}:${POSTGRES_PORT}/${DB}"