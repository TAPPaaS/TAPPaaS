#!/usr/bin/env bash
# tappaas-support-bundle.sh — pack what the maintainers need to look at a problem (#883).
#
# A support bundle is a tarball an alert mail carries (site-notify.sh --attach):
# the journal of the unit that went wrong, the module test logs of that run,
# the site's state (versions, failed units, the cluster, open alerts) and its
# configuration with personal data and secrets removed (support-anonymize.py,
# which also scrubs the logs). The operator decides whether it goes further:
# the mail says to forward it to site.json `supportEmail`. Nothing here sends
# anything to the maintainers.
#
# The bundle and its map (original → replacement, to decode a supporter's
# question) stay in --out, mode 0600; the newest 20 are kept.
#
# Usage: tappaas-support-bundle.sh --reason TEXT [--unit U]... [--since T [--until T]]
#                                  [--out DIR] [--no-cluster]
#        tappaas-support-bundle.sh --test [--to ADDR] [--dry-run]
#   --reason     why it was made; goes into manifest.json
#   --unit       a systemd unit whose journal goes in: its last run, or the
#                --since/--until window when given (repeatable)
#   --since/--until  the window (journalctl's time syntax); also selects the
#                module test logs (~/logs) written in it. Default: the first
#                unit's last run, else the last two hours
#   --no-cluster do not ask a node for the cluster's state
#   --test       build a bundle from the last update sweep and send it as a test
#                ALERT, then its RESOLVED (proves the whole path; no action needed)
#   --to         --test only: send to this address instead of site.json email
# Prints the bundle's path on stdout; progress goes to stderr.
#
# Environment (tests):
#   TAPPAAS_CONFIG_DIR   config dir (default /home/tappaas/config)
#   TAPPAAS_LOG_DIR      module test logs (default /home/tappaas/logs)
#   TAPPAAS_SUPPORT_DIR  default --out (default /var/lib/tappaas/support)
#   TAPPAAS_SITE_NOTIFY  the mailer (default site-notify.sh next to this file)
#   TAPPAAS_NOTIFY_SSH   ssh command for the cluster read (default ssh)
#
# Exit: 0 bundle written (and, with --test, both mails sent) · 1 it could not
# be written or a mail did not go out · 2 bad arguments.

set -uo pipefail

HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
CONFIG_DIR="${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}"
LOG_DIR="${TAPPAAS_LOG_DIR:-/home/tappaas/logs}"
OUT="${TAPPAAS_SUPPORT_DIR:-/var/lib/tappaas/support}"
SITE_NOTIFY="${TAPPAAS_SITE_NOTIFY:-${HERE}/site-notify.sh}"
SSH="${TAPPAAS_NOTIFY_SSH:-ssh}"
KEEP=20
MAX_LOGS=60
MAX_LOG_BYTES=$(( 4 * 1024 * 1024 ))
MAX_JOURNAL_BYTES=$(( 8 * 1024 * 1024 ))

REASON=""; SINCE=""; UNTIL=""; CLUSTER=1; TEST=0; TO=""; DRY_RUN=0
UNITS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reason)     REASON="${2:-}"; shift 2 ;;
        --unit)       UNITS+=("${2:-}"); shift 2 ;;
        --since)      SINCE="${2:-}"; shift 2 ;;
        --until)      UNTIL="${2:-}"; shift 2 ;;
        --out)        OUT="${2:-}"; shift 2 ;;
        --no-cluster) CLUSTER=0; shift ;;
        --test)       TEST=1; shift ;;
        --to)         TO="${2:-}"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)    sed -n '2,37p' "$0"; exit 0 ;;
        *) echo "tappaas-support-bundle: unknown option: $1" >&2; exit 2 ;;
    esac
done
say() { echo "support-bundle: $*" >&2; }
strip() { sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'; }

# ── --test: the whole path, on a good day ────────────────────────────
if [[ "${TEST}" -eq 1 ]]; then
    bundle="$("$0" --reason "test of the alert mail and support bundle path (#883)" \
        --unit update-tappaas.service --out "${OUT}")" || { say "the bundle could not be written"; exit 1; }
    result="$(jq -r '"ok=\(.ok) succeeded=\(.succeeded // "?")/\(.total // "?") \(.start_time // "") → \(.end_time // "")"' \
        "${CONFIG_DIR}/last-update-result.json" 2>/dev/null || echo "no last-update-result.json")"
    args=(--key test:support-bundle --what "test alert")
    [[ -n "${TO}" ]] && args+=(--to "${TO}")
    [[ "${DRY_RUN}" -eq 1 ]] && args+=(--dry-run)
    out=/dev/stderr; [[ "${DRY_RUN}" -eq 1 ]] && out=/dev/stdout
    "${SITE_NOTIFY}" "${args[@]}" --attach "${bundle}" \
        --subject "ALERT: TEST — support bundle check (no action needed)" > "${out}" <<EOF || exit 1
This is a test of the TAPPaaS alert mail, run by hand (tappaas-support-bundle.sh --test).
Nothing is wrong. A real alert that carries a support bundle looks like this.

The bundle is made from the last update sweep: ${result}
A second mail, RESOLVED, follows; your mail client should show it in this thread.
EOF
    [[ "${DRY_RUN}" -eq 1 ]] && { echo "${bundle}"; exit 0; }
    "${SITE_NOTIFY}" "${args[@]}" --resolve \
        --subject "RESOLVED: TEST — support bundle check" >&2 <<EOF || exit 1
The test alert is cleared. This mail answers it, so it should appear in the same
thread. Nothing else to do.
EOF
    echo "${bundle}"
    exit 0
fi

[[ -n "${REASON}" ]] || { echo "tappaas-support-bundle: --reason is required" >&2; exit 2; }

site_name="$(jq -r '.name // empty' "${CONFIG_DIR}/site.json" 2>/dev/null || true)"
[[ "${site_name}" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || site_name="site"
stamp="$(date +%Y%m%d-%H%M%S)"
name="tappaas-support-${site_name}-${stamp}"
mkdir -p "${OUT}" && chmod 0700 "${OUT}" 2>/dev/null
work="$(mktemp -d "${OUT}/.build.XXXXXX")" || { say "cannot write in ${OUT}"; exit 1; }
trap 'rm -rf "${work}"' EXIT
stage="${work}/${name}"
mkdir -p "${stage}/journal" "${stage}/logs" "${stage}/state"

# ── the window ───────────────────────────────────────────────────────
# The first unit's last run, from its start: InactiveExitTimestamp covers its
# ExecStartPre steps, which ExecMainStartTimestamp would miss.
if [[ -z "${SINCE}" && ${#UNITS[@]} -gt 0 ]]; then
    t="$(systemctl show "${UNITS[0]}" -p InactiveExitTimestamp --value 2>/dev/null || true)"
    [[ -n "${t}" && "${t}" != "n/a" ]] && SINCE="$(date -d "${t}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
fi
[[ -n "${SINCE}" ]] || SINCE="$(date -d '-2 hours' '+%Y-%m-%d %H:%M:%S')"
since_epoch="$(date -d "${SINCE}" +%s 2>/dev/null || echo 0)"
until_epoch="$(date -d "${UNTIL:-now}" +%s 2>/dev/null || date +%s)"

# ── journals ─────────────────────────────────────────────────────────
for u in "${UNITS[@]}"; do
    [[ "${u}" =~ ^[A-Za-z0-9@_.:-]+$ ]] || { say "skipping unit '${u}': not a unit name"; continue; }
    args=(-u "${u}" --since "${SINCE}" --no-pager -o short-iso)
    [[ -n "${UNTIL}" ]] && args+=(--until "${UNTIL}")
    journalctl "${args[@]}" 2>&1 | strip | tail -c "${MAX_JOURNAL_BYTES}" > "${stage}/journal/${u}.log"
done

# ── the module test logs of the window, newest first, within a budget ──
nlogs=0; bytes=0
if [[ -d "${LOG_DIR}" ]]; then
    while IFS= read -r f; do
        m="$(stat -c %Y "${f}" 2>/dev/null || echo 0)"
        (( m >= since_epoch && m <= until_epoch + 60 )) || continue
        s="$(stat -c %s "${f}" 2>/dev/null || echo 0)"
        (( nlogs < MAX_LOGS && bytes + s <= MAX_LOG_BYTES )) || break
        strip < "${f}" > "${stage}/logs/$(basename "${f}")"
        nlogs=$((nlogs + 1)); bytes=$((bytes + s))
    done < <(ls -1t "${LOG_DIR}"/*.log 2>/dev/null)
fi

# ── the site's state ─────────────────────────────────────────────────
{
    echo "host: $(hostname)"
    echo "made: $(date -Is)"
    jq -r '.repositories[]? | "\(.name)\t\(.path // "")\t\(.branch // "")"' "${CONFIG_DIR}/site.json" 2>/dev/null \
        | while IFS=$'\t' read -r rn rp rb; do
            [[ -d "${rp}/.git" ]] || continue
            printf '%s: %s (branch %s) %s\n' "${rn}" \
                "$(git -C "${rp}" describe --tags --always --dirty 2>/dev/null)" "${rb:-?}" \
                "$(git -C "${rp}" log -1 --format='%h %cI %s' 2>/dev/null)"
        done
    echo "channel: $(jq -r '.channel // "?"' "${CONFIG_DIR}/site.json" 2>/dev/null)"
} > "${stage}/state/versions.txt"
systemctl --failed --no-pager 2>&1 | strip > "${stage}/state/failed-units.txt"
timeout 60 module-manager list 2>&1 | strip > "${stage}/state/modules.txt" || true
df -h / /home /var > "${stage}/state/disk.txt" 2>&1
"${SITE_NOTIFY}" --list-open > "${stage}/state/alerts-open.txt" 2>&1 || true
for b in update-tappaas.failures alerts.log; do
    [[ -f "${CONFIG_DIR}/${b}" ]] && tail -n 50 "${CONFIG_DIR}/${b}" > "${stage}/state/${b}.tail"
done
if [[ "${CLUSTER}" -eq 1 ]]; then
    for _cnl in "${HERE}/../lib/cluster-nodes.sh" /home/tappaas/bin/cluster-nodes.sh; do
        # shellcheck source=/dev/null
        [[ -r "${_cnl}" ]] && { . "${_cnl}"; break; }
    done
    nodes=()
    declare -F tappaas_cluster_nodes >/dev/null 2>&1 \
        && mapfile -t nodes < <(tappaas_cluster_nodes "${CONFIG_DIR}" 2>/dev/null | grep -E '^[A-Za-z0-9_-]+$')
    for node in "${nodes[@]}"; do
        if timeout 60 "${SSH}" -n -o BatchMode=yes -o ConnectTimeout=10 "root@${node}.mgmt.internal" \
            'echo "== pvecm status"; pvecm status; echo; echo "== ha-manager status"; ha-manager status;
             echo; echo "== guests"; pvesh get /cluster/resources --type vm --output-format json \
               | jq -r ".[] | [.vmid, .name, .node, .status, .hastate // \"\"] | @tsv"' \
            > "${stage}/state/cluster.txt" 2>&1; then
            break
        fi
    done
fi

# ── anonymize: the config goes in, everything already here is scrubbed ──
map="${OUT}/${name}.map.json"
summary="$(python3 -I "${HERE}/support-anonymize.py" --config-dir "${CONFIG_DIR}" --stage "${stage}" --map "${map}")" \
    || { say "anonymizing failed — no bundle written (nothing unscrubbed leaves this host)"; exit 1; }

jq -n --arg reason "${REASON}" --arg made "$(date -Is)" --arg host "$(hostname)" --arg site "${site_name}" \
      --arg since "${SINCE}" --arg until "${UNTIL:-$(date '+%Y-%m-%d %H:%M:%S')}" \
      --argjson units "$(printf '%s\n' "${UNITS[@]+"${UNITS[@]}"}" | jq -R . | jq -s 'map(select(. != ""))')" \
      --argjson logs "${nlogs}" --argjson anon "${summary}" \
      '{reason: $reason, made: $made, site: $site, host: $host, window: {since: $since, until: $until},
        journals: $units, module_test_logs: $logs, anonymized: $anon,
        contents: {"journal/": "the units named, over the window",
                   "logs/": "module test logs written in the window",
                   "state/": "versions, failed units, modules, disk, open alerts, breadcrumbs, the cluster",
                   "config/": "the site configuration, anonymized"}}' > "${stage}/manifest.json"

bundle="${OUT}/${name}.tar.gz"
( umask 077; tar -C "${work}" -czf "${bundle}" "${name}" ) || { say "tar failed"; exit 1; }
say "wrote ${bundle} ($(( $(stat -c %s "${bundle}") / 1024 )) KB; map ${map})"

# Keep the newest few; a bundle and its map go together.
ls -1t "${OUT}"/tappaas-support-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while IFS= read -r old; do
    rm -f "${old}" "${old%.tar.gz}.map.json"
done
echo "${bundle}"
