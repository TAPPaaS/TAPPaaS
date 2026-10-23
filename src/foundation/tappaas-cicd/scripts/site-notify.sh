#!/usr/bin/env bash
# site-notify.sh — mail the site owner through a Proxmox node (ADR-007e v1.3).
#
# The site notification target: the notice goes to site.json `email` through a
# Proxmox node's own mail system (postfix/sendmail, the channel PVE already uses
# for its own mail) — the cicd has no mailer, and a notice that stays on the
# cicd reaches no one. Nodes are tried in order until one accepts the mail.
# The failed-sweep notice (#651) and the security scan (ADR-011) send through it.
#
# Usage: site-notify.sh --subject <text> [--what <label>] [--breadcrumb FILE] [--dry-run] < body
#   --subject     what follows "[TAPPaaS <site>] " in the Subject header
#   --what        how the log and breadcrumb name the notice (default "notice")
#   --breadcrumb  append a timestamped line saying whether it was sent
#   --dry-run     print the mail instead of sending it
# The body is read from stdin; a "Site: … — host …" line is put in front of it.
#
# Environment:
#   TAPPAAS_CONFIG_DIR   config dir (default /home/tappaas/config; tests)
#   TAPPAAS_NOTIFY_SSH   ssh command (default ssh; tests)
#   TAPPAAS_NOTIFY_NODES space-separated node names (default: the site's nodes; tests)
#
# Exit codes: 0 sent (or nothing to send to), 1 no node accepted the mail or
# the address is not a single address, 2 bad arguments.

set -euo pipefail

CONFIG_DIR="${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}"
SSH="${TAPPAAS_NOTIFY_SSH:-ssh}"
DRY_RUN=0
SUBJECT=""
WHAT="notice"
BREADCRUMB=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --subject)    SUBJECT="${2:-}"; shift 2 ;;
        --what)       WHAT="${2:-}"; shift 2 ;;
        --breadcrumb) BREADCRUMB="${2:-}"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)    sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "site-notify: unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ -n "${SUBJECT}" ]] || { echo "site-notify: --subject is required" >&2; exit 2; }
# It goes into a header: one line of printable characters.
SUBJECT="$(printf '%s' "${SUBJECT}" | tr -d '\r\n' | tr -c '[:print:]' ' ')"
BODY="$(cat)"

log() { echo "site-notify: $*"; }
breadcrumb() { [[ -n "${BREADCRUMB}" ]] || return 0; printf '%s %s\n' "$(date -Is)" "$*" >> "${BREADCRUMB}" 2>/dev/null || true; }

SITE="${CONFIG_DIR}/site.json"
to="$(jq -r '.email // empty' "${SITE}" 2>/dev/null || true)"
site_name="$(jq -r '.name // empty' "${SITE}" 2>/dev/null || true)"
# It goes into the Subject header: a site code, or nothing.
[[ "${site_name}" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || site_name=""

# The site's public domain, which is what tells one site from another in an
# inbox: a site code like "rossen" and a host like "tappaas-cicd" look the same
# from every installation. It lives on the environments, not on the site — take
# the default environment's primary domain, else mgmt's, else the domain of the
# address the notice goes to.
site_domain=""
for _envname in "$(jq -r '.defaultEnvironment // empty' "${SITE}" 2>/dev/null || true)" mgmt; do
    [[ -n "${_envname}" ]] || continue
    _envfile="${CONFIG_DIR}/environments/${_envname}.json"
    [[ -f "${_envfile}" ]] || continue
    site_domain="$(jq -r '.domains.primary // empty' "${_envfile}" 2>/dev/null || true)"
    # `[[ … ]] && break` would end the SCRIPT under set -e on the last iteration.
    if [[ -n "${site_domain}" ]]; then break; fi
done
[[ -n "${site_domain}" ]] || site_domain="${to##*@}"
# It becomes part of a mail header: a hostname, or nothing.
[[ "${site_domain}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || site_domain=""
if [[ -z "${to}" ]]; then
    log "site.json has no email — ${WHAT} not sent (set one: site-manager site modify --email <address>)"
    breadcrumb "${WHAT} NOT sent: site.json has no email"
    exit 0
fi
# It becomes a mail header: one plain address or nothing.
if ! [[ "${to}" =~ ^[^@[:space:]\<\>,\;\"\(\)]+@[^@[:space:]\<\>,\;\"\(\)]+$ ]]; then
    log "site.json email is not a single address — ${WHAT} not sent"
    breadcrumb "${WHAT} NOT sent: site.json email is not a single address"
    exit 1
fi

if [[ -n "${TAPPAAS_NOTIFY_NODES:-}" ]]; then
    read -r -a nodes <<<"${TAPPAAS_NOTIFY_NODES}"
else
    # The cluster's nodes (their pvehost instances, cluster-nodes.sh).
    for _cnl in "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/cluster-nodes.sh" /home/tappaas/bin/cluster-nodes.sh; do
        # shellcheck source=/dev/null
        [[ -r "${_cnl}" ]] && { . "${_cnl}"; break; }
    done
    nodes=()
    declare -F tappaas_cluster_nodes >/dev/null 2>&1 \
        && mapfile -t nodes < <(tappaas_cluster_nodes "${CONFIG_DIR}" 2>/dev/null | grep -E '^[A-Za-z0-9_-]+$')
    [[ ${#nodes[@]} -gt 0 ]] || nodes=(tappaas1)
fi

host="$(hostname 2>/dev/null || echo tappaas-cicd)"
# The domain leads: it is the one part of this that names THIS installation.
_label="${site_domain:-${site_name}}"
subject="[TAPPaaS${_label:+ ${_label}}] ${SUBJECT}"
body="Site: ${site_name:-(unnamed)}${site_domain:+ (${site_domain})} — host ${host}

${BODY}"

ssh_node() {
    "${SSH}" -n -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=no -o ControlPath=none \
        "root@$1.mgmt.internal" "$2"
}

for node in "${nodes[@]}"; do
    # The sender Proxmox is configured with (Datacenter → email_from), if any.
    from="$(ssh_node "${node}" "pvesh get /cluster/options --output-format json" 2>/dev/null \
            | jq -r '.email_from // empty' 2>/dev/null || true)"
    from_hdr=""
    [[ "${from}" =~ ^[^@[:space:]\<\>,\;\"\(\)]+@[^@[:space:]\<\>,\;\"\(\)]+$ ]] && from_hdr="From: TAPPaaS <${from}>"$'\n'
    mail="$(printf 'To: %s\n%sSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
        "${to}" "${from_hdr}" "${subject}" "${body}")"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        printf '%s\n' "${mail}"
        log "dry run — would send through ${node}"
        exit 0
    fi
    if printf '%s\n' "${mail}" | "${SSH}" -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=no -o ControlPath=none \
            "root@${node}.mgmt.internal" "/usr/sbin/sendmail -t -oi"; then
        log "${WHAT} sent to ${to} through ${node}"
        breadcrumb "${WHAT} sent to ${to} through ${node}"
        exit 0
    fi
    log "${node} did not take the mail — trying the next node"
done

log "no node accepted the mail — ${WHAT} NOT sent"
breadcrumb "${WHAT} NOT sent: no node accepted the mail"
exit 1
