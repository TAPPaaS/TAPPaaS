#!/usr/bin/env bash
# test-pvehost-nfs.sh — runs the pvehost:nfs unit suite (ADR-029, #766) in the
# tappaas-cicd fast tier: pvehost has no fast tier of its own (its test.sh is the
# live per-instance test), and a suite nothing runs does not exist.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${HERE}/../../../pvehost/lib/test-nfs-lib.sh"
