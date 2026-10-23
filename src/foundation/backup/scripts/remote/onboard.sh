#!/usr/bin/env bash
#
# Register a REMOTE (ADR-012 §1.4): another PBS that pulls OUR backups, so a
# copy of our data lives off-site with them.
#
# This is the only backup operation that grants anyone access to our own
# datastore, so it grants the least that works:
#
#   * a READ-ONLY role (DatastoreReader) — they can read and pull, never write,
#     never delete, never prune;
#   * scoped to ONE namespace, the root by default (our VM backups);
#   * with propagation OFF, so the grant does not reach child namespaces —
#     `fs/` holds our config and /etc/secrets capture, and `receive/` holds
#     other peers' data. A propagating root grant would hand a buddy both.
#
# We hold no credential on them and they hold no write on us: the copy they
# keep cannot be reached, let alone erased, from here. That is the whole point
# of pulling rather than pushing (§1.4.1).
#
# Usage: onboard.sh <name>          (config: config/remote-<name>.json)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-job.sh"
# shellcheck source=../../lib/pbs-namespace.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-namespace.sh"

NAME="${1:-}"
[[ -n "${NAME}" ]] || die "Usage: $0 <name>"

CFG="${CONFIG_DIR:-/home/tappaas/config}/remote-${NAME}.json"
[[ -f "${CFG}" ]] || die "remote config not found: ${CFG} (backup-manager peer add remote ${NAME})"

store="$(pbs_storage_name)"
authid="$(jq -r '.authId // empty' "${CFG}")"
ns="$(jq -r '.namespace // empty' "${CFG}")"
propagate="$(jq -r 'if .propagate then "true" else "false" end' "${CFG}")"
[[ -n "${authid}" ]] || die "remote-${NAME}.json has no authId (who is pulling from us?)"

# The ACL path: the datastore root when no namespace is named, else that one.
acl_path="$(_pbs_ns_acl_path "${store}" "${ns}")"

info "${BOLD}Granting ${BL}${authid}${CL}${BOLD} read-only pull access to ${BGN}${acl_path}${CL}"
if [[ "${propagate}" == "true" ]]; then
    warn "  propagate is TRUE — this grant reaches CHILD namespaces too."
    warn "  On the root that includes fs/ (config + secrets) and receive/ (other peers' data)."
fi

# The login exists only to be pulled with; create it if it is ours to create.
# An auth-id in a realm we do not own (e.g. an API token they already hold) is
# accepted as-is: we only attach the ACL.
#
# TAPPAAS_REMOTE_PASSWORD is the non-interactive path, for a caller that hands the
# same password to the puller itself — the satellite's lockdown (ADR-010 §8.4.4).
# It SETS the password, on a login that already exists too, so a re-run leaves
# the puller and the login agreeing.
if [[ "${authid}" == *"@pbs" && -n "${TAPPAAS_REMOTE_PASSWORD:-}" ]]; then
    if _pbs_user_exists "${authid}"; then
        _pbs_node_run proxmox-backup-manager user update "${authid}" --password "${TAPPAAS_REMOTE_PASSWORD}" \
            || die "could not set the password of ${authid}"
        info "  ${GN}✓${CL} login ${authid} exists — its password is set to the one handed over"
    else
        pbs_user_ensure "${authid}" "${TAPPAAS_REMOTE_PASSWORD}" || die "could not create ${authid}"
        info "  ${GN}✓${CL} created login ${authid}"
    fi
elif [[ "${authid}" == *"@pbs" ]] && ! _pbs_user_exists "${authid}"; then
    read -rsp "  Password for the new login ${authid}: " PW; echo
    [[ -n "${PW}" ]] || die "a password is required to create ${authid}"
    pbs_user_ensure "${authid}" "${PW}"
    info "  ${GN}✓${CL} created login ${authid}"
else
    info "  login ${authid} already exists (or is not ours to create) — attaching the grant only"
fi

pbs_acl_ensure "${acl_path}" DatastoreReader "${authid}" "${propagate}" \
    || die "could not grant DatastoreReader on ${acl_path} to ${authid}"
info "  ${GN}✓${CL} ${authid} may READ ${acl_path}$([[ "${propagate}" == "false" ]] && echo " (that namespace only)")"

# What they need on their side to configure the pull.
fp="$(_pbs_node_run proxmox-backup-manager cert info 2>/dev/null | sed -n 's/^Fingerprint (sha256): //p' | head -1)"
info ""
# A buddy tunnel (#796): the pulled side SERVES it, so the puller reaches our
# PBS at <net>.1 and nothing else of ours.
trole="$(jq -r '.tunnel.role // empty' "${CFG}")"
phost="$(pbs_pbs_url 2>/dev/null || echo backup.mgmt.internal)"
if [[ "${trole}" == "serve" ]]; then
    # shellcheck source=../../lib/pbs-tunnel.sh disable=SC1091
    . "${SCRIPT_DIR}/../../lib/pbs-tunnel.sh"
    tnet="$(jq -r '.tunnel.net // empty' "${CFG}")"
    tport="$(jq -r '.tunnel.listenPort // empty' "${CFG}")"
    tkey="$(jq -r '.tunnel.peerKey // empty' "${CFG}")"
    tmtu="$(jq -r '.tunnel.mtu // empty' "${CFG}")"
    hosts="$(bt_hosts "${tnet}")" || die "tunnel.net ${tnet} is not a valid /30"
    info "${BOLD}Serving buddy tunnel $(bt_serve_name "${NAME}") on udp/${tport} (${tnet})${CL}"
    ourkey="$(bt_serve_up "${NAME}" "${tnet}" "${tport}" "${tmtu}" "${tkey}")" \
        || die "could not bring up the buddy tunnel (backup-manager peer check remote ${NAME})"
    phost="${hosts% *}"
    info "  ${GN}✓${CL} tunnel instance up — only ${hosts#* } may reach ${phost}:8007 through it"
    [[ -n "${tkey}" ]] || warn "  No --peer-key yet: nobody can connect until you re-run with their key (--force)."
fi

info "${BOLD}Give the remote operator these, so they can add us as a pull source:${CL}"
info "  host:        ${phost}"
info "  datastore:   ${store}"
info "  namespace:   ${ns:-<root>}"
info "  auth id:     ${authid}"
info "  fingerprint: ${fp:-<run: proxmox-backup-manager cert info>}"
if [[ "${trole}" == "serve" ]]; then
    sj="${CONFIG_DIR:-/home/tappaas/config}/site.json"
    info ""
    info "${BOLD}On a TAPPaaS system they run this (fill in the endpoint):${CL}"
    while IFS= read -r l; do info "  ${l}"; done < <(bt_dial_command "${sj}" "${store}" "${tnet}" "${ourkey}" "${tport}" "${tmtu}")
    [[ "$(jq -r '(.locations[.primaryLocation // ""] // .location // {}).country // empty' "${sj}" 2>/dev/null)" != "" ]] \
        || warn "  site.json records no primary location — add it (site-manager location add <name> --country … --timezone … --primary) so they need not type it"
fi
