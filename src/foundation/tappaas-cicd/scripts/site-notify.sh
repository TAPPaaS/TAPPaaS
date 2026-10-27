#!/usr/bin/env bash
# site-notify.sh — mail the site owner through a Proxmox node (ADR-007e v1.3).
#
# The site notification target: the notice goes to site.json `email` through a
# Proxmox node's own mail system (postfix/sendmail, the channel PVE already uses
# for its own mail) — the cicd has no mailer, and a notice that stays on the
# cicd reaches no one. Nodes are tried in order until one accepts the mail.
# The failed-sweep notice (#651), the log alerts (#126) and the security scan
# (ADR-011) send through it.
#
# An ALERT and its RESOLVED are one condition, named by --key (#883): the alert
# is recorded as open, and a --resolve for that key is sent only while it is
# open — as a reply to the alert, so a mail client threads the two — and then
# closes it. A --resolve for a key that is not open sends nothing.
#
# Usage: site-notify.sh --subject <text> [--what <label>] [--breadcrumb FILE]
#                       [--to ADDR] [--attach FILE] [--key K [--resolve]] [--dry-run] < body
#        site-notify.sh --list-open
#   --subject     what follows "[TAPPaaS <site>] " in the Subject header
#   --what        how the log and breadcrumb name the notice (default "notice")
#   --breadcrumb  append a timestamped line saying whether it was sent
#   --to          one address instead of site.json `email` (a test, a forward)
#   --attach      attach FILE (a support bundle, tappaas-support-bundle.sh); the
#                 body then says to forward it to site.json `supportEmail`.
#                 Over 5 MB it is not attached and the body says where it is.
#   --key         the condition this notice is about (letters, digits, . _ : @ -)
#   --resolve     it has cleared: send only if the key is open, then close it
#   --list-open   print the open keys, one per line: key, first sent, subject
#   --dry-run     print the mail instead of sending it (records nothing)
# The body is read from stdin; a "Site: … — host …" line is put in front of it.
#
# Environment:
#   TAPPAAS_CONFIG_DIR   config dir (default /home/tappaas/config; tests)
#   TAPPAAS_NOTIFY_SSH   ssh command (default ssh; tests)
#   TAPPAAS_NOTIFY_NODES space-separated node names (default: the site's nodes; tests)
#   TAPPAAS_ALERT_STATE  where open keys are kept (default /var/lib/tappaas/alerts-open)
#
# Exit codes: 0 sent (or nothing to send to, or nothing open to resolve), 1 no
# node accepted the mail or the address is not a single address, 2 bad arguments.

set -euo pipefail

CONFIG_DIR="${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}"
SSH="${TAPPAAS_NOTIFY_SSH:-ssh}"
STATE_DIR="${TAPPAAS_ALERT_STATE:-/var/lib/tappaas/alerts-open}"
DRY_RUN=0
SUBJECT=""
WHAT="notice"
BREADCRUMB=""
TO=""
ATTACH=""
KEY=""
RESOLVE=0
LIST_OPEN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --subject)    SUBJECT="${2:-}"; shift 2 ;;
        --what)       WHAT="${2:-}"; shift 2 ;;
        --breadcrumb) BREADCRUMB="${2:-}"; shift 2 ;;
        --to)         TO="${2:-}"; shift 2 ;;
        --attach)     ATTACH="${2:-}"; shift 2 ;;
        --key)        KEY="${2:-}"; shift 2 ;;
        --resolve)    RESOLVE=1; shift ;;
        --list-open)  LIST_OPEN=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)    sed -n '2,38p' "$0"; exit 0 ;;
        *) echo "site-notify: unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ "${LIST_OPEN}" -eq 1 ]]; then
    for f in "${STATE_DIR}"/*; do
        [[ -f "${f}" ]] || continue
        jq -r '[.key, .sent, .subject] | @tsv' "${f}" 2>/dev/null || true
    done
    exit 0
fi

[[ -n "${SUBJECT}" ]] || { echo "site-notify: --subject is required" >&2; exit 2; }
# It names a file under STATE_DIR: no slash, no leading dot.
if [[ -n "${KEY}" ]] && ! [[ "${KEY}" =~ ^[A-Za-z0-9_@-][A-Za-z0-9_.:@-]{0,127}$ ]]; then
    echo "site-notify: --key must be letters, digits and . _ : @ - (at most 128)" >&2; exit 2
fi
[[ "${RESOLVE}" -eq 0 || -n "${KEY}" ]] || { echo "site-notify: --resolve needs --key" >&2; exit 2; }
[[ -z "${ATTACH}" || -r "${ATTACH}" ]] || { echo "site-notify: --attach: cannot read ${ATTACH}" >&2; exit 2; }
# It goes into a header: one line of printable characters.
SUBJECT="$(printf '%s' "${SUBJECT}" | tr -d '\r\n' | tr -c '[:print:]' ' ')"
BODY="$(cat)"

log() { echo "site-notify: $*"; }
breadcrumb() { [[ -n "${BREADCRUMB}" ]] || return 0; printf '%s %s\n' "$(date -Is)" "$*" >> "${BREADCRUMB}" 2>/dev/null || true; }
single_address() { [[ "$1" =~ ^[^@[:space:]\<\>,\;\"\(\)]+@[^@[:space:]\<\>,\;\"\(\)]+$ ]]; }

# A resolve with nothing open is the common case (every good sweep asks): it
# needs no site.json, no node and no mail.
STATE_FILE="${KEY:+${STATE_DIR}/${KEY}}"
if [[ "${RESOLVE}" -eq 1 && ! -f "${STATE_FILE}" ]]; then
    log "nothing open for ${KEY} — ${WHAT} not sent"
    exit 0
fi

SITE="${CONFIG_DIR}/site.json"
to="${TO:-$(jq -r '.email // empty' "${SITE}" 2>/dev/null || true)}"
support="$(jq -r '.supportEmail // empty' "${SITE}" 2>/dev/null || true)"
single_address "${support}" || support=""
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
if ! single_address "${to}"; then
    log "${TO:+--to}${TO:-site.json email} is not a single address — ${WHAT} not sent"
    breadcrumb "${WHAT} NOT sent: ${TO:+--to}${TO:-site.json email} is not a single address"
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

# ── the attachment (#883) ─────────────────────────────────────────────
MAX_ATTACH=$(( 5 * 1024 * 1024 ))
attach_name=""
if [[ -n "${ATTACH}" ]]; then
    attach_name="$(printf '%s' "$(basename "${ATTACH}")" | tr -c 'A-Za-z0-9._-' '_')"
    size="$(stat -c %s "${ATTACH}" 2>/dev/null || stat -f %z "${ATTACH}")"
    if (( size > MAX_ATTACH )); then
        body+="

The support bundle is too large to mail ($(( size / 1024 )) KB): it is on
${host} at ${ATTACH}."
        attach_name=""
    else
        body+="

--
Attached: ${attach_name}, a support bundle — the logs of this event and the
site's configuration with personal data and secrets removed (manifest.json in
it lists what is there and what was removed).
To have the TAPPaaS maintainers look at it, forward this mail with its
attachment to ${support:-your TAPPaaS support contact}."
    fi
fi

# ── threading an ALERT and its RESOLVED (#883) ────────────────────────
msgid=""; reply_to=""
if [[ -n "${KEY}" ]]; then
    msgid="<$(date +%s).$$.${RANDOM}.${KEY//[^A-Za-z0-9.-]/-}@${site_domain:-tappaas.invalid}>"
    [[ -f "${STATE_FILE}" ]] && reply_to="$(jq -r '.message_id // empty' "${STATE_FILE}" 2>/dev/null || true)"
    [[ "${reply_to}" =~ ^\<[^[:space:]\<\>]+\>$ ]] || reply_to=""
fi
record_open() {
    [[ -n "${KEY}" ]] || return 0
    if [[ "${RESOLVE}" -eq 1 ]]; then rm -f "${STATE_FILE}"; return 0; fi
    # A repeat keeps the first alert: replies thread to it, and "sent" is when
    # the condition began to be reported.
    [[ -f "${STATE_FILE}" ]] && return 0
    mkdir -p "${STATE_DIR}" 2>/dev/null || true
    jq -n --arg key "${KEY}" --arg sent "$(date -Is)" --arg subject "${subject}" --arg id "${msgid}" \
        '{key: $key, sent: $sent, subject: $subject, message_id: $id}' > "${STATE_FILE}" 2>/dev/null \
        || log "could not record ${KEY} as open (${STATE_DIR})"
}

# The mail: headers, then a plain body or, with an attachment, multipart/mixed.
compose() {  # compose <from header line or "">
    printf 'To: %s\n%sSubject: %s\n' "${to}" "$1" "${subject}"
    [[ -n "${msgid}" ]] && printf 'Message-ID: %s\n' "${msgid}"
    [[ -n "${reply_to}" ]] && printf 'In-Reply-To: %s\nReferences: %s\n' "${reply_to}" "${reply_to}"
    if [[ -z "${attach_name}" ]]; then
        printf 'Content-Type: text/plain; charset=UTF-8\n\n%s\n' "${body}"
        return
    fi
    local b="tappaas-$(date +%s)-$$"
    printf 'MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary="%s"\n\n' "${b}"
    printf -- '--%s\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n%s\n\n' "${b}" "${body}"
    printf -- '--%s\nContent-Type: application/gzip; name="%s"\nContent-Transfer-Encoding: base64\n' "${b}" "${attach_name}"
    printf 'Content-Disposition: attachment; filename="%s"\n\n' "${attach_name}"
    base64 -w 76 "${ATTACH}" 2>/dev/null || base64 -b 76 -i "${ATTACH}"
    printf -- '\n--%s--\n' "${b}"
}

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
    mail="$(compose "${from_hdr}")"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        printf '%s\n' "${mail}"
        log "dry run — would send through ${node}"
        exit 0
    fi
    if printf '%s\n' "${mail}" | "${SSH}" -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=no -o ControlPath=none \
            "root@${node}.mgmt.internal" "/usr/sbin/sendmail -t -oi"; then
        log "${WHAT} sent to ${to} through ${node}"
        breadcrumb "${WHAT} sent to ${to} through ${node}${KEY:+ (${KEY}$([[ "${RESOLVE}" -eq 1 ]] && echo ", resolved"))}"
        record_open
        exit 0
    fi
    log "${node} did not take the mail — trying the next node"
done

log "no node accepted the mail — ${WHAT} NOT sent"
breadcrumb "${WHAT} NOT sent: no node accepted the mail"
exit 1
