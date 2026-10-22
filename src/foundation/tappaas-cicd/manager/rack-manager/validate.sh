#!/usr/bin/env bash
# validate.sh — rack-manager's `validate` verb: config/racks.json against the
# topology and the faceplate catalog.
set -euo pipefail
exec rack-manager validate "$@"
