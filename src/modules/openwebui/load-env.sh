#!/usr/bin/env bash
# load-env.sh — safely load variables from .env file into current shell

load_env() {
  local env_file="${1:-.env}"
  if [[ -f "$env_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      # Skip empty lines and lines starting with #
      [[ -z "$line" || "$line" =~ ^\s*# ]] && continue
      # Remove inline comments starting with #
      line="${line%%#*}"
      # Trim leading and trailing whitespace
      line="$(echo -e "$line" | sed -e 's/^\s*//' -e 's/\s*$//')"
      # Export the cleaned line as an environment variable
      export "$line"
    done < "$env_file"
  else
    echo "Warning: env file '$env_file' not found."
  fi
}

# Call function with .env file
load_env .env