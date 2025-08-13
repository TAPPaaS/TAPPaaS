#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# init-data-dirs.sh
# Create /data/<service>/<subdir> directories for persistent container volumes.
# Subdirs: application_config, functional_config, user_data, logs
# Ownership forced to tappaas:tappaas
# ------------------------------------------------------------------------------

OWNER="tappaas"
GROUP="tappaas"

# Map of services to their required subdirectories
declare -A DIRS
DIRS["open-webui"]="application_config functional_config user_data logs"
DIRS["searxng"]="application_config user_data logs"
DIRS["postgres"]="application_config user_data logs"
DIRS["litellm"]="application_config functional_config user_data logs"
DIRS["redis"]="user_data logs"

create_dir() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        echo "📁 Creating: $path"
        mkdir -p "$path"
    else
        echo "✅ Exists  : $path"
    fi
    chown "$OWNER:$GROUP" "$path"
}

echo "🚀 Initializing /data persistent volume directories..."
for service in "${!DIRS[@]}"; do
    for sub in ${DIRS[$service]}; do
        create_dir ~/data/$service/$sub
    done
done

echo "🎯 All /data directories verified with ownership $OWNER:$GROUP"
