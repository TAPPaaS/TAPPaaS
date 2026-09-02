# shellcheck shell=bash
# report-lib.sh — shared mechanism for the cluster services' report-service.sh
# (ADR-020 D7, the actual-state read side).
#
# Every provider service reports ACTUAL state as one flat JSON object so the
# manager can run ONE differ against it. The MECHANISM of getting there is the
# same for a QEMU VM and an LXC container — parse args, load the module config,
# find the guest cluster-wide, read its config, protect stdout — while the FIELD
# SET genuinely differs (a container has no BIOS; its disk is `rootfs`, not
# `scsi0`; Proxmox calls its name `hostname`, not `name`). So the mechanism
# lives here and each reporter builds its own jq object.
#
# Sourced by:
#   services/vm/report-service.sh    (qemu, via qm)
#   services/lxc/report-service.sh   (lxc,  via pct)
#
# Requires: jq, and common-install-routines.sh sourced first (for check_json,
# normalize_module_config, get_config_value, get_node_hostname, the log helpers).
#
# Contract for the caller:
#   report_begin "<guest-type>" "$@"   parse args, locate + read the guest
#   report_field <key>                 one `qm/pct config` value ("" if absent)
#   report_field_or <key> <default>    …with the HYPERVISOR's implicit default
#   report_emit '<jq program>' <args>  emit the object on the real stdout
#
# and these variables, set by report_begin:
#   REPORT_MODULE  REPORT_VMID  REPORT_NODE  REPORT_STATUS
#
# EXIT CODES. Each one names a DIFFERENT operator action, because the consumer
# (module-manager's inspect) has three distinct diagnostics to print and must not
# have to pattern-match stderr text to tell them apart:
#
#   0  reported
#   2  usage error (no module name, unknown flag)
#   3  the module has no readable config — it is not deployed here
#   4  no cluster node answered — the cluster, not the guest, is the problem
#   5  the guest is not present on any node (it may be intentionally absent:
#      an archived module has no guest by design)
#   6  the guest was located but its config could not be read on its own node
#
# Anything else is a bug in this library.

readonly REPORT_MGMT="mgmt"
readonly REPORT_CONFIG_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}"
REPORT_SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
                 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

# Set by report_begin, read by the sourcing reporter (hence "unused" here).
# shellcheck disable=SC2034
REPORT_MODULE=""
REPORT_VMID=""
REPORT_NODE=""
# shellcheck disable=SC2034
REPORT_STATUS=""
REPORT_LIVE=""
REPORT_CLI=""

# STDOUT IS THE CONTRACT: exactly one JSON object, nothing else.
#
# The shared logging helpers write to stdout (info/debug/warn do; only
# error/fatal/die go to stderr), and check_json warns about any field
# module-fields.json does not declare — so a module with one undeclared field
# emitted a warning line ahead of the JSON and every consumer's parse failed.
# Rather than chase each call site, hold the real stdout on fd 3 and point
# stdout at stderr; report_emit writes to fd 3. Diagnostics stay visible to a
# human, and machine output cannot be contaminated by a library that later
# decides to print something new.
report_guard_stdout() { exec 3>&1 1>&2; }

report_usage() {
    echo "Usage: $(basename "${0}") [--vmid ID] <module-name>" >&2
    exit 2
}

# report_begin <guest-type: qemu|lxc> "$@"
report_begin() {
    local guest="$1"; shift
    case "${guest}" in
        qemu) REPORT_CLI="qm" ;;
        lxc)  REPORT_CLI="pct" ;;
        *)    echo "report_begin: unknown guest type '${guest}'" >&2; exit 2 ;;
    esac

    local vmid_override=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vmid)    vmid_override="${2:-}"; [[ -n "${vmid_override}" ]] || { echo "--vmid requires a value" >&2; exit 2; }; shift ;;
            -h|--help) sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            -*)        echo "$(basename "${0}"): unknown option '$1'" >&2; exit 2 ;;
            *)         REPORT_MODULE="$1" ;;
        esac
        shift
    done
    [[ -n "${REPORT_MODULE}" ]] || report_usage

    check_json "${REPORT_CONFIG_DIR}/${REPORT_MODULE}.json" || exit 3

    # Normalize Pattern-A configs (nested under .config."<module>:<service>") so
    # the two locator reads work for either config shape. ONLY vmid and node are
    # read here — nothing on the reported side is defaulted, because desired
    # state is the manager's job and mixing the two is exactly #550.
    JSON="$(normalize_module_config < "${REPORT_CONFIG_DIR}/${REPORT_MODULE}.json")"
    export JSON

    # A config with no vmid describes no guest — a policy-only module, or a
    # co-located state file that merely happens to be valid JSON. Say so with
    # the "not deployed here" code rather than letting get_config_value die on
    # a missing required key, which would surface as a bare rc 1.
    REPORT_VMID="${vmid_override:-$(get_config_value 'vmid' '')}"
    if [[ -z "${REPORT_VMID}" || "${REPORT_VMID}" == "null" ]]; then
        echo "$(basename "${0}"): ${REPORT_MODULE} declares no vmid — it has no guest to report" >&2
        exit 3
    fi
    local config_node
    config_node="$(get_config_value 'node' "$(get_node_hostname 0)")"
    [[ "${config_node}" == "null" || -z "${config_node}" ]] && config_node="$(get_node_hostname 0)"

    # Locate the guest CLUSTER-WIDE. config.node is only a hint: a migrate or an
    # HA failover deliberately leaves it unchanged (#526), so a guest may live
    # elsewhere. Reporting the node we FOUND it on is what makes `node` drift
    # detectable at all — trusting config.node would report every guest as being
    # exactly where the config claims, which is never drift.
    # "No node answered" and "the guest is not there" are different facts and
    # get different exit codes: the first is an infrastructure problem, the
    # second may be the CORRECT state (an archived module has no guest).
    local cand row raw answered=0
    # shellcheck disable=SC2046  # word-splitting of hostnames is intended
    for cand in "${config_node}" $(get_all_node_hostnames); do
        raw=$(ssh "${REPORT_SSH_OPTS[@]}" "root@${cand}.${REPORT_MGMT}.internal" \
            "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null) || continue
        [[ -n "${raw}" ]] || continue
        answered=1
        row=$(jq -r --argjson id "${REPORT_VMID}" --arg t "${guest}" \
                '.[] | select(.vmid == $id and .type == $t) | "\(.node) \(.status)"' \
                <<< "${raw}" 2>/dev/null) || row=""
        if [[ -n "${row}" ]]; then
            REPORT_NODE="${row%% *}"
            # shellcheck disable=SC2034  # read by the sourcing reporter
            REPORT_STATUS="${row##* }"
            break
        fi
    done

    if [[ "${answered}" -eq 0 ]]; then
        echo "$(basename "${0}"): no cluster node answered — could not locate ${REPORT_MODULE}" >&2
        exit 4
    fi
    if [[ -z "${REPORT_NODE}" ]]; then
        echo "$(basename "${0}"): ${guest} guest ${REPORT_VMID} (${REPORT_MODULE}) is not present on any cluster node" >&2
        exit 5
    fi

    # `qm/pct config` is NODE-LOCAL, so it must run where the guest actually is.
    # The command embeds a locally-computed VMID that expands client-side.
    # shellcheck disable=SC2029
    REPORT_LIVE="$(ssh "${REPORT_SSH_OPTS[@]}" "root@${REPORT_NODE}.${REPORT_MGMT}.internal" \
        "${REPORT_CLI} config ${REPORT_VMID}" 2>/dev/null)" || {
        echo "$(basename "${0}"): failed to read '${REPORT_CLI} config ${REPORT_VMID}' on ${REPORT_NODE}" >&2
        exit 6
    }
}

# One key from the "key: value" config text. Empty when absent — a fact about
# the guest, not a failure: a VM with one NIC genuinely has no net1.
report_field() { awk -F': ' -v k="$1" '$1==k {print $2; exit}' <<< "${REPORT_LIVE}"; }

# Some keys are OMITTED when the guest runs at the HYPERVISOR's implicit
# default, so an absent key still describes a real running value: a VM with no
# `cores:` line genuinely has one core. Supplying those is EXTRACTION (decoding
# how Proxmox spells a value), not defaulting — the TAPPaaS schema defaults live
# in module-fields.json and belong to the DESIRED side, resolved once by the
# manager. Keeping the two apart is the #550 distinction.
report_field_or() {
    local v
    v="$(report_field "$1")"
    [[ -n "${v}" ]] && { printf '%s' "${v}"; return 0; }
    printf '%s' "$2"
}

# The boot disk value, across the buses a guest may use. The first present one
# wins, matching how install-service.sh creates them. Both the storage pool and
# the size come from the same string ("tanka1:vm-340-disk-0,size=80G").
#   report_disk <bus...>   → echoes the raw value
report_disk() {
    local bus v
    for bus in "$@"; do
        v="$(report_field "${bus}")"
        [[ -n "${v}" ]] && { printf '%s' "${v}"; return 0; }
    done
    printf ''
}
report_disk_storage() { printf '%s' "${1%%:*}"; }
report_disk_size()    { sed -n 's/.*size=\([0-9]\+[GMTKgmtk]\?\).*/\1/p' <<< "$1"; }

# Emit the object on the REAL stdout (fd 3).
#   report_emit '<jq program>' --arg k v ...
report_emit() {
    local program="$1"; shift
    jq -n "$@" "${program}" >&3
}
