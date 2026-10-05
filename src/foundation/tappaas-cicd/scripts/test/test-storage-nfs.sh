#!/usr/bin/env bash
# test-storage-nfs.sh — runs the storage:nfs unit suite (ADR-029 v0.9) in the
# tappaas-cicd fast tier: the storage module has no fast tier of its own (its
# test.sh is the live test), and a suite nothing runs does not exist.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${HERE}/../../../storage/lib/test-nfs-lib.sh"
