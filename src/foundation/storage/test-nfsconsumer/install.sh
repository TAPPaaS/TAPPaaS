#!/usr/bin/env bash
#
# TAPPaaS test fixture — storage:nfs consumer (ADR-029, storage/test.sh --deep).
#
# No-op module installer: the VM is created by cluster:vm and its mounts by
# storage:nfs; the deep suite rebuilds the guest itself. Exists only so the deep
# suite can stand up a disposable consumer.
#
# Usage: ./install.sh <vmname>
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
info "${BOLD}test-nfsconsumer: no post-install steps (storage:nfs deep-test fixture)${CL}"
