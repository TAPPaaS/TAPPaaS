#!/usr/bin/env bash
#
# sat-hello — disposable ADR-010 test module update.
#
# No-op: sat-hello.nix is fully declarative and re-applied by the framework
# nixos-rebuild. Nothing module-specific to reconcile. Safe to delete.
#
# Usage: ./update.sh <vmname>

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

info "${BOLD}sat-hello: no update steps (declarative nginx test fixture)${CL}"
