#!/usr/bin/env bash
#
# TAPPaaS Identity Service — Update (ADR-006 Phase 4, issue #56).
#
# install-service.sh is fully reconcile-in-place, so update == re-run install:
# it refreshes the OIDC app/provider, re-applies the access bindings, and
# rewrites the VM secrets env. Safe to run on every update cycle.
#
# Usage: update-service.sh <effective-module-name>

set -euo pipefail

_IDENTITY_SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${_IDENTITY_SVC_DIR}/install-service.sh" "$@"
