#!/usr/bin/env bash
set -euo pipefail

##
# Robust .env loader:
# - Loads base vars (safe for spaces, special chars)
# - Ignores comments, blanks
# - No shell expansion until after loading all base variables
# - Self-heals: writes new composites back to .env for Compose
##

ENV_FILE="${1:-.env}"
TMP_ENV=".env.tmp"

# Function: robustly load all base vars
load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ERROR] Env file '$ENV_FILE' not found." >&2
    exit 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^\s*# ]] && continue
    line="${line%% #*}"                             # strip trailing ' # comment'
    line="$(echo "$line" | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//')"
    if [[ "$line" == *"="* ]]; then
      export "$line"
    fi
  done < "$ENV_FILE"
}
load_env

# 1️⃣ Build composite APP_DATABASES from per-app components (DRY)
export APP_DATABASES="litellm|${LITELLM_DB_NAME}|${LITELLM_DB_USER}|${LITELLM_DB_PASS},n8n|${N8N_DB_NAME}|${N8N_DB_USER}|${N8N_DB_PASS}"

# 2️⃣ Compose LiteLLM DB URL (DRY from parts)
export LITELLM_DATABASE_URL="postgresql://${LITELLM_DB_USER}:${LITELLM_DB_PASS}@${POSTGRES_HOST}:${POSTGRES_PORT}/${LITELLM_DB_NAME}"

# 3️⃣ Compose DATABASE_URL for compatibility
export DATABASE_URL="$LITELLM_DATABASE_URL"

# 4️⃣ Persist these derived values back to .env (overwrite old entries, keep comments!)
awk -v appdbs="$APP_DATABASES" \
    -v litellmurl="$LITELLM_DATABASE_URL" \
    -v dburl="$DATABASE_URL" '
  # Replace or append the DRY keys; preserve comments and order
  BEGIN {set_appdbs=0; set_llurl=0; set_dburl=0}
  /^APP_DATABASES=/ { print "APP_DATABASES=" appdbs; set_appdbs=1; next }
  /^LITELLM_DATABASE_URL=/ { print "LITELLM_DATABASE_URL=" litellmurl; set_llurl=1; next }
  /^DATABASE_URL=/ { print "DATABASE_URL=" dburl; set_dburl=1; next }
  { print }
  END {
    if(!set_appdbs) print "APP_DATABASES=" appdbs;
    if(!set_llurl) print "LITELLM_DATABASE_URL=" litellmurl;
    if(!set_dburl) print "DATABASE_URL=" dburl;
  }
' "$ENV_FILE" > "$TMP_ENV"
mv "$TMP_ENV" "$ENV_FILE"

# 5️⃣ Show status/log
echo "[INFO] Environment loaded and persisted"
echo "[INFO] APP_DATABASES=$APP_DATABASES"
echo "[INFO] LITELLM_DATABASE_URL=$LITELLM_DATABASE_URL"

# Optionally, export other derived envs as needed for shell use.
