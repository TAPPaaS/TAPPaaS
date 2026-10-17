#!/usr/bin/env bash
# install.sh — build the console (backend and front end) and link bin/console
# into ~/bin (idempotent). tappaas-console.service runs ~/bin/console serve.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${here}/../lib/component-install-lib.sh"
build_and_link_nix_component "${here}" "console"
