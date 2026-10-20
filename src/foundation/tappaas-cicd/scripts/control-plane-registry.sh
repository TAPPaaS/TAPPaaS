#!/usr/bin/env bash
# control-plane-registry.sh — write the control plane's registry (ADR-035 D5).
#
# config/control-plane.json lists every manager and controller on this site, so
# the readers that used to keep their own list (the self-check, the console) read
# one. P1: the standard components, from tappaas-cicd's components.json, each as
# an entry of module `tappaas-cicd`. Entries a module registered (module-manager,
# a later phase) are kept as they are: this rewrites only tappaas-cicd's own.
#
# Run by refresh-control-plane.sh on every sweep's prepare step and by
# tappaas-cicd's install.sh, after the components are built and linked.
#
# Usage: control-plane-registry.sh [--check]
#   --check   print the registry it would write; change nothing
# Exit: 0 written (or printed), 1 components.json unreadable or the write failed.

set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh 2>/dev/null || {
    info() { echo "[Info] $*"; }; error() { echo "[Error] $*" >&2; }
}

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CICD_DIR="${CICD_DIR:-$(dirname "${HERE}")}"
COMPONENTS="${CICD_DIR}/components.json"
CONF="${CONFIG_DIR:-/home/tappaas/config}"
REGISTRY="${CONF}/control-plane.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! jq -e '.components | type == "array"' "${COMPONENTS}" >/dev/null 2>&1; then
    error "control-plane-registry: ${COMPONENTS} is not a component list"
    exit 1
fi

# The repository tappaas-cicd came from, as site.json names it (the one whose
# path holds this checkout); "TAPPaaS" when site.json does not say.
repo="TAPPaaS"
if [[ -r "${CONF}/site.json" ]]; then
    root="$(dirname "$(dirname "$(dirname "${CICD_DIR}")")")"
    r="$(jq -r --arg p "${root}" '[.repositories[]? | select(.path == $p) | .name][0] // empty' "${CONF}/site.json" 2>/dev/null)"
    [[ -n "${r}" ]] && repo="${r}"
fi

build() { # build <existing-registry-json>
    jq --slurpfile c "${COMPONENTS}" --argjson old "$1" --arg dir "${CICD_DIR}" --arg repo "${repo}" \
       --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" -n '
        { version: 1, generated: $t,
          components: (
            [ $c[0].components[] | {
                name, kind, module: "tappaas-cicd", repository: $repo,
                source: ($dir + "/" + .path), language, package,
                manifest: (.manifest // null), aliases: (.aliases // []), instances: [] } ]
            + [ ($old.components // [])[] | select(.module != "tappaas-cicd") ]
          ) }'
}

old='{}'
[[ -s "${REGISTRY}" ]] && old="$(jq -c . "${REGISTRY}" 2>/dev/null || echo '{}')"

if [[ "${CHECK}" == 1 ]]; then
    build "${old}"
    exit $?
fi

mkdir -p "${CONF}"
exec 9>"${REGISTRY}.lock"
flock -w 30 9 || { error "control-plane-registry: ${REGISTRY} is locked by another writer"; exit 1; }
# Re-read under the lock: a module's registration may have landed meanwhile.
[[ -s "${REGISTRY}" ]] && old="$(jq -c . "${REGISTRY}" 2>/dev/null || echo '{}')"
tmp="$(mktemp "${REGISTRY}.XXXXXX")"
if build "${old}" > "${tmp}" && jq -e '.components | length > 0' "${tmp}" >/dev/null; then
    chmod 644 "${tmp}"
    mv -f "${tmp}" "${REGISTRY}"
    info "control plane: $(jq '[.components[] | select(.module == "tappaas-cicd")] | length' "${REGISTRY}") standard component(s), $(jq '[.components[] | select(.module != "tappaas-cicd")] | length' "${REGISTRY}") from modules — ${REGISTRY}"
else
    rm -f "${tmp}"
    error "control-plane-registry: could not write ${REGISTRY}"
    exit 1
fi
