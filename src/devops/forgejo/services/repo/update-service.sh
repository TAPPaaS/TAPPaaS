#!/usr/bin/env bash
#
# TAPPaaS Forgejo Repo Service — Update
#
# install-service.sh is idempotent: it re-asserts the repository, the deploy
# key, the consumer's files and the editors (one who signed in to Forgejo since
# the last run is added now).
#
# Usage: update-service.sh <consuming-module-name> [--dry-run]

set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-service.sh" "$@"
