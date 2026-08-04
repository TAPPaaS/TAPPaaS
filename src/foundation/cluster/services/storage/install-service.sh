#!/usr/bin/env bash
#
# TAPPaaS Cluster Storage Service - Install (dispatcher)
#
# For each of a module's declared `sharedStorage` entries, resolves the share
# name against whichever backend registry owns it, computes the NixOS
# fileSystems snippet for it, and rewrites the marked block in the module's
# own .nix SOURCE file. No SSH, no mount, no nixos-rebuild here — this
# dispatcher only edits the source; the consuming module's own install.sh
# (which runs AFTER dependsOn services, per install-module.sh's ordering)
# pushes the file and rebuilds.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: $0 <module-name>"
    exit 1
fi

MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
check_json "${MODULE_JSON}" || exit 2
# shellcheck source=storage-common.sh disable=SC1091
. "${SCRIPT_DIR}/storage-common.sh"

ENTRY_COUNT=$(jq '(.sharedStorage // []) | length' <<<"${JSON}")
if [[ "${ENTRY_COUNT}" -eq 0 ]]; then
    debug "  No 'sharedStorage' entries declared for ${MODULE} — nothing to do"
    exit 0
fi

VMNAME="$(get_config_value 'vmname' "${MODULE}")"
ZONE0="$(get_config_value 'zone0' 'mgmt')"
NODE_FQDN="${VMNAME}.${ZONE0}.internal"

MODULE_DIR="$(get_module_dir "${MODULE}")" || die "Could not resolve module directory for ${MODULE}"
NIX_FILE="${MODULE_DIR}/${VMNAME}.nix"
[[ -f "${NIX_FILE}" ]] || die "${NIX_FILE} not found"

SNIPPETS="$(storage_collect_nix_snippets "${MODULE_JSON}" "${NODE_FQDN}" | while IFS= read -r params; do
    mp=$(jq -r '.mountPoint' <<<"${params}")
    device=$(jq -r '.device' <<<"${params}")
    fstype=$(jq -r '.fsType' <<<"${params}")
    opts=$(jq -r '.options | map("\"" + . + "\"") | join(" ")' <<<"${params}")
    printf '  fileSystems."%s" = {\n    device  = "%s";\n    fsType  = "%s";\n    options = [ %s ];\n  };\n' \
        "${mp}" "${device}" "${fstype}" "${opts}"
done)"

storage_rewrite_nix_block "${NIX_FILE}" "${SNIPPETS}"

info "  ${GN}✓${CL} cluster:storage mounts written into ${NIX_FILE} — will apply on this module's own install/update rebuild"
