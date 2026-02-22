#!/usr/bin/env bash
#
# TAPPaaS Test - VM Installation
#
# Creates a VM and applies OS-specific configuration based on imageType.
# Supports NixOS (clone), Debian/Ubuntu (img), and handles HA if configured.
#
# Usage: ./install.sh <vmname>
# Example: ./install.sh test-nixos
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get imageType to determine post-install steps

echo ""
echo "=== Post-Install Configuration ==="

echo ""
echo "=== Installation Complete ==="
