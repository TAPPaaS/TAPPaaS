#!/usr/bin/env bash
#
# TAPPaaS Windows Server Module - Test
#
# Usage: ./test.sh <vmname>
#

set -euo pipefail

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh

MODULE_NAME="${1:-windows-server}"

WINDOWS_TEST="$(get_module_dir 'templates')/services/windows/test-service.sh"
[[ -x "${WINDOWS_TEST}" ]] || chmod +x "${WINDOWS_TEST}"
"${WINDOWS_TEST}" "${MODULE_NAME}"
