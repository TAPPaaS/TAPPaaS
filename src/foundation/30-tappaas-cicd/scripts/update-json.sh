#!/usr/bin/env bash
#
# Update a module JSON file if needed.
#
# Usage: update-json.sh <module-name>
#
# Returns:
#   0 (true)  - JSON was updated (source copied to installed)
#   1 (false) - No update needed or .orig file exists
#
# If a <module>.json.orig file exists in /home/tappaas/config, it means
# the user has customized the JSON. In this case, a warning is printed
# if the source JSON has changed since the .orig file was created then false is returned.

set -e

MODULE="${1:-}"
CONFIG_DIR="/home/tappaas/config"

if [ -z "$MODULE" ]; then
    echo "Usage: update-json.sh <module-name>"
    echo "  Updates <module>.json if source differs from installed"
    exit 1
fi

SOURCE_JSON="./${MODULE}.json"
INSTALLED_JSON="${CONFIG_DIR}/${MODULE}.json"
ORIG_JSON="${CONFIG_DIR}/${MODULE}.json.orig"

# Check if source JSON exists
if [ ! -f "$SOURCE_JSON" ]; then
    echo "Error: Source file not found: $SOURCE_JSON"
    exit 1
fi

# Ensure config directory exists
mkdir -p "$CONFIG_DIR"

# Check if .orig file exists (indicates user customization)
if [ -f "$ORIG_JSON" ]; then
    # Compare source with .orig to see if upstream has changed
    if ! diff -q "$SOURCE_JSON" "$ORIG_JSON" >/dev/null 2>&1; then
        echo "Warning: ${MODULE}.json has been updated upstream, but local customizations exist"
        echo "  Source:    $SOURCE_JSON"
        echo "  Original:  $ORIG_JSON"
        echo "  Custom:    $INSTALLED_JSON"
        echo "  Please review and merge changes manually"
    fi
    exit 1  # Return false - don't auto-update when .orig exists
fi

# No .orig file - compare source with installed
if [ ! -f "$INSTALLED_JSON" ]; then
    # Installed file doesn't exist, copy it
    echo "Installing ${MODULE}.json to ${CONFIG_DIR}/"
    cp "$SOURCE_JSON" "$INSTALLED_JSON"
    exit 0  # Return true - file was updated
fi

# Compare source with installed
if diff -q "$SOURCE_JSON" "$INSTALLED_JSON" >/dev/null 2>&1; then
    # Files are equal, no update needed
    exit 1  # Return false
else
    # Files differ, copy source to installed
    echo "Updating ${MODULE}.json in ${CONFIG_DIR}/"
    cp "$SOURCE_JSON" "$INSTALLED_JSON"
    exit 0  # Return true - file was updated
fi
