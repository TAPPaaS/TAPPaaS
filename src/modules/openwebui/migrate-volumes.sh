#!/usr/bin/env bash
#
# Migrate existing host bind-mount structure for Local AI Platform
# Adjusts ownership/permissions safely for macOS, Linux, Windows/WSL
# Will NOT overwrite configs or data

set -euo pipefail
IFS=$'\n\t'

# ---- CONFIG ----
PROJECT_DIR="$(pwd)"
VOLUME_ROOT="$PROJECT_DIR/volumes"

# Mapping of host folders to container user:group
# Change UIDs/GIDs if your images use non-default
declare -A DIR_OWNERS=(
  ["postgres/data"]="999:999"         # postgres user (UID 999)
  ["postgres/logs"]="999:999"
  ["redis/data"]="100:101"           # redis user (UID 100: GID 101)
  ["redis/logs"]="100:101"
  ["open-webui/admin_config"]="1000:1000"
  ["open-webui/user_config"]="1000:1000"
  ["open-webui/backend"]="1000:1000"
  ["open-webui/logs"]="1000:1000"
  ["searxng/admin_config"]="1000:1000"
  ["searxng/var_lib_searxng"]="1000:1000"
  ["searxng/logs"]="1000:1000"
  ["litellm/admin_config"]="1000:1000"
  ["litellm/user_config"]="1000:1000"
  ["litellm/app"]="1000:1000"
  ["litellm/logs"]="1000:1000"
)

# ---- FUNCTIONS ----

set_permissions() {
  local path="$1"
  local owner="$2"

  # Only apply chown/chmod on Linux/WSL — macOS & Windows use pass‑through
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "[macOS] Skipping chown for: $path"
  elif grep -qi microsoft /proc/version 2>/dev/null; then
    echo "[WSL] Skipping chown for: $path (handled by Windows fs)"
  else
    echo "Setting owner $owner for: $path"
    sudo chown -R "$owner" "$path"
  fi

  # Give at least rwx for owner, rx for group
  chmod -R u+rwX,g+rX "$path"
}

migrate() {
  echo "🔄 Migrating existing volumes in: $VOLUME_ROOT"
  for folder in "${!DIR_OWNERS[@]}"; do
    host_path="$VOLUME_ROOT/$folder"
    owner="${DIR_OWNERS[$folder]}"

    if [[ -d "$host_path" ]]; then
      echo "[OK] Found: $host_path"
      set_permissions "$host_path" "$owner"
    else
      echo "[WARN] Missing expected dir: $host_path"
      mkdir -p "$host_path"
      set_permissions "$host_path" "$owner"
    fi
  done
}

# ---- MAIN ----
migrate
echo "✅ Migration/permission adjustment complete"
echo "💡 To test: run -> docker compose config && docker compose up -d"
