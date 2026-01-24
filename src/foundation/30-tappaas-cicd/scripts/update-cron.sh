#!/usr/bin/env bash
#
# Create a cron entry to run update-tappaas daily at 2am.
# The update-tappaas script handles all scheduling logic internally.
#
# Usage: update-cron.sh

set -e

CRON_CMD="/home/tappaas/bin/update-tappaas"
CRON_ENTRY="0 2 * * * $CRON_CMD"

# Determine crontab command based on current user
if [ "$(whoami)" = "tappaas" ]; then
  CRONTAB_CMD="crontab"
else
  CRONTAB_CMD="crontab -u tappaas"
fi

# Check if crontab is available
if ! command -v crontab >/dev/null 2>&1; then
  echo "Error: crontab command not found. Please ensure cron is enabled in the NixOS configuration."
  echo "Add 'services.cron.enable = true;' to tappaas-cicd.nix and run nixos-rebuild."
  exit 1
fi

# Remove any existing update-tappaas cron entries
$CRONTAB_CMD -l 2>/dev/null | grep -v "update-tappaas" | $CRONTAB_CMD - 2>/dev/null || true

# Add the cron entry
($CRONTAB_CMD -l 2>/dev/null; echo "$CRON_ENTRY") | $CRONTAB_CMD -

# echo "Cron entry created for user tappaas:"
# echo "  $CRON_ENTRY"
# echo ""
# echo "update-tappaas will run daily at 2:00 AM and determine which nodes to update based on:"
# echo "  - Branch 'main' or 'stable': updates first week of month only"
# echo "    - Even numbered nodes (tappaas2, tappaas4, ...): Tuesday"
# echo "    - Odd numbered nodes (tappaas1, tappaas3, ...): Thursday"
# echo "  - Other branches: updates run daily"
