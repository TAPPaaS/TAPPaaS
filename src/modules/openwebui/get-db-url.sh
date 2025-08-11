# ============================================================================
# File: get-db-url.sh
# Project: Local AI Platform (OpenWebUI, Searxng, LiteLLM, Postgres)
# script to generate the database URL for application: LiteLLM
# based on the APP_DATABASES environment variable

#!/bin/sh
set -e

# Find first entry starting with 'litellm|', split by commas, trim each
ENTRY=$(echo "$APP_DATABASES" | tr ',' '\n' | grep '^litellm|' | xargs)

if [ -z "$ENTRY" ]; then
    echo "Error: No APP_DATABASES entry found for 'litellm'." >&2
    exit 1
fi

# Split and trim whitespace for each field
IFS='|' read -r APP DB USER PASS <<EOF
$ENTRY
EOF
APP=$(echo "$APP" | xargs)
DB=$(echo "$DB" | xargs)
USER=$(echo "$USER" | xargs)
PASS=$(echo "$PASS" | xargs)

# Defaults if empty
POSTGRES_HOST=$(echo "${POSTGRES_HOST:-postgres}" | xargs)
POSTGRES_PORT=$(echo "${POSTGRES_PORT:-5432}" | xargs)

# Output clean connection string
echo "postgresql://${USER}:${PASS}@${POSTGRES_HOST}:${POSTGRES_PORT}/${DB}"