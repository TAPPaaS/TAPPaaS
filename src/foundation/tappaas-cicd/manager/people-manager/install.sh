#!/usr/bin/env bash
# Link this component's CLI entry scripts into ~/bin (idempotent).
#
# people-manager bash entry points:
#   user-setup.sh  -> ~/bin/user-setup.sh
#   validate.sh    -> ~/bin/validate-people.sh   (project-wide name)
#
# The TypeScript CRUD + Authentik sync engine (people-manager.ts) arrives in
# S2b; nothing to build here yet.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"

link_as() {
    # $1 = source basename, $2 = link name in bin
    local src="${here}/$1" name="$2"
    [[ -f "${src}" ]] || { echo "  skip: ${src} not found"; return 0; }
    chmod +x "${src}"
    ln -sfn "${src}" "${bin}/${name}"
    echo "  linked ${bin}/${name}"
}

link_as user-setup.sh user-setup.sh
link_as validate.sh    validate-people.sh
