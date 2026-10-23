#!/usr/bin/env bash
# validate.sh — position-manager's `validate` verb: config/positions.json
# against the topology, the site's locations and the faceplate catalog.
set -euo pipefail
exec position-manager validate "$@"
