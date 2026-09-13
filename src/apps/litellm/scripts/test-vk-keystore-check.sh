#!/usr/bin/env bash
# test-vk-keystore-check.sh — the VK keystore existence check must run as root.
#
# The keystore lives in /etc/secrets (mode 700, root). The services run their
# remote checks as tappaas, so a bare `-f` cannot see the file and always reports
# it missing. install-service.sh then deletes the alias and mints a new key:
# every modify of a consuming module rotated its service key. test-service.sh
# already used `sudo test -f`, so the test stayed green while update rotated.
#
# Usage: test-vk-keystore-check.sh [<litellm-module-dir>]   (default: this module)
set -uo pipefail

DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SVC="${DIR}/services/models"
fail=0

for f in install-service.sh update-service.sh test-service.sh; do
  path="${SVC}/${f}"
  if [[ ! -f "${path}" ]]; then
    echo "FAIL ${f}: not found"; fail=1; continue
  fi
  # Any keystore existence test that is not `sudo test -f` runs as tappaas.
  bare=$(grep -nE -- '-f "\\\$\{KEYSTORE\}"' "${path}" | grep -v 'sudo test -f' || true)
  if [[ -n "${bare}" ]]; then
    echo "FAIL ${f}: keystore checked without sudo:"
    printf '       %s\n' "${bare}"
    fail=1
  elif ! grep -q 'sudo test -f "\\\${KEYSTORE}"' "${path}"; then
    echo "FAIL ${f}: no root keystore check found"; fail=1
  else
    echo "PASS ${f}: keystore checked as root"
  fi
done

exit "${fail}"
