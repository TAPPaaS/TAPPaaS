#!/bin/env bash
#
# Create a cron entry to run update-tappaas at 2pm on a specified weekday.
#
# Usage: update-cron.sh <node-name> [weekday]
#   node-name: The TAPPaaS node name (e.g., tappaas1)
#   weekday:   Optional weekday (0-6, where 0=Sunday, 3=Wednesday). Default: 3 (Wednesday)

set -e

NODE_NAME="${1:-}"
WEEKDAY="${2:-3}"

if [ -z "$NODE_NAME" ]; then
    echo "Usage: update-cron.sh <node-name> [weekday]"
    echo "  node-name: The TAPPaaS node name (e.g., tappaas1)"
    echo "  weekday:   Optional weekday (0-6, where 0=Sunday, 3=Wednesday). Default: 3 (Wednesday)"
    exit 1
fi

# Validate weekday is a number between 0 and 6
if ! [[ "$WEEKDAY" =~ ^[0-6]$ ]]; then
    echo "Error: weekday must be a number between 0 and 6"
    echo "  0=Sunday, 1=Monday, 2=Tuesday, 3=Wednesday, 4=Thursday, 5=Friday, 6=Saturday"
    exit 1
fi

# Define the cron job
CRON_CMD="/home/tappaas/bin/update-tappaas --tappaas-node $NODE_NAME"
CRON_ENTRY="0 14 * * $WEEKDAY $CRON_CMD"

# Remove any existing cron entry for this node
crontab -u tappaas -l 2>/dev/null | grep -v "update-tappaas --tappaas-node $NODE_NAME" | crontab -u tappaas - 2>/dev/null || true

# Add the new cron entry
(crontab -u tappaas -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -u tappaas -

echo "Cron entry created for user tappaas:"
echo "  $CRON_ENTRY"
echo ""
echo "This will run update-tappaas for node '$NODE_NAME' at 2:00 PM every weekday $WEEKDAY"
