#!/usr/bin/env bash
#
# rename-instance.sh — an instance gets another name, in place (#566).
#
# Run by `module-manager module modify <instance> --set instance=<new>`.
#
# An instance is named by its config file (ADR-026 D6.1); the module it is an
# instance of is named by .moduleSource (D6.2), not by that name. So renaming an
# instance is a rename of its config files and of the references other configs
# make to it — nothing on the running guest, whose own name is `vmname` and is
# not touched here.
#
# That is the whole fix #566 asked for. The breakage it reported — a legacy,
# unsuffixed name that no update could merge, because the release source was
# derived by stripping the name at a hyphen — is gone with D6.3: the merge reads
# <module dir>/<module>.json. A name off the <module>-<environment> convention
# is a name, not a fault; this verb is for when the operator wants the
# convention back.
#
#   config/<old>.json        → config/<new>.json
#   config/<old>.json.orig   → config/<new>.json.orig      (the merge baseline)
#   config/<old>.meta.json   → config/<new>.meta.json
#   .node == <old> elsewhere → <new>                       (the Host a module runs on, D6.5)
#
# NOT touched, and reported: the guest's own name (`vmname`) and everything
# keyed on it — its DNS record, firewall alias, proxy upstream — and the backup
# job, which follows the vmid. A machine is refused: it is named after the host
# it is (ADR-026 D8), so renaming the instance would only make the two disagree.
#
# Usage: rename-instance.sh <old> <new> [--dry-run]
# Exit:  0 renamed (or would) · 1 refused, nothing changed · 2 usage
#
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
. /home/tappaas/bin/common-install-routines.sh

CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"
DRY=0
ARGS=()
for a in "$@"; do
    case "${a}" in
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) error "${SCRIPT_NAME}: unknown option ${a}"; exit 2 ;;
        *) ARGS+=("${a}") ;;
    esac
done
[[ "${#ARGS[@]}" -eq 2 ]] || { error "usage: ${SCRIPT_NAME} <old> <new> [--dry-run]"; exit 2; }
OLD="${ARGS[0]}"; NEW="${ARGS[1]}"

OLD_CFG="${CONFIG_DIR}/${OLD}.json"
[[ -f "${OLD_CFG}" ]] || die "'${OLD}' is not installed (no ${OLD_CFG})"
[[ "${OLD}" != "${NEW}" ]] || die "'${NEW}' is the name it already has"
instance_name_ok "${NEW}" \
    || die "'${NEW}' is not a usable instance name (a DNS label — lowercase letters, digits, hyphens — and not a name config/ already uses)"
[[ ! -e "${CONFIG_DIR}/${NEW}.json" ]] || die "config/${NEW}.json already exists — that name is taken"

kind="$(jq -r '(.kind // (.config? // {} | to_entries[]?.value.kind?)) // ""' "${OLD_CFG}" | head -1)"
[[ "${kind}" != "machine" ]] \
    || die "'${OLD}' is a machine: it is named after the host it is (ADR-026 D8). Rename the host, then re-register it with 'module-manager module adopt <address> --instance ${NEW}'"

# What moves, and what points at the old name.
files=()
for suffix in .json .json.orig .meta.json; do
    [[ -f "${CONFIG_DIR}/${OLD}${suffix}" ]] && files+=("${suffix}")
done
refs=()
shopt -s nullglob
for f in "${CONFIG_DIR}"/*.json; do
    [[ "${f}" == "${OLD_CFG}" ]] && continue
    jq -e --arg o "${OLD}" '(.node // "") == $o' "${f}" >/dev/null 2>&1 && refs+=("${f}")
done

info "${BOLD}Renaming instance ${BL}${OLD}${CL}${BOLD} → ${BL}${NEW}${CL}"
for suffix in "${files[@]}"; do info "  config/${OLD}${suffix} → config/${NEW}${suffix}"; done
for f in "${refs[@]}"; do info "  $(basename "${f}"): node ${OLD} → ${NEW}"; done
if [[ "${DRY}" -eq 1 ]]; then
    info "  --dry-run: nothing was changed"
    exit 0
fi

for suffix in "${files[@]}"; do
    mv "${CONFIG_DIR}/${OLD}${suffix}" "${CONFIG_DIR}/${NEW}${suffix}" \
        || die "could not rename config/${OLD}${suffix} — config/ is as it was"
done
for f in "${refs[@]}"; do
    tmp="${f}.rename.tmp"
    cp -p "${f}" "${tmp}"    # keep mode and owner (#525)
    if jq --arg n "${NEW}" '.node = $n' "${f}" > "${tmp}" && jq empty "${tmp}" 2>/dev/null; then
        mv -f "${tmp}" "${f}"
    else
        rm -f "${tmp}"
        warn "  could not repoint $(basename "${f}") at ${NEW} — do it by hand: module-manager module modify $(basename "${f}" .json) --set node=${NEW}"
    fi
done

info "${GN}✓${CL} ${NEW} is the instance name; its module is unchanged ($(module_of "${NEW}" 2>/dev/null || echo unknown))"
vmname="$(jq -r '(.vmname // (.config? // {} | to_entries[]?.value.vmname?)) // ""' "${CONFIG_DIR}/${NEW}.json" | head -1)"
if [[ -n "${vmname}" ]]; then
    info "  the guest is still ${BL}${vmname}${CL} — with its DNS record, firewall alias and proxy upstream."
    info "  Renaming the guest is a separate, disruptive change; this verb does not do it."
fi
