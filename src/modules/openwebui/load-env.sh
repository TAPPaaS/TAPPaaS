#!/usr/bin/env bash
set -euo pipefail

##
# Robust .env loader:
# - Works in bash/zsh
# - Skips comments & blanks
# - No shell interpretation of special chars in values
# - Safe with spaces, pipes, braces
# - Expands composite vars after base vars are loaded
##

load_env() {
  local env_file="${1:-.env}"
  if [[ ! -f "$env_file" ]]; then
    echo "[ERROR] Env file '$env_file' not found." >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty/comment lines
    [[ -z "$line" || "$line" =~ ^\s*# ]] && continue
    # Remove any inline comment starting with ' #' (space-hash)
    line="${line%% #*}"
    # Trim whitespace
    line="$(echo "$line" | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//')"
    # Export only if line contains '='
    if [[ "$line" == *"="* ]]; then
      export "$line"
    fi
  done < "$env_file"
}

# 1️⃣ Load all base variables from .env
load_env ".env"

# 2️⃣ Build composite APP_DATABASES from per‑app vars
export APP_DATABASES="\
litellm|${LITELLM_DB_NAME}|${LITELLM_DB_USER}|${LITELLM_DB_PASS},\
n8n|${N8N_DB_NAME}|${N8N_DB_USER}|${N8N_DB_PASS}\
"

# 3️⃣ Generate LiteLLM DB URL from helper script
if [[ -x "./get-db-url.sh" ]]; then
  export LITELLM_DATABASE_URL="$(./get-db-url.sh)"
else
  echo "[WARN] get-db-url.sh not found or not executable, skipping LITELLM_DATABASE_URL generation"
fi

# 4️⃣ Summary log
echo "[INFO] Environment loaded"
echo "[INFO] APP_DATABASES=$APP_DATABASES"
echo "[INFO] LITELLM_DATABASE_URL=$LITELLM_DATABASE_URL"
