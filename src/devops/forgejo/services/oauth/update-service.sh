#!/usr/bin/env bash
#
# TAPPaaS Forgejo OAuth Service — Update
#
# install-service.sh is idempotent: it re-asserts the application, moves its
# redirect URIs when the consumer's address changed (a name published since the
# last run), and rewrites the consumer's file.
#
# Usage: update-service.sh <consuming-module-name> [--dry-run]

set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-service.sh" "$@"
