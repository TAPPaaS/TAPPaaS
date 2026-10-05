#!/usr/bin/env bash
#
# TAPPaaS test fixture — pvehost:nfs consumer (ADR-029, pvehost/test.sh --deep).
#
# No-op module installer: the VM is created by cluster:vm and its mounts by
# pvehost:nfs; the deep suite rebuilds the guest itself. Exists only so the deep
# suite can stand up a disposable consumer.
#
# Usage: ./install.sh <vmname>
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
info "${BOLD}test-nfsconsumer: no post-install steps (pvehost:nfs deep-test fixture)${CL}"
