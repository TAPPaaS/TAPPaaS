#!/usr/bin/env bash
set -euo pipefail

# Creates the /data/<service>/<subdir> structure for all services
# Sets ownership to tappaas:tappaas
# Safe to re-run if directories already exist.

OWNER="tappaas"
GROUP="tappaas"

# All required directories by service and subdir
declare -A DIRS

# open-webui
DIRS["open-webui"]="application_config functional_config user_data logs"

# searxng
DIRS["searxng"]="application_config user_data logs"

# postgres
DIRS["postgres"]="application_config user_data logs"

# litellm
DIRS["litellm"]="application_config functional_config user_data logs"

# redis
DIRS["redis"]="user_data logs"

# Function to create directories safely
create_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        echo "📁 Creating $dir"
        mkdir -p "$dir"
    else
        echo "✅ Exists: $dir"
    fi
    chown "$OWNER:$GROUP" "$dir"
}

echo "🚀 Initializing /data directory structure..."
for service in "${!DIRS[@]}"; do
    subs=${DIRS[$service]}
    for sub in $subs; do
        create_dir "/data/$service/$sub"
    done
done

echo "🎯 All directories created/verified with ownership $OWNER:$GROUP"