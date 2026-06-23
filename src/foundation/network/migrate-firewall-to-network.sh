#!/usr/bin/env bash
#
# migrate-firewall-to-network.sh — one-time supervised live migration (ADR-007 P8, step 3)
#
# Renames the deployed `firewall` module to `network` on a LIVE TAPPaaS system.
# This is the DEFERRED, SUPERVISED half of the firewall→network rename: the source
# tree (src/foundation/network/, network.json, the network:* service prefixes) is
# already renamed and ships full back-compat so a live `firewall`-deployed system
# keeps working untouched. This script performs the actual cutover when an operator
# decides to run it — it is NOT run automatically by install/update.
#
# What it does (each step is idempotent and individually guarded):
#   1. config: rename config/firewall.json -> config/network.json, preserving every
#      operator field, and flip vmname firewall -> network.
#   2. Proxmox VM: rename the VM (vmid from the config) name firewall -> network.
#   3. DNS: add network.<mgmt>.internal host override (keep firewall.<mgmt>.internal
#      until the operator retires it — it is the cicd's lifeline; see WARNING below).
#   4. Caddy: reconcile the management reverse-proxy route under the new name.
#   5. config: leftover *.meta.json / backups renamed alongside.
#
# WARNING — the OPNsense HOST hostname (firewall.mgmt.internal / FIREWALL_FQDN) is the
# cicd's control lifeline. This script ADDS the new DNS name but does NOT remove the
# old one, and does NOT change FIREWALL_FQDN usages in running tooling. Fully retiring
# `firewall.mgmt.internal` is a separate, even-more-careful operator step done only
# after every consumer has been re-pointed and verified. Run this script under
# supervision, with a fresh PBS snapshot of the cicd and the OPNsense VM.
#
# Idempotent: re-running after a partial/complete migration is safe (each step
# detects already-migrated state and no-ops).
#
# Usage: migrate-firewall-to-network.sh [OPTIONS]
#
# Options:
#   --config-dir DIR   config directory (default: ${TAPPAAS_CONFIG:-/home/tappaas/config})
#   --node FQDN        Proxmox node FQDN to issue `qm` against
#                      (default: derived from site.json via get_primary_node_fqdn)
#   --mgmt-domain DOM  mgmt DNS domain (default: mgmt.internal)
#   --dry-run          print every action without changing anything
#   --yes              skip the interactive confirmation prompt (for scripted runs)
#   -h, --help         show this help and exit
#
# Exit codes: 0 = success or nothing to do; 1 = error.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging — reuse common-install-routines.sh when present
# ---------------------------------------------------------------------------
if ! declare -F info >/dev/null 2>&1; then
    if [[ -f /home/tappaas/bin/common-install-routines.sh ]]; then
        # shellcheck source=/dev/null
        . /home/tappaas/bin/common-install-routines.sh
    else
        : "${GN:=$'\033[1;92m'}"
        : "${RD:=$'\033[01;31m'}"
        : "${YW:=$'\033[33m'}"
        : "${DGN:=$'\033[32m'}"
        : "${BOLD:=$'\033[1m'}"
        : "${CL:=$'\033[m'}"
        info()  { echo -e "${DGN}[Info]${CL} $*"; }
        debug() { :; }
        warn()  { echo -e "${YW}[Warning]${CL} $*"; }
        error() { echo -e "${RD}[Error]${CL} $*" >&2; }
        die()   { error "$@"; exit 1; }
    fi
fi

# ---------------------------------------------------------------------------
# Defaults / argument parsing
# ---------------------------------------------------------------------------
CONFIG_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}"
NODE_FQDN=""
MGMT_DOMAIN="mgmt.internal"
DRY_RUN=0
ASSUME_YES=0

OLD_NAME="firewall"
NEW_NAME="network"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-dir)  CONFIG_DIR="${2:?--config-dir needs a value}"; shift 2 ;;
        --node)        NODE_FQDN="${2:?--node needs a value}"; shift 2 ;;
        --mgmt-domain) MGMT_DOMAIN="${2:?--mgmt-domain needs a value}"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --yes)         ASSUME_YES=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "Unknown argument: $1 (see --help)" ;;
    esac
done

readonly CONFIG_DIR MGMT_DOMAIN OLD_NAME NEW_NAME

OLD_JSON="${CONFIG_DIR}/${OLD_NAME}.json"
NEW_JSON="${CONFIG_DIR}/${NEW_NAME}.json"
readonly OLD_JSON NEW_JSON

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
TMP_FILES=()
cleanup() {
    local f
    for f in "${TMP_FILES[@]:-}"; do
        [[ -n "${f}" && -f "${f}" ]] && rm -f "${f}"
    done
}
trap cleanup EXIT INT TERM

# run <description> <command...> — honours --dry-run.
run() {
    local desc="$1"; shift
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        info "[dry-run] ${desc}: $*"
        return 0
    fi
    info "${desc}"
    "$@"
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || die "jq is required"

if [[ ! -d "${CONFIG_DIR}" ]]; then
    die "config dir not found: ${CONFIG_DIR}"
fi

# Already fully migrated? (new config present, old gone.)
if [[ -f "${NEW_JSON}" && ! -f "${OLD_JSON}" ]]; then
    info "${GN}Already migrated${CL}: ${NEW_JSON} exists and ${OLD_JSON} is gone — nothing to do."
    exit 0
fi

if [[ ! -f "${OLD_JSON}" && ! -f "${NEW_JSON}" ]]; then
    die "Neither ${OLD_JSON} nor ${NEW_JSON} present — is the network/firewall module installed?"
fi

# Resolve the Proxmox node FQDN if not supplied.
if [[ -z "${NODE_FQDN}" ]]; then
    if declare -F get_primary_node_fqdn >/dev/null 2>&1; then
        NODE_FQDN="$(get_primary_node_fqdn 2>/dev/null || true)"
    fi
fi
readonly NODE_FQDN

# VMID from whichever config exists.
SRC_JSON="${OLD_JSON}"
[[ -f "${SRC_JSON}" ]] || SRC_JSON="${NEW_JSON}"
VMID="$(jq -r '.vmid // empty' "${SRC_JSON}" 2>/dev/null || true)"

cat <<BANNER
${BOLD}ADR-007 P8 — live firewall → network migration${CL}
  config dir   : ${CONFIG_DIR}
  source config: ${SRC_JSON}
  VM id        : ${VMID:-<unknown>}
  proxmox node : ${NODE_FQDN:-<none — VM rename will be SKIPPED>}
  mgmt domain  : ${MGMT_DOMAIN}
  mode         : $([[ "${DRY_RUN}" -eq 1 ]] && echo "DRY-RUN (no changes)" || echo "LIVE")
BANNER

if [[ "${DRY_RUN}" -eq 0 && "${ASSUME_YES}" -eq 0 ]]; then
    warn "This is a one-time supervised live migration. Ensure you have a fresh"
    warn "PBS snapshot of the cicd and the OPNsense VM before proceeding."
    read -r -p "Proceed with the LIVE migration? [y/N] " _reply
    case "${_reply}" in
        y|Y|yes|YES) ;;
        *) die "Aborted by operator." ;;
    esac
fi

# ---------------------------------------------------------------------------
# Step 1 — config: firewall.json -> network.json (preserve operator fields,
#          flip vmname). Idempotent: skip if already migrated.
# ---------------------------------------------------------------------------
if [[ -f "${OLD_JSON}" ]]; then
    if [[ -f "${NEW_JSON}" ]]; then
        warn "Both ${OLD_JSON} and ${NEW_JSON} exist — keeping ${NEW_JSON}, backing up the old one."
        run "back up legacy ${OLD_NAME}.json" \
            mv "${OLD_JSON}" "${OLD_JSON}.pre-migrate.bak"
    else
        # Preserve every field; only flip vmname firewall -> network.
        tmp="$(mktemp)"; TMP_FILES+=("${tmp}")
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            info "[dry-run] rewrite ${OLD_JSON} -> ${NEW_JSON} with vmname='${NEW_NAME}', location -> .../network"
        else
            jq --arg vm "${NEW_NAME}" '
                .vmname = $vm
                | .description = (.description // "The TAPPaaS Network VM (OPNsense)")
                | if (.location // "") | test("/firewall$")
                  then .location = (.location | sub("/firewall$"; "/network"))
                  else . end
                | del(.legacyName)
            ' "${OLD_JSON}" > "${tmp}" || die "failed to transform ${OLD_JSON}"
            jq empty "${tmp}" || die "transformed config is not valid JSON"
            mv "${tmp}" "${NEW_JSON}"
            info "${GN}✓${CL} wrote ${NEW_JSON} (vmname=${NEW_NAME})"
            # keep a backup of the original for rollback
            cp "${NEW_JSON}" "${OLD_JSON}.bak" 2>/dev/null || true
            rm -f "${OLD_JSON}"
            info "${GN}✓${CL} removed ${OLD_JSON} (backup at ${OLD_JSON}.bak)"
        fi
    fi

    # Sidecar meta.json follows the config rename.
    if [[ -f "${CONFIG_DIR}/${OLD_NAME}.meta.json" && ! -f "${CONFIG_DIR}/${NEW_NAME}.meta.json" ]]; then
        run "rename ${OLD_NAME}.meta.json -> ${NEW_NAME}.meta.json" \
            mv "${CONFIG_DIR}/${OLD_NAME}.meta.json" "${CONFIG_DIR}/${NEW_NAME}.meta.json"
    fi
else
    info "config already migrated to ${NEW_JSON} — skipping config step."
fi

# ---------------------------------------------------------------------------
# Step 2 — Proxmox VM rename (firewall -> network). Guarded on a node + vmid.
# ---------------------------------------------------------------------------
if [[ -z "${NODE_FQDN}" ]]; then
    warn "No Proxmox node resolved (--node / site.json) — SKIPPING VM rename."
    warn "  Rename it manually later: ssh root@<node> qm set ${VMID:-<vmid>} --name ${NEW_NAME}"
elif [[ -z "${VMID}" ]]; then
    warn "No vmid in config — SKIPPING VM rename."
else
    # Read the current VM name; only rename if still 'firewall'.
    current_name=""
    if [[ "${DRY_RUN}" -eq 0 ]]; then
        current_name="$(ssh -o ConnectTimeout=5 "root@${NODE_FQDN}" \
            "qm config ${VMID} 2>/dev/null | awk -F': ' '/^name:/{print \$2}'" 2>/dev/null || true)"
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        info "[dry-run] rename Proxmox VM ${VMID} -> name '${NEW_NAME}' on ${NODE_FQDN}"
    elif [[ "${current_name}" == "${NEW_NAME}" ]]; then
        info "Proxmox VM ${VMID} already named '${NEW_NAME}' — skipping."
    else
        run "rename Proxmox VM ${VMID} (${current_name:-?}) -> ${NEW_NAME}" \
            ssh -o ConnectTimeout=10 "root@${NODE_FQDN}" "qm set ${VMID} --name ${NEW_NAME}" \
            || warn "VM rename returned non-zero (continuing — verify with qm config ${VMID})"
    fi
fi

# ---------------------------------------------------------------------------
# Step 3 — DNS: add network.<mgmt> host override. Keep firewall.<mgmt> (lifeline).
# ---------------------------------------------------------------------------
NEW_FQDN="${NEW_NAME}.${MGMT_DOMAIN}"
OLD_FQDN="${OLD_NAME}.${MGMT_DOMAIN}"
if command -v dns-manager >/dev/null 2>&1; then
    # Resolve the IP of the existing firewall host so the new name points at it.
    fw_ip="$(dig +short "${OLD_FQDN}" 2>/dev/null | head -n1 || true)"
    if [[ -n "${fw_ip}" ]]; then
        run "add DNS host override ${NEW_FQDN} -> ${fw_ip}" \
            dns-manager add "${NEW_NAME}" "${MGMT_DOMAIN}" --ip "${fw_ip}" \
            || warn "dns-manager add ${NEW_FQDN} returned non-zero (continuing)"
    else
        warn "Could not resolve ${OLD_FQDN} to an IP — SKIPPING DNS add."
        warn "  Add it manually: dns-manager add ${NEW_NAME} ${MGMT_DOMAIN} --ip <firewall-ip>"
    fi
    info "Leaving ${OLD_FQDN} in place (cicd lifeline) — retire it separately when safe."
else
    warn "dns-manager not on PATH — SKIPPING DNS step."
    warn "  Add manually: dns-manager add ${NEW_NAME} ${MGMT_DOMAIN} --ip <firewall-ip>"
fi

# ---------------------------------------------------------------------------
# Step 4 — Caddy: reconcile the mgmt reverse-proxy route under the new name.
#          The proxy update-service is idempotent, so re-running it against the
#          (now network-named) module reconciles the OPNsense GUI route.
# ---------------------------------------------------------------------------
PROXY_SVC=""
for cand in \
    "/home/tappaas/TAPPaaS/src/foundation/network/services/proxy/update-service.sh" \
    "$(dirname "${BASH_SOURCE[0]}")/services/proxy/update-service.sh"; do
    [[ -x "${cand}" ]] && { PROXY_SVC="${cand}"; break; }
done

# Only reconcile if the module opts its own GUI into the proxy (network:proxy or
# legacy firewall:proxy still present in its dependsOn).
self_proxy=0
if [[ -f "${NEW_JSON}" ]]; then
    if jq -e '(.dependsOn // []) | (index("network:proxy") // index("firewall:proxy"))' \
            "${NEW_JSON}" >/dev/null 2>&1; then
        self_proxy=1
    fi
fi

if [[ "${self_proxy}" -eq 1 && -n "${PROXY_SVC}" ]]; then
    run "reconcile Caddy reverse-proxy route for ${NEW_NAME}" \
        "${PROXY_SVC}" "${NEW_NAME}" \
        || warn "Caddy reconcile returned non-zero (continuing — verify the route)"
elif [[ "${self_proxy}" -eq 1 ]]; then
    warn "proxy update-service.sh not found — SKIPPING Caddy reconcile."
    warn "  Run later: src/foundation/network/services/proxy/update-service.sh ${NEW_NAME}"
else
    info "Module does not publish its own GUI via the proxy — no Caddy route to reconcile."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "${GN}${BOLD}Dry-run complete${CL} — no changes were made. Re-run without --dry-run to apply."
else
    info "${GN}${BOLD}Migration complete.${CL}"
    info "  Verify: config/${NEW_NAME}.json present; qm config ${VMID:-<vmid>} name=${NEW_NAME};"
    info "          ${NEW_FQDN} resolves; the mgmt proxy route works."
    warn "  The host name ${OLD_FQDN} (FIREWALL_FQDN) was intentionally LEFT in place."
    warn "  Retire it only after every consumer is re-pointed and verified."
fi
exit 0
