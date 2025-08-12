#!/usr/bin/env bash
set -euo pipefail

##
# load-env.sh — Robust and portable environment loader
# - Loads variables from .env, ignoring comments/empty lines
# - Validates keys before export (avoids accidental shell expansion)
# - Populates derived vars consistently for Docker Compose and init scripts
# - Preserves comments and order in .env when updating derived vars
# - Cross-platform safe: works on macOS, Linux, WSL
##

ENV_FILE="${1:-.env}"
TMP_ENV=".env.tmp"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] Env file '$ENV_FILE' not found." >&2
  exit 1
fi

# 1️⃣ Load .env variables into current shell
while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip comments and blank lines
  [[ -z "$line" || "$line" =~ ^\s*# ]] && continue
  # Remove any inline comment starting with #
  clean_line="${line%% #*}"
  clean_line="$(echo "$clean_line" | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//')"
  # Validate KEY=VALUE format
  if [[ "$clean_line" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
    export "$clean_line"
  fi
done < "$ENV_FILE"

# 2️⃣ Ensure Postgres vars are aligned with base superuser vars
export POSTGRES_USER="${POSTGRES_SUPERUSER}"
export POSTGRES_PASSWORD="${POSTGRES_SUPERPASS}"

# 3️⃣ Build composite APP_DATABASES string dynamically
export APP_DATABASES="litellm|${LITELLM_DB_NAME}|${LITELLM_DB_USER}|${LITELLM_DB_PASS},n8n|${N8N_DB_NAME}|${N8N_DB_USER}|${N8N_DB_PASS}"

# 4️⃣ Build LiteLLM DB URL and alias
export LITELLM_DATABASE_URL="postgresql://${LITELLM_DB_USER}:${LITELLM_DB_PASS}@${POSTGRES_HOST}:${POSTGRES_PORT}/${LITELLM_DB_NAME}"
export DATABASE_URL="$LITELLM_DATABASE_URL"

# 5️⃣ Update or insert derived vars in .env while preserving comments and order
awk -v appdbs="$APP_DATABASES" \
    -v litellmurl="$LITELLM_DATABASE_URL" \
    -v dburl="$DATABASE_URL" '
  BEGIN {
    set_appdbs=0; set_llurl=0; set_dburl=0
  }
  /^APP_DATABASES=/ {
    print "APP_DATABASES=" appdbs; set_appdbs=1; next
  }
  /^LITELLM_DATABASE_URL=/ {
    print "LITELLM_DATABASE_URL=" litellmurl; set_llurl=1; next
  }
  /^DATABASE_URL=/ {
    print "DATABASE_URL=" dburl; set_dburl=1; next
  }
  { print }
  END {
    if(!set_appdbs) print "APP_DATABASES=" appdbs
    if(!set_llurl) print "LITELLM_DATABASE_URL=" litellmurl
    if(!set_dburl) print "DATABASE_URL=" dburl
  }
' "$ENV_FILE" > "$TMP_ENV" && mv "$TMP_ENV" "$ENV_FILE"

# 6️⃣ Log results
echo "[INFO] Environment loaded and updated"
echo "       POSTGRES_USER=$POSTGRES_USER"
echo "       POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
echo "       APP_DATABASES=$APP_DATABASES"
echo "       LITELLM_DATABASE_URL=$LITELLM_DATABASE_URL"