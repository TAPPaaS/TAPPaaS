#!/usr/bin/env bash
#
# TAPPaaS satellite module update (ADR-010)
#
# Delegates to `satellite-manager update`. NOTE: satellite updates are pull-based
# (the satellite autoUpgrades from a pinned/signed ref); tappaas-cicd never SSHes
# in to push (ADR-010 §7.3). This verb reconciles the home-side wiring and config.
#
# Usage: ./update.sh <name>
#
set -euo pipefail

# update-module.sh passes the INSTANCE (config/satellite-<name>.json →
# satellite-<name>); satellite-manager takes the satellite's own <name>.
NAME="${1:?usage: ./update.sh <name>}"
NAME="${NAME#satellite-}"
command -v satellite-manager >/dev/null 2>&1 \
    || { echo "satellite-manager not on PATH" >&2; exit 1; }
exec satellite-manager update "${NAME}"
