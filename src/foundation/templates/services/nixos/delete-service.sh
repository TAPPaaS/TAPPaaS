#!/usr/bin/env bash
#
# TAPPaaS NixOS Template Service - Delete
#
# Removes NixOS template configuration for a consuming module.
#
# Usage: delete-service.sh <module-name>
#

set -euo pipefail

echo "templates:nixos delete-service called for module: ${1:-unknown} (not yet implemented)"
exit 0
