#!/usr/bin/env bash
#
# deploy-vms.sh
# Clones one or more Windows Server VMs from the TAPPaaS template (VMID 8081).
# Auto-detects the next QW<n> name and first free VMID in the configured range.
#
# Usage:
#   bash deploy-vms.sh           # clone 1 VM
#   bash deploy-vms.sh 3         # clone 3 VMs
#   CPU_CORES=4 bash deploy-vms.sh 2
#
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# -- Colors / Logging --------------------------------------------------------
readonly GN="\e[1;32m" YW="\e[33m" RD="\e[31m" CL="\e[0m"
info()  { echo -e "${GN}[INFO]${CL}  $*"; }
warn()  { echo -e "${YW}[WARN]${CL}  $*" >&2; }
error() { echo -e "${RD}[ERROR]${CL} $*" >&2; }
die()   { error "$*"; exit 1; }

# -- Defaults (override via environment) -------------------------------------
TEMPLATE_VMID="${TEMPLATE_VMID:-8081}"
STORAGE="${STORAGE:-tanka1}"
VMID_RANGE_START="${VMID_RANGE_START:-320}"
VMID_RANGE_END="${VMID_RANGE_END:-329}"
VM_PREFIX="QW"

# Optional resource overrides (blank = inherit from template)
CPU_CORES="${CPU_CORES:-}"
CPU_SOCKETS="${CPU_SOCKETS:-}"
MEMORY_MB="${MEMORY_MB:-}"
BRIDGE="${BRIDGE:-}"

AUTOSTART="${AUTOSTART:-false}"

# Set by parse_args
COUNT=1

# -- Usage -------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: [ENV_OVERRIDES] bash ${SCRIPT_NAME} [COUNT]

Clones COUNT Windows Server VMs from template VMID ${TEMPLATE_VMID}.
Names them QW1, QW2, ... continuing from the highest existing QW index.
VMIDs are allocated from range ${VMID_RANGE_START}-${VMID_RANGE_END}.

Arguments:
  COUNT           Number of VMs to clone (default: 1)

Environment overrides:
  TEMPLATE_VMID     Source template VMID      (default: ${TEMPLATE_VMID})
  STORAGE           Target storage pool       (default: ${STORAGE})
  VMID_RANGE_START  First allocatable VMID    (default: ${VMID_RANGE_START})
  VMID_RANGE_END    Last allocatable VMID     (default: ${VMID_RANGE_END})
  CPU_CORES         Override vCPU cores       (default: inherit from template)
  CPU_SOCKETS       Override CPU sockets      (default: inherit from template)
  MEMORY_MB         Override RAM in MB        (default: inherit from template)
  BRIDGE            Override network bridge   (default: inherit from template)
  AUTOSTART         Start VMs after clone     (default: ${AUTOSTART})

Examples:
  bash ${SCRIPT_NAME}
  bash ${SCRIPT_NAME} 3
  CPU_CORES=4 MEMORY_MB=8192 bash ${SCRIPT_NAME} 2
  AUTOSTART=true bash ${SCRIPT_NAME}
EOF
}

# -- Cleanup -----------------------------------------------------------------
cleanup() {
    local rc=$?
    [[ $rc -ne 0 ]] && error "Script exited with code ${rc}."
    exit "${rc}"
}
trap cleanup EXIT ERR INT TERM

# -- Argument parsing --------------------------------------------------------
parse_args() {
    [[ "${1:-}" =~ ^(-h|--help)$ ]] && { usage; exit 0; }
    COUNT="${1:-1}"
    [[ "${COUNT}" =~ ^[0-9]+$ ]] && (( COUNT >= 1 )) \
        || die "COUNT must be a positive integer (got: '${COUNT}'). Usage: bash ${SCRIPT_NAME} [COUNT]"
}

# -- Preflight ---------------------------------------------------------------
preflight() {
    command -v qm &>/dev/null \
        || die "'qm' not found — run this script on a Proxmox VE host."

    qm status "${TEMPLATE_VMID}" &>/dev/null \
        || die "Template VMID ${TEMPLATE_VMID} does not exist. Run build-template.sh first."

    qm config "${TEMPLATE_VMID}" 2>/dev/null | grep -q "^template: 1" \
        || die "VMID ${TEMPLATE_VMID} is not a template yet. Shut it down and run:  qm template ${TEMPLATE_VMID}"
}

# -- Discovery ---------------------------------------------------------------
USED_VMIDS=()

load_used_vmids() {
    mapfile -t USED_VMIDS < <(
        { qm list 2>/dev/null  | awk 'NR>1 {print $1}';
          pct list 2>/dev/null | awk 'NR>1 {print $1}'; } | sort -n | uniq
    )
}

next_free_vmid() {
    local candidate="${VMID_RANGE_START}"
    while (( candidate <= VMID_RANGE_END )); do
        local in_use=false
        for used in "${USED_VMIDS[@]+"${USED_VMIDS[@]}"}"; do
            if (( used == candidate )); then
                in_use=true
                break
            fi
        done
        if [[ "${in_use}" == "false" ]]; then
            echo "${candidate}"
            return
        fi
        (( candidate++ ))
    done
    die "No free VMID in range ${VMID_RANGE_START}-${VMID_RANGE_END}. Expand range with VMID_RANGE_END."
}

highest_qw_index() {
    local max=0
    for vmid in "${USED_VMIDS[@]+"${USED_VMIDS[@]}"}"; do
        local name
        name=$(qm config "${vmid}" 2>/dev/null | awk -F': ' '/^name:/{print $2}') || continue
        if [[ "${name}" =~ ^${VM_PREFIX}([0-9]+)$ ]]; then
            local n="${BASH_REMATCH[1]}"
            (( n > max )) && max=$n
        fi
    done
    echo "${max}"
}

# -- Deploy ------------------------------------------------------------------
deploy_vms() {
    local next_qw
    next_qw=$(( $(highest_qw_index) + 1 ))

    info "Cloning ${COUNT} VM(s) from template ${TEMPLATE_VMID} ..."
    echo ""

    local -a created=()

    for (( i = 0; i < COUNT; i++ )); do
        local vmid vm_name
        vmid=$(next_free_vmid)
        vm_name="${VM_PREFIX}${next_qw}"

        info "Cloning → ${vm_name}  (VMID ${vmid})"

        qm clone "${TEMPLATE_VMID}" "${vmid}" \
            --name    "${vm_name}" \
            --full    1 \
            --storage "${STORAGE}"

        [[ -n "${CPU_CORES}"   ]] && qm set "${vmid}" --cores   "${CPU_CORES}"
        [[ -n "${CPU_SOCKETS}" ]] && qm set "${vmid}" --sockets "${CPU_SOCKETS}"
        [[ -n "${MEMORY_MB}"   ]] && qm set "${vmid}" --memory  "${MEMORY_MB}"
        [[ -n "${BRIDGE}"      ]] && qm set "${vmid}" --net0    "virtio,bridge=${BRIDGE}"

        if [[ "${AUTOSTART}" == "true" ]]; then
            qm start "${vmid}"
            info "  ${vm_name} — cloned and started"
        else
            info "  ${vm_name} — cloned (stopped)"
        fi

        created+=("${vmid}:${vm_name}")
        USED_VMIDS+=("${vmid}")
        (( next_qw++ ))
    done

    print_summary "${created[@]}"
}

# -- Summary -----------------------------------------------------------------
print_summary() {
    local -a created=("$@")
    echo ""
    info "${#created[@]} VM(s) deployed:"
    echo ""
    printf "  %-8s  %s\n" "VMID" "Name"
    printf "  %-8s  %s\n" "----" "----"
    for entry in "${created[@]}"; do
        IFS=: read -r vid vname <<< "${entry}"
        printf "  %-8s  %s\n" "${vid}" "${vname}"
    done
    echo ""

    if [[ "${AUTOSTART}" != "true" ]]; then
        info "Start with:"
        for entry in "${created[@]}"; do
            IFS=: read -r vid _ <<< "${entry}"
            echo "    qm start ${vid}"
        done
        echo ""
    fi

    echo "  If sysprep was run on the template, each VM boots into OOBE"
    echo "  for hostname/network setup on first start."
    echo ""
}

# -- Main --------------------------------------------------------------------
main() {
    parse_args "$@"
    preflight
    load_used_vmids
    deploy_vms
}

main "$@"
