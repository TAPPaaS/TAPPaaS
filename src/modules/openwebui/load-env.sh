#!/usr/bin/env bash
set -euo pipefail

##
# Robust .env loader:
# - Laadt basisvariabelen (veilig voor spaties/specials)
# - Negeert commentaar en lege regels
# - Houdt env consistent voor Compose én init scripts
##

ENV_FILE="${1:-.env}"
TMP_ENV=".env.tmp"

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ERROR] Env file '$ENV_FILE' not found." >&2
    exit 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^\s*# ]] && continue
    line="${line%% #*}"
    line="$(echo "$line" | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//')"
    if [[ "$line" == *"="* ]]; then
      export "$line"
    fi
  done < "$ENV_FILE"
}
load_env

# Zorg dat ook Postgres base image variabelen beschikbaar zijn
export POSTGRES_USER="${POSTGRES_SUPERUSER}"
export POSTGRES_PASSWORD="${POSTGRES_SUPERPASS}"

# 1️⃣ Composite APP_DATABASES string opbouwen
export APP_DATABASES="litellm|${LITELLM_DB_NAME}|${LITELLM_DB_USER}|${LITELLM_DB_PASS},n8n|${N8N_DB_NAME}|${N8N_DB_USER}|${N8N_DB_PASS}"

# 2️⃣ LiteLLM DB URL samenstellen
export LITELLM_DATABASE_URL="postgresql://${LITELLM_DB_USER}:${LITELLM_DB_PASS}@${POSTGRES_HOST}:${POSTGRES_PORT}/${LITELLM_DB_NAME}"

# 3️⃣ DATABASE_URL alias instellen
export DATABASE_URL="$LITELLM_DATABASE_URL"

# 4️⃣ Persist afgeleide waarden terug naar .env
awk -v appdbs="$APP_DATABASES" \
    -v litellmurl="$LITELLM_DATABASE_URL" \
    -v dburl="$DATABASE_URL" '
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

# 5️⃣ Log status
echo "[INFO] Environment loaded and persisted"
echo "[INFO] POSTGRES_USER=$POSTGRES_USER"
echo "[INFO] POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
echo "[INFO] APP_DATABASES=$APP_DATABASES"
echo "[INFO] LITELLM_DATABASE_URL=$LITELLM_DATABASE_URL"