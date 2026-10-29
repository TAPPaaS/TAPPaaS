#!/usr/bin/env bash
# validate.sh — asset-manager's `validate` verb: config/positions.json
# against the topology, the site's locations and the faceplate catalog.
set -euo pipefail
exec asset-manager validate "$@"
