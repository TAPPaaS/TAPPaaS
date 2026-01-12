#!/bin/bash
set -euo pipefail

# ============================================================================
# Script: manage-service.sh
# Purpose:
#   Generic management tool for Docker Compose services with:
#     - Reset (remove volume, restart)
#     - Test/verify setup
# Supports PostgreSQL multi-DB init with APP_DATABASES, but easy to extend.
# 
# to reset: ./manage-service.sh reset postgres postgres_
# to test:  ./manage-service.sh test-postgres postgres
#
# Author: TAPpaas Team / Erik Daniel
# Date: 2025-08-11
# ============================================================================

# ===== Helper: print friendly message with follow-up action =====
msg() {
  local type="$1"; shift
  case "$type" in
    info)    echo "ℹ️  $*";;
    ok)      echo "✅ $*";;
    warn)    echo "⚠️  $*";;
    error)   echo "❌ $*";;
  esac
}

# ===== Helper: wait for container to be healthy =====
wait_for_healthy() {
  local container_name="$1"
  msg info "Waiting for '$container_name' to be healthy..."
  local id
  id=$(docker compose ps -q "$container_name")
  if [ -z "$id" ]; then
    msg error "Container '$container_name' not found in Compose."
    echo "➡️  Check: Is the service name correct in docker-compose.yml?"
    exit 1
  fi
  until [ "$(docker inspect --format '{{.State.Health.Status}}' "$id")" = "healthy" ]; do
    sleep 2
    echo "..."
  done
  msg ok "'$container_name' is healthy."
}

# ===== Reset a service's volume and restart =====
reset_service() {
  local service="$1"
  local volume_pattern="$2"

  local volume
  volume=$(docker volume ls --format '{{.Name}}' | grep "$volume_pattern" || true)
  if [ -z "$volume" ]; then
    msg error "No volume found matching '$volume_pattern'."
    echo "➡️  Check the 'volumes:' in docker-compose.yml for correct names."
    exit 1
  fi

  msg warn "This will DELETE all data in volume '$volume'."
  read -rp "Type 'yes' to continue: " confirm
  if [ "$confirm" != "yes" ]; then
    msg info "Action cancelled."
    exit 0
  fi

  msg info "Stopping service '$service'..."
  docker compose stop "$service" || true

  msg info "Removing volume '$volume'..."
  docker volume rm "$volume"

  msg info "Starting service '$service'..."
  docker compose up -d "$service"

  wait_for_healthy "$service"
  msg ok "Reset and initialization complete."
}

# ===== Test PostgreSQL multi-DB according to APP_DATABASES =====
test_postgres_multidb() {
  local pg_service="$1"
  local superuser="${POSTGRES_SUPERUSER:-pgadmin}"
  local sysdb="${POSTGRES_DB:-postgres}"
  local app_dbs="${APP_DATABASES:-}"

  if [ -z "$app_dbs" ]; then
    msg error "APP_DATABASES is empty."
    echo "➡️  Check: Is APP_DATABASES set in your .env file?"
    exit 1
  fi

  msg info "Connecting to Postgres service '$pg_service'..."
  docker exec -i "$pg_service" psql -U "$superuser" -d "$sysdb" <<EOSQL
\l
SELECT rolname FROM pg_roles ORDER BY rolname;
EOSQL

  # Check schemas in each DB
  msg info "Checking schemas for each app database..."
  IFS=',' read -ra db_pairs <<< "$app_dbs"
  for entry in "${db_pairs[@]}"; do
    entry=$(echo "$entry" | xargs)
    [ -z "$entry" ] && continue
    IFS='|' read -ra f <<< "$entry"
    app_name="${f[0]}"
    db_name="${f[1]}"
    msg info "Checking DB '$db_name' for schema '${app_name}_schema'..."
    if docker exec -i "$pg_service" psql -U "$superuser" -d "$db_name" -c "\dn" | grep -q "${app_name}_schema"; then
      msg ok "Schema '${app_name}_schema' exists."
    else
      msg error "Schema '${app_name}_schema' is missing!"
      echo "➡️  Action: Check init-multiple-dbs.sh and APP_DATABASES in .env."
    fi
  done

  # LiteLLM DB URL check
  local litellm_service
  litellm_service=$(docker ps --format '{{.Names}}' | grep litellm || true)
  if [ -n "$litellm_service" ]; then
    msg info "Checking LiteLLM DB URL..."
    db_url=$(docker exec "$litellm_service" sh -c 'echo $LITELLM_DATABASE_URL' || true)
    echo "LiteLLM DB URL: $db_url"
  else
    msg warn "LiteLLM service not found; skipping DB URL check."
  fi

  msg ok "Test finished."
}

# ===== Main entry =====
if [ $# -lt 2 ]; then
  echo "Usage:"
  echo "  $0 reset <service_name> <volume_pattern>"
  echo "  $0 test-postgres <postgres_service_name>"
  exit 1
fi

action="$1"
service="$2"
volume_pattern="${3:-}"

case "$action" in
  reset)
    reset_service "$service" "$volume_pattern"
    ;;
  test-postgres)
    test_postgres_multidb "$service"
    ;;
  *)
    echo "Unknown action: $action"
    exit 1
    ;;
esac
