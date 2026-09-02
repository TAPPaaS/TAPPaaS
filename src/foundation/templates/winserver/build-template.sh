#!/usr/bin/env bash
# DEPRECATED: Template creation is now fully automatic via install-module.sh.
# Retained as reference / manual fallback only.
#
# build-template.sh
# Creates the TAPPaaS Windows Server 2025 Proxmox template (VMID 8081).
# Run this once on a Proxmox VE host to prepare the base image.
#
# After this script completes, follow the printed manual steps to install
# Windows, apply VirtIO drivers, run sysprep, then: qm template 8081
#
# Usage: [ENV_OVERRIDES] bash build-template.sh [-h]
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
TEMPLATE_NAME="${TEMPLATE_NAME:-tappaas-winserver}"
STORAGE="${STORAGE:-tanka1}"
ISO_STORAGE="${ISO_STORAGE:-local}"
WIN_ISO="${WIN_ISO:-26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso}"
DISK_SIZE="${DISK_SIZE:-80G}"
CPU_SOCKETS="${CPU_SOCKETS:-1}"
CPU_CORES="${CPU_CORES:-4}"
MEMORY_MB="${MEMORY_MB:-8192}"
BRIDGE="${BRIDGE:-lan}"
BIOS="${BIOS:-ovmf}"

# -- Usage -------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: [ENV_OVERRIDES] bash ${SCRIPT_NAME}

Creates the TAPPaaS Windows Server 2025 Proxmox template.

Environment overrides:
  TEMPLATE_VMID   VM ID for the template       (default: ${TEMPLATE_VMID})
  TEMPLATE_NAME   VM display name              (default: ${TEMPLATE_NAME})
  STORAGE         Proxmox storage pool         (default: ${STORAGE})
  ISO_STORAGE     Storage holding the ISOs     (default: ${ISO_STORAGE})
  WIN_ISO         Windows Server ISO filename  (default: ${WIN_ISO})
                  Must be uploaded to Proxmox local ISO storage first.
  DISK_SIZE       System disk size             (default: ${DISK_SIZE})
  CPU_CORES       vCPU cores                   (default: ${CPU_CORES})
  MEMORY_MB       RAM in MB                    (default: ${MEMORY_MB})
  BRIDGE          Network bridge               (default: ${BRIDGE})
  BIOS            Firmware: ovmf or seabios    (default: ${BIOS})

Example:
  WIN_ISO=my_server.iso bash ${SCRIPT_NAME}
  TEMPLATE_VMID=9000 STORAGE=local-lvm bash ${SCRIPT_NAME}
EOF
}

# -- Cleanup -----------------------------------------------------------------
cleanup() {
    local rc=$?
    [[ $rc -ne 0 ]] && error "Script exited with code ${rc}."
    exit "${rc}"
}
trap cleanup EXIT ERR INT TERM

# -- Preflight ---------------------------------------------------------------
preflight() {
    command -v qm &>/dev/null \
        || die "'qm' not found — run this script on a Proxmox VE host."

    if qm status "${TEMPLATE_VMID}" &>/dev/null; then
        die "VMID ${TEMPLATE_VMID} already exists.\n  Remove it first:  qm destroy ${TEMPLATE_VMID}\n  Or use a different ID:  TEMPLATE_VMID=9000 bash ${SCRIPT_NAME}"
    fi

    if ! pvesm list "${ISO_STORAGE}" 2>/dev/null | grep -qF "${WIN_ISO}"; then
        warn "Windows ISO '${WIN_ISO}' not found in storage '${ISO_STORAGE}'."
        warn "Upload it first, or override with: WIN_ISO=<filename>"
    fi
}

# -- VirtIO ISO detection ----------------------------------------------------
detect_virtio_iso() {
    # shellcheck disable=SC2012
    local path
    path=$(ls /var/lib/vz/template/iso/virtio-win*.iso 2>/dev/null | sort -V | tail -1)
    [[ -n "${path}" ]] && basename "${path}" || true
}

# -- Create VM ---------------------------------------------------------------
create_vm() {
    local virtio_iso
    virtio_iso=$(detect_virtio_iso)

    if [[ -z "${virtio_iso}" ]]; then
        warn "No virtio-win*.iso found in /var/lib/vz/template/iso/ — VirtIO drivers CD will not be attached."
    fi

    info "Creating template VM ${TEMPLATE_VMID} (${TEMPLATE_NAME}) ..."

    qm create "${TEMPLATE_VMID}" \
        --name      "${TEMPLATE_NAME}" \
        --ostype    win11 \
        --machine   q35 \
        --bios      "${BIOS}" \
        --scsihw    virtio-scsi-single \
        --agent     enabled=1 \
        --cpu       host \
        --sockets   "${CPU_SOCKETS}" \
        --cores     "${CPU_CORES}" \
        --memory    "${MEMORY_MB}" \
        --net0      "virtio,bridge=${BRIDGE}" \
        --boot      "order=ide2;scsi0"

    qm set "${TEMPLATE_VMID}" --scsi0 "${STORAGE}:${DISK_SIZE},cache=writeback,discard=on"
    qm set "${TEMPLATE_VMID}" --ide2  "${ISO_STORAGE}:iso/${WIN_ISO},media=cdrom"

    if [[ -n "${virtio_iso}" ]]; then
        qm set "${TEMPLATE_VMID}" --ide0 "${ISO_STORAGE}:iso/${virtio_iso},media=cdrom"
        info "VirtIO drivers ISO attached: ${virtio_iso}"
    fi

    if [[ "${BIOS}" == "ovmf" ]]; then
        qm set "${TEMPLATE_VMID}" --efidisk0  "${STORAGE}:1,efitype=4m,pre-enrolled-keys=1"
        qm set "${TEMPLATE_VMID}" --tpmstate0 "${STORAGE}:1,version=v2.0"
    fi
}

# -- Print next steps --------------------------------------------------------
print_next_steps() {
    echo ""
    info "VM ${TEMPLATE_VMID} created. Complete these manual steps:"
    echo ""
    echo "  1.  Start the VM:"
    echo "        qm start ${TEMPLATE_VMID}"
    echo ""
    echo "  2.  Open the Proxmox console and install Windows Server 2025."
    echo "      When prompted for a storage driver, click 'Load driver':"
    echo "        Browse to  D:\\amd64\\2k25\\"
    echo "        Load: viostor.inf  (storage — required to see the disk)"
    echo "        Load: netkvm.inf   (network)"
    echo ""
    echo "  3.  After Windows install, mount the VirtIO ISO and run:"
    echo "        virtio-win-guest-tools.exe"
    echo ""
    echo "  4.  Install Windows Updates. Install OpenSSH Server:"
    echo "        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
    echo "        Set-Service -Name sshd -StartupType Automatic"
    echo "        Start-Service sshd"
    echo ""
    echo "  5.  Run sysprep to generalise the image:"
    echo "        C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown"
    echo ""
    echo "  6.  Once shut down, detach the ISO drives:"
    echo "        qm set ${TEMPLATE_VMID} --delete ide0,ide2"
    echo ""
    echo "  7.  Convert to Proxmox template:"
    echo "        qm template ${TEMPLATE_VMID}"
    echo ""
    echo "  Once templated, run deploy-vms.sh to clone VMs from this template."
    echo ""
}

# -- Main --------------------------------------------------------------------
main() {
    [[ "${1:-}" =~ ^(-h|--help)$ ]] && { usage; exit 0; }
    preflight
    create_vm
    print_next_steps
}

main "$@"
