#!/bin/env bash
#
# Create a cron entry to run update-tappaas daily at 2am.
# The update-tappaas script handles all scheduling logic internally.
#
# Usage: update-cron.sh

set -e

CRON_CMD="/home/tappaas/bin/update-tappaas"
CRON_ENTRY="0 2 * * * $CRON_CMD"

# Remove any existing update-tappaas cron entries
crontab -u tappaas -l 2>/dev/null | grep -v "update-tappaas" | crontab -u tappaas - 2>/dev/null || true

# Add the cron entry
(crontab -u tappaas -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -u tappaas -

echo "Cron entry created for user tappaas:"
echo "  $CRON_ENTRY"
echo ""
echo "update-tappaas will run daily at 2:00 AM and determine which nodes to update based on:"
echo "  - Branch 'main' or 'stable': updates first week of month only"
echo "    - Even numbered nodes (tappaas2, tappaas4, ...): Tuesday"
echo "    - Odd numbered nodes (tappaas1, tappaas3, ...): Thursday"
echo "  - Other branches: updates run daily"
