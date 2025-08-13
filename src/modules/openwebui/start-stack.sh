#!/usr/bin/env bash
set -euo pipefail

##
# start-stack.sh — Prepare and start the full Docker Compose stack
# Steps:
#   1. Check prerequisites
#   2. Load .env + .env.local (for secrets/overrides)
#   3. Validate mandatory variables
#   4. Generate derived settings (DB URLs, APP_DATABASES, ports)
#   5. Validate required host directories
#   6. Update .env with derived values (preserve order/comments)
#   7. Validate docker-compose config
#   8. Start stack
# Stops on error with concrete remediation instructions.
##

STEP=0
NEXT_STEP() { STEP=$((STEP+1)); echo -e "\n[$STEP/8] $1"; }
ABORT() { echo -e "❌ ERROR: $1\n💡 Action: $2"; exit 1; }

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=true; shift; fi

ENV_FILE="${1:-.env}"
LOCAL_ENV=".env.local"
TMP_ENV=".env.tmp"

NEXT_STEP "Checking prerequisites..."
command -v docker >/dev/null || ABORT "Docker not installed" "Install Docker first"
command -v docker compose >/dev/null || ABORT "Docker Compose v2 not installed" "Upgrade Docker to a version with Compose v2"

[[ -f "$ENV_FILE" ]] || ABORT "$ENV_FILE is missing" "Copy from .env.example and adjust values"
[[ ! -f "$LOCAL_ENV" ]] && echo "ℹ️  No $LOCAL_ENV found — secrets will be taken from $ENV_FILE"

load_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^\s*# ]] && continue
      clean_line="${line%% #*}"
      clean_line="$(echo "$clean_line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      if [[ "$clean_line" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
        export "$clean_line"
      fi
    done < "$file"
  fi
}

NEXT_STEP "Loading environment variables..."
load_file "$ENV_FILE"
load_file "$LOCAL_ENV"

[[ -n "${POSTGRES_SUPERUSER:-}" ]] || ABORT "POSTGRES_SUPERUSER not set" "Add it to $ENV_FILE"
[[ -n "${POSTGRES_SUPERPASS:-}" ]]   || ABORT "POSTGRES_SUPERPASS not set" "Store in $LOCAL_ENV"

NEXT_STEP "Aligning Postgres credentials..."
export POSTGRES_USER="$POSTGRES_SUPERUSER"
export POSTGRES_PASSWORD="$POSTGRES_SUPERPASS"

NEXT_STEP "Generating derived database settings..."
[[ -n "${LITELLM_DB_USER:-}" && -n "${LITELLM_DB_PASS:-}" && -n "${LITELLM_DB_NAME:-}" ]] \
  || ABORT "LiteLLM DB credentials incomplete" "Add LITELLM_DB_USER, LITELLM_DB_PASS, and LITELLM_DB_NAME to .env or .env.local"

export APP_DATABASES="litellm|${LITELLM_DB_NAME}|${LITELLM_DB_USER}|${LITELLM_DB_PASS},n8n|${N8N_DB_NAME}|${N8N_DB_USER}|${N8N_DB_PASS}"
export LITELLM_DATABASE_URL="postgresql://${LITELLM_DB_USER}:${LITELLM_DB_PASS}@${POSTGRES_HOST}:${POSTGRES_PORT}/${LITELLM_DB_NAME}"
export DATABASE_URL="$LITELLM_DATABASE_URL"

NEXT_STEP "Ensuring service ports are set..."
: "${OPENWEBUI_PORT:=8080}"
: "${SEARXNG_PORT:=8081}"
: "${POSTGRES_PORT:=5432}"
: "${LITELLM_PORT:=4000}"
: "${REDIS_PORT:=6379}"
export OPENWEBUI_PORT SEARXNG_PORT POSTGRES_PORT LITELLM_PORT REDIS_PORT

NEXT_STEP "Validating required host directories..."
for svc in openwebui litellm searxng postgres redis; do
  for sub in admin_config user_config data logs; do
    if [[ "$svc" == "postgres" && "$sub" == "user_config" ]]; then continue; fi
    if [[ "$svc" == "postgres" && "$sub" == "admin_config" ]]; then sub="admin_scripts"; fi
    dir="$svc/$sub"
    [[ -d "$dir" ]] || ABORT "Missing directory: $dir" "Run: mkdir -p $dir && chown $(id -u):$(id -g) $dir"
  done
done

NEXT_STEP "Updating .env with derived values..."
awk -v appdbs="$APP_DATABASES" \
    -v litellmurl="$LITELLM_DATABASE_URL" \
    -v dburl="$DATABASE_URL" \
    -v owport="$OPENWEBUI_PORT" \
    -v sxport="$SEARXNG_PORT" \
    -v pgport="$POSTGRES_PORT" \
    -v llport="$LITELLM_PORT" \
    -v rdport="$REDIS_PORT" '
  BEGIN {
    set_appdbs=set_llurl=set_dburl=0
    set_owport=set_sxport=set_pgport=set_llport=set_rdport=0
  }
  /^APP_DATABASES=/        { print "APP_DATABASES=" appdbs; set_appdbs=1; next }
  /^LITELLM_DATABASE_URL=/ { print "LITELLM_DATABASE_URL=" litellmurl; set_llurl=1; next }
  /^DATABASE_URL=/         { print "DATABASE_URL=" dburl; set_dburl=1; next }
  /^OPENWEBUI_PORT=/       { print "OPENWEBUI_PORT=" owport; set_owport=1; next }
  /^SEARXNG_PORT=/         { print "SEARXNG_PORT=" sxport; set_sxport=1; next }
  /^POSTGRES_PORT=/        { print "POSTGRES_PORT=" pgport; set_pgport=1; next }
  /^LITELLM_PORT=/         { print "LITELLM_PORT=" llport; set_llport=1; next }
  /^REDIS_PORT=/           { print "REDIS_PORT=" rdport; set_rdport=1; next }
  { print }
  END {
    if(!set_appdbs) print "APP_DATABASES=" appdbs
    if(!set_llurl) print "LITELLM_DATABASE_URL=" litellmurl
    if(!set_dburl) print "DATABASE_URL=" dburl
    if(!set_owport) print "OPENWEBUI_PORT=" owport
    if(!set_sxport) print "SEARXNG_PORT=" sxport
    if(!set_pgport) print "POSTGRES_PORT=" pgport
    if(!set_llport) print "LITELLM_PORT=" llport
    if(!set_rdport) print "REDIS_PORT=" rdport
  }
' "$ENV_FILE" > "$TMP_ENV"

if $DRY_RUN; then
  echo "[DRY-RUN] Preview of .env changes:"
  diff -u "$ENV_FILE" "$TMP_ENV" || true
  rm -f "$TMP_ENV"
  echo "Dry run complete — no changes made."
  exit 0
else
  mv "$TMP_ENV" "$ENV_FILE"
fi

NEXT_STEP "Validating docker-compose configuration..."
docker compose config >/dev/null || ABORT "docker-compose config validation failed" "Fix invalid syntax or missing variables before retrying"

NEXT_STEP "Starting Docker Compose stack..."
docker compose up -d || ABORT "Failed to start the Docker stack" "Check: docker compose logs --follow"

echo -e "\n✅ All steps completed successfully!"
echo "   Access OpenWebUI: http://localhost:$OPENWEBUI_PORT"
echo "   LiteLLM health: curl http://localhost:$LITELLM_PORT/health/readiness"
