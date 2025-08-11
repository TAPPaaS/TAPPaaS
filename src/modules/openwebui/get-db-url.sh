# ============================================================================
# File: get-db-url.sh
# Project: Local AI Platform (OpenWebUI, Searxng, LiteLLM, Postgres)
# script to generate the database URL for application: LiteLLM
# based on the APP_DATABASES environment variable

#!/bin/sh
set -e

# Find first entry in APP_DATABASES starting with 'litellm|'
ENTRY=$(echo "$APP_DATABASES" | tr ',' '\n' | grep '^litellm|')
IFS='|' read -r APP DB USER PASS <<EOF
$ENTRY
EOF

# Generate Database URL
echo "postgresql://${USER}:${PASS}@${POSTGRES_HOST}:${POSTGRES_PORT}/${DB}"
