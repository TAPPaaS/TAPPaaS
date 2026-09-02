#!/usr/bin/env bash
#
# TAPPaaS Cluster VM Service - Update (drift converge)
#
# Reconciles a module's live Proxmox VM with its desired configuration.
# Called by update-module.sh (Step 4) and `module reconcile --apply` for any
# module that dependsOn cluster:vm.
#
# ADR-020 SHAPE. This script no longer computes drift. It used to hold a bespoke
# drift loop — its own `cfg()` default ladder, its own `qm config` parser, its
# own comparison rules — which meant the value it would APPLY could differ from
# the value `reconcile` REPORTED (#550). Now:
#
#   desired = module-manager module resolve   [the one resolver]
#   actual  = ./report-service.sh             [extract only]
#   drift   = module-manager module drift     [the one differ]
#   apply   = converge_apply (converge-lib.sh) → the batched `qm set`
#             + update-net.sh / update-disk.sh / update-node.sh
#
# What lives HERE is what is genuinely cluster:vm's and is NOT field drift: the
# provider callbacks (how to run a batched `qm set`; how to reboot, wait for an
# address and register DNS) and the ordering between them. That split is ADR-020
# D7's migration discipline — extract the drift loop, keep everything else.
#
# Handled (auto-applied), unchanged from before the refactor:
#   net0/net1 (bridge, zone→tag, trunks; MAC + queues preserved) -> update-net.sh
#   cores, memory, cputype, vmtag, vmname                        -> one qm set
#   diskSize (grow only)                                         -> update-disk.sh
#   node (only if the module does NOT dependOn cluster:ha)       -> update-node.sh
#
# Reported but not auto-applied (the manifest's classes say so):
#   storage           -> manual   : warn; move-disk is left to the operator
#   bios / ostype     -> recreate : fatal; needs power-off / reinstall
#   vmid/image*/os/cloudInit -> immutable : fatal; implies reinstall
#   node on HA modules -> deferred to cluster:ha (inside update-node.sh)
#
# Usage: update-service.sh [--check] [--apply-drift <file>] [--force] <module>
#   --check              Report drift without applying (also via TAPPAAS_CHECK=1)
#   --apply-drift FILE   Apply a drift record that was computed elsewhere. The
#                        default is to ask the manager for one — every existing
#                        caller invokes this script bare and must keep working.
#   --force              Authorize a disruptive change — a guest reboot or an
#                        offline migrate (ADR-020 D8). Without it, and without
#                        rebootOk in the scheduled pass, such a change is
#                        deferred with a DEFERRED: line and the converge still
#                        exits 0.
#
# Exit codes:
#   0  In sync, or all applicable drift applied (deferrals included — a deferred
#      disruptive change is not a failure, ADR-020 D8)
#   1  Drift detected that could not be safely applied
#

# The provider callbacks below (converge_apply_set, converge_side_effect_*) are
# invoked BY NAME from converge-lib.sh; cleanup() runs from the EXIT trap.
# ShellCheck sees neither call site.
# shellcheck disable=SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CONFIG_DIR="/home/tappaas/config"
readonly ZONES_FILE="${CONFIG_DIR}/zones.json"
readonly MGMT="mgmt"

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/vm-net.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/vm-net.sh"
# shellcheck source=../../../tappaas-cicd/lib/converge-lib.sh disable=SC1091
. "${SCRIPT_DIR}/../../../tappaas-cicd/lib/converge-lib.sh"

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

# ── Arguments ────────────────────────────────────────────────────────

CHECK_MODE="${TAPPAAS_CHECK:-0}"
DRIFT_FILE=""
FORCE=0
MODULE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)       CHECK_MODE=1 ;;
        --apply-drift) DRIFT_FILE="${2:-}"; shift ;;
        --force)       FORCE=1 ;;
        -h|--help)     echo "Usage: $0 [--check] [--apply-drift <file>] [--force] <module-name>"; exit 0 ;;
        -*)            echo "update-service.sh: unknown option '$1'" >&2; exit 1 ;;
        *)             MODULE="$1" ;;
    esac
    shift
done

if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 [--check] [--apply-drift <file>] [--force] <module-name>"
    exit 1
fi

check_json "${CONFIG_DIR}/${MODULE}.json" || exit 1

debug "${BOLD}cluster:vm update-service: reconciling ${BL}${MODULE}${CL}"
[[ "${CHECK_MODE}" == "1" ]] && warn "  CHECK MODE — drift will be reported, not applied"
CONVERGE_CHECK="${CHECK_MODE}"

# ── The drift record ─────────────────────────────────────────────────
# Bare invocation asks the manager for one. That keeps every existing caller
# (update-module.sh, reconcile --apply, an operator at a prompt) working exactly
# as before while there is still only ONE differ, in the manager.

OWN_DRIFT_FILE=""
cleanup() { [[ -n "${OWN_DRIFT_FILE}" ]] && rm -f -- "${OWN_DRIFT_FILE}"; return 0; }
trap cleanup EXIT INT TERM

if [[ -z "${DRIFT_FILE}" ]]; then
    OWN_DRIFT_FILE="$(mktemp "${TMPDIR:-/tmp}/cluster-vm-drift.XXXXXX.json")"
    DRIFT_FILE="${OWN_DRIFT_FILE}"
    drift_err="$(mktemp "${TMPDIR:-/tmp}/cluster-vm-drift-err.XXXXXX")"
    if ! module-manager module drift "${MODULE}" --service cluster:vm --json \
            > "${DRIFT_FILE}" 2> "${drift_err}"; then
        # A STALE module-manager is the one failure an operator cannot guess
        # from "could not compute drift": pre-update.sh warns and continues when
        # a component build fails, which leaves this script newer than the CLI
        # it depends on. Name that case explicitly.
        if grep -q "Unknown verb" "${drift_err}" 2>/dev/null; then
            error "The installed module-manager has no 'module drift' verb — it is older than this service script."
            error "Rebuild it:  ${SCRIPT_DIR}/../../../tappaas-cicd/manager/module-manager/install.sh"
            rm -f -- "${drift_err}"
            exit 1
        fi
        error "Could not compute drift for '${MODULE}':"
        sed 's/^/    /' "${drift_err}" >&2
        rm -f -- "${drift_err}"
        die "module-manager module drift ${MODULE} --service cluster:vm failed"
    fi
    rm -f -- "${drift_err}"
fi

# ── Provider callbacks (the converge-lib contract) ───────────────────
# The runner decides WHAT to do and in what order; these are the only places
# that talk to Proxmox.

# Facts the callbacks need, read once from the record's actual state so they
# cannot disagree with what the drift was computed against.
VMID="$(jq -r '(.actual.vmid) // ""'   "${DRIFT_FILE}")"
NODE="$(jq -r '(.actual.node) // ""'   "${DRIFT_FILE}")"
VMSTATUS="$(jq -r '(.actual.status) // ""' "${DRIFT_FILE}")"
VMNAME="$(jq -r '(.actual.name) // ""' "${DRIFT_FILE}")"
[[ -n "${VMNAME}" ]] || VMNAME="${MODULE}"
ZONE0="$(module-manager module resolve "${MODULE}" --json 2>/dev/null | jq -r '(.fields.zone0.value) // "mgmt"')"
NODE_FQDN="${NODE}.${MGMT}.internal"

# ONE batched `qm set` for every in-place field — preserved deliberately: it is
# a single round-trip and a single atomic Proxmox change, where per-field calls
# would multiply both the latency and the ways a converge can half-apply.
# shellcheck disable=SC2029  # VMID/args expand client-side, intentionally
converge_apply_set() {
    debug "  Applying qm set on ${NODE}..."
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
        "qm set ${VMID} $(printf '%q ' "$@")" >/dev/null
}

# shellcheck disable=SC2029
converge_side_effect_reboot() {
    if [[ "${VMSTATUS}" != "running" ]]; then
        warn "  VM not running — network change applied to config; DNS will register on next boot"
        REBOOT_SKIPPED=1
        return 0
    fi
    debug "  Rebooting VM ${VMID} to apply the network change..."
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "qm reboot ${VMID}" >/dev/null
}

# Wait for the guest to report an address IN THE TARGET SUBNET.
#
# Both discovery sources can surface a STALE address from the old subnet — the
# dnsmasq lease table keeps the previous lease until it expires, and the guest
# may briefly still report it — which would register a wrong, cross-zone DNS
# record. So derive the target /24 prefix and prefer a match.
NEW_IP=""
IP_SRC=""
REBOOT_SKIPPED=0
# shellcheck disable=SC2029
converge_side_effect_wait_ip() {
    [[ "${REBOOT_SKIPPED}" == "1" ]] && return 0
    debug "  Waiting for VM to come back with an IP..."
    local zone_cidr zone_prefix cands qm_iface ga_ips le_ips desired_mac
    zone_cidr="$(jq -r --arg z "${ZONE0}" '.[$z].ip // empty' "${ZONES_FILE}" 2>/dev/null)"
    zone_prefix=""
    [[ "${zone_cidr}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\. ]] && zone_prefix="${BASH_REMATCH[1]}."
    desired_mac="$(jq -r '(.actual["net0.mac"]) // ""' "${DRIFT_FILE}")"

    # 90×4s = up to 360s: a NixOS guest can be slow to boot AND to re-DHCP into
    # a new subnet after a VLAN change (it must drop the old-subnet lease first).
    for _ in $(seq 1 90); do
        sleep 4
        cands=""
        # 1) qemu-guest-agent — guest-reported current IPv4s; may be absent on a
        #    minimal image or slow to come up after the reboot.
        qm_iface=$(ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
            "qm guest cmd ${VMID} network-get-interfaces" 2>/dev/null) || qm_iface=""
        if [[ -n "${qm_iface}" ]]; then
            # `|| true`: under `set -e`+pipefail a no-match jq must not abort the
            # whole converge mid-wait — an empty result just means "not yet".
            ga_ips=$(jq -r '.[] | select(.name | test("^(lo|docker)") | not)
                             | ."ip-addresses"[]?
                             | select(."ip-address-type" == "ipv4")
                             | ."ip-address"' <<< "${qm_iface}" 2>/dev/null || true)
            [[ -n "${ga_ips}" ]] && cands+="${ga_ips}"$'\n' && [[ -z "${IP_SRC}" ]] && IP_SRC="guest-agent"
        fi
        # 2) dnsmasq DHCP lease by MAC — guest-agent-independent (recovers the
        #    common case where the agent is missing/silent but the guest has
        #    already leased). `dns-manager` prints a connection banner ("OK") on
        #    stdout, so match the IPv4 shape rather than taking the first line.
        if [[ -n "${desired_mac}" ]]; then
            # `|| true`: a no-match grep (MAC not currently leased — e.g. right
            # after the guest sends a DHCP RELEASE on reboot) returns 1, which
            # under `set -e`+pipefail would otherwise abort the converge.
            le_ips=$(dns-manager --no-ssl-verify leases --mac "${desired_mac}" 2>/dev/null \
                     | grep -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true)
            [[ -n "${le_ips}" ]] && cands+="${le_ips}"$'\n' && [[ -z "${IP_SRC}" ]] && IP_SRC="dhcp-lease"
        fi
        cands=$(grep -vE '^(127\.|$)' <<< "${cands}" || true)
        [[ -z "${cands}" ]] && continue
        # Prefer an address in the target subnet; if only a stale old-subnet
        # address is visible so far, keep waiting for the new lease to appear.
        if [[ -n "${zone_prefix}" ]]; then
            NEW_IP=$(grep -F "${zone_prefix}" <<< "${cands}" | head -1 || true)
        else
            NEW_IP=$(head -1 <<< "${cands}")   # no subnet known — best effort
        fi
        [[ -n "${NEW_IP}" ]] && break
    done
    return 0
}

# Register the new record, drop the stale one, then gate on the module actually
# being able to serve (#468).
#
# NOT reaching an IP is NOT a failure: the VLAN change IS applied, and dnsmasq
# resolves <vmname>.<zone>.internal from the guest's lease once it appears
# (masqdns — how cluster:lxc and every leased VM already resolve). Warn and let
# masqdns take over rather than aborting a converge that succeeded.
converge_side_effect_dns() {
    [[ "${REBOOT_SKIPPED}" == "1" ]] && return 0
    local new_domain="${ZONE0}.internal" old_tag old_zone
    if [[ -z "${NEW_IP}" ]]; then
        warn "  VM did not report an IPv4 in ${ZONE0} within the wait window (no guest-agent report and no matching DHCP lease)."
        warn "  The net0 VLAN change IS applied; ${VMNAME}.${new_domain} will resolve via masqdns once the guest re-DHCPs. Skipping the static DNS fast-path."
    else
        debug "  VM came up with IP ${BL}${NEW_IP}${CL} (via ${IP_SRC:-?})"
        debug "  Registering DNS: ${VMNAME}.${new_domain} → ${NEW_IP}"
        dns-manager --no-ssl-verify add "${VMNAME}" "${new_domain}" "${NEW_IP}" \
            --description "${MODULE} (cluster:vm converge)" \
            || warn "  dns-manager add failed for ${VMNAME}.${new_domain}"
    fi

    # Stale record from the zone the guest LEFT. The record's actual state holds
    # the pre-change tag, so the old zone is derivable without a second read.
    old_tag="$(jq -r '(.actual["net0.tag"]) // ""' "${DRIFT_FILE}")"
    old_zone="$(vmnet_zone_for_tag "${old_tag:-0}" "${ZONES_FILE}")"
    if [[ -n "${old_zone}" && "${old_zone}" != "${ZONE0}" ]]; then
        debug "  Removing stale DNS: ${VMNAME}.${old_zone}.internal"
        # A missing old record is normal (install-service registers no DNS), so
        # a failure here is informational, not a warning.
        dns-manager --no-ssl-verify delete "${VMNAME}" "${old_zone}.internal" \
            || debug "  no stale DNS to remove for ${VMNAME}.${old_zone}.internal"
    fi

    # An IP in the new subnet means the guest has re-DHCPed, not that the module
    # can serve (#468). Same gate as the update-os.sh reboot path — shared
    # helper, so the two reboot sites cannot drift apart.
    if [[ -n "${NEW_IP}" ]]; then
        wait_for_module_ready "${MODULE}" "${NEW_IP}" 180 \
            || warn "  '${MODULE}' not ready after the subnet-change reboot — later steps may see a starting service"
    fi
    return 0
}

# ── Disruption authorization (ADR-020 D8) ────────────────────────────
#
# A field's change class says a change NEEDS disruption — a guest reboot for a
# subnet change, an offline migrate. This says whether we are ALLOWED to cause
# it. Two levers, and only two:
#
#   --force            an operator, now. `module modify --force` and
#                      `reconcile --apply --force` forward it here.
#   rebootOk + the     a standing per-module permission, honoured only inside
#   scheduled pass     the unattended sweep, where the site has already said
#                      (site.json automaticReboot) that it accepts downtime in
#                      the window. update-tappaas exports TAPPAAS_SCHEDULED_PASS
#                      for exactly this.
#
# `update-tappaas --force` is NOT one of them. It means "run the sweep now" — a
# scheduling override — and forwarding it as disruption authority would let a
# routine update reboot production guests. update-tappaas therefore never passes
# --force to `module modify`, and this script never reads its own environment
# for one.
#
# Unauthorized disruptive drift is DEFERRED by converge-lib: everything else
# applies, a machine-parseable DEFERRED: line is printed, and the converge still
# exits 0. Not applying a change is not a failure; pretending it applied would be.
REBOOT_OK="$(module-manager module resolve "${MODULE}" --json 2>/dev/null \
             | jq -r '(.fields.rebootOk.value) // "false"')"
SCHEDULED_PASS="${TAPPAAS_SCHEDULED_PASS:-0}"

ALLOW_DISRUPTION=0
if [[ "${FORCE}" == "1" ]]; then
    ALLOW_DISRUPTION=1
elif [[ "${REBOOT_OK}" == "true" && "${SCHEDULED_PASS}" == "1" ]]; then
    debug "  rebootOk=true in the scheduled pass — disruptive changes are authorized"
    ALLOW_DISRUPTION=1
fi

converge_apply "${MODULE}" "${SCRIPT_DIR}" "${DRIFT_FILE}" "${CHECK_MODE}" "${ALLOW_DISRUPTION}" "${FORCE}" || exit 1

debug "  ${GN}✓${CL} cluster:vm update-service completed"
exit 0
