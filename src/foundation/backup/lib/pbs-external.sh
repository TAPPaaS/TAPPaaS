# shellcheck shell=bash
# pbs-external.sh — consume an externally-managed PBS (ADR-012 §1.3, #456).
#
# The site already runs a PBS TAPPaaS did not provision — on the LAN (#456), at
# a satellite (ADR-010), or a third party. The module CONSUMES it by URL:
#
#   * it discovers no storage and installs nothing
#   * it registers that PBS as a Proxmox `pbs` storage under the module's own
#     pbsStorageName, so the existing managed-job machinery (pbs-job.sh) targets
#     it with no further wiring — clients push there exactly as they would to a
#     local PBS (§1.4), with a write-no-delete credential the REMOTE issues
#   * it never creates a datastore and never touches what is already stored:
#     pre-existing snapshots stay listable and restorable (§4.2)
#
# The credential is prompt-not-store (§2.5): the operator is asked at onboarding
# and the answer goes into the Proxmox storage entry, never into backup.json.
#
# Requires: common-install-routines.sh and lib/pbs-storage.sh sourced first.

# ── Pure helpers (no cluster access — unit-testable) ─────────────────

# Whether `use-external` may flip this placement state. Consuming an external
# PBS is PERMANENT (§2.1), so it is only offered where nothing local would be
# orphaned by it: an unresolved config, a shim, or an already-external one.
# A live local PBS (node:<name>) is refused — abandoning a datastore full of
# backups must be a deliberate reinstall, not a one-word command.
#   rc 0 = allowed, rc 1 = refused
pbs_external_allowed() {
    case "${1:-}" in
        ""|shim|external|remote-only) return 0 ;;
        *) return 1 ;;
    esac
}

# The datastore name to consume on the external PBS: an explicit choice, else
# the module's own pbsStorageName (the common case — same name both sides).
pbs_external_datastore() {
    local explicit="${1:-}" fallback="${2:-tappaas_backup}"
    [[ -n "${explicit}" ]] && printf '%s\n' "${explicit}" || printf '%s\n' "${fallback}"
}

# ── Cluster ops ──────────────────────────────────────────────────────

# Register the external PBS at <url> as the module's backup storage. The storage
# NAME is the module's pbsStorageName, so nothing downstream needs to know the
# PBS is external. Args: url storageName datastore namespace user pw [fp] [zone]
pbs_external_register() {
    local url="$1" sname="$2" store="$3" ns="$4" user="$5" pw="$6" fp="${7:-}" zone="${8:-mgmt}"
    local host port
    host="$(_pbs_url_host "${url}")"
    port="$(_pbs_url_port "${url}")"
    [[ -n "${host}" ]] || { warn "pbs_external_register: could not parse a host out of '${url}'"; return 1; }
    info "${BOLD}Registering externally-managed PBS ${BGN}${host}${CL}${BOLD} (datastore ${BGN}${store}${CL}${BOLD}) as storage ${BGN}${sname}${CL}${BOLD}${CL}"
    pbs_storage_register "${sname}" "${host}" "${store}" "${ns}" "${user}" "${pw}" "${fp}" "${port}" "${zone}"
}

# Confirm the registered storage is actually usable — active, and its existing
# contents listable. Read-only: this is the check that #456's "existing
# snapshots stay restorable" is true, so it must never write.
pbs_external_verify() {
    local sname="$1" zone="${2:-mgmt}" node out
    node="$(get_node_hostname 0)"
    out="$(ssh -n -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.${zone}.internal" "pvesm status --storage ${sname}" 2>&1)" || {
        warn "  storage ${sname} is not reachable:"; printf '%s\n' "${out}" | sed 's/^/    /'; return 1; }
    grep -q "active" <<<"${out}" || { warn "  storage ${sname} is registered but not active"; return 1; }
    info "  ${GN}✓${CL} storage ${BL}${sname}${CL} is active"
    out="$(ssh -n -o ConnectTimeout=20 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.${zone}.internal" "pvesh get /nodes/${node}/storage/${sname}/content --output-format json" 2>/dev/null)" || out=""
    if [[ -n "${out}" ]]; then
        info "  ${GN}✓${CL} $(jq -r 'length' <<<"${out}" 2>/dev/null || echo '?') existing backup(s) visible and restorable (nothing was modified)"
    fi
    return 0
}
