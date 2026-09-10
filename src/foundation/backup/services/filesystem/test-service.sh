#!/usr/bin/env bash
#
# backup:filesystem — test-service (ADR-012 §3.1).
#
# FAST: the wiring is complete and internally consistent — manifest present and
#       valid, paths declared, namespace known, runner deployed AND TRIGGERED.
# DEEP (TAPPAAS_TEST_DEEP=1): a capture actually exists in PBS and is recent.
#
# The runner/timer checks are what make `reconcile --apply`'s Step 4 (#583) able
# to see this capability at all. Without them the header above was a claim: the
# service reported "no drift" while its executable was missing from the guest
# and nothing was ever going to trigger it (#626).
#
# Usage: test-service.sh <module-name>   [TAPPAAS_TEST_DEEP=1]
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-job.sh"
# shellcheck source=../../lib/pbs-namespace.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-namespace.sh"
# shellcheck source=../../lib/pbs-placement.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-placement.sh"
# shellcheck source=../../lib/pbs-fs.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-fs.sh"

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || { echo "Usage: $0 <module-name>"; exit 1; }

pass=0; fail=0; warns=0
ok()   { info "    ${GN}✓${CL} $*"; pass=$((pass+1)); }
bad()  { error "    ✗ $*"; fail=$((fail+1)); }
note() { warn  "    ! $*"; warns=$((warns+1)); }

if pbs_is_shim; then
    info "  backup:filesystem: backup is a shim (no datastore) — capture is not realized yet; skipping."
    exit 0
fi

info "  Check 1: capture manifest"
MANIFEST="$(pbs_fs_manifest_path "${MODULE}")"
if [[ -f "${MANIFEST}" ]] && jq -e . "${MANIFEST}" >/dev/null 2>&1; then
    n="$(jq -r '.paths | length' "${MANIFEST}")"
    if [[ "${n}" -gt 0 ]]; then ok "manifest lists ${n} path(s) → $(jq -r '.namespace' "${MANIFEST}")"
    else bad "manifest declares no paths — nothing would be captured"; fi
else
    bad "no valid capture manifest at ${MANIFEST} (run update-module.sh ${MODULE})"
fi

info "  Check 2: namespace exists on the PBS"
NS="$(pbs_fs_namespace "${MODULE}")"
if pbs_ns_list 2>/dev/null | grep -qx "${NS}"; then ok "namespace ${NS} present"
else bad "namespace ${NS} missing on $(pbs_storage_name)"; fi

info "  Check 3: the runner is deployed on the guest"
CONFIG="${CONFIG_DIR:-/home/tappaas/config}/${MODULE}.json"
VMNAME="$(jq -r '.vmname // empty' "${CONFIG}" 2>/dev/null || true)"
ZONE="$(jq -r '.zone0 // "mgmt"' "${CONFIG}" 2>/dev/null || echo mgmt)"
RUNNER="$(pbs_fs_runner_path)"
if [[ -z "${VMNAME}" ]]; then
    bad "${MODULE} has no vmname — cannot check the guest"
else
    GUEST="${VMNAME}.${ZONE}.internal"
    if ! tappaas_ssh_guest -o ConnectTimeout=10 -o BatchMode=yes "tappaas@${GUEST}" true >/dev/null 2>&1; then
        note "cannot reach ${GUEST} — runner and trigger not checked"
    else
        if tappaas_ssh_guest -o BatchMode=yes "tappaas@${GUEST}" "test -x '${RUNNER}'" >/dev/null 2>&1; then
            ok "runner present and executable at ${RUNNER} on ${GUEST}"
        else
            bad "${RUNNER} is MISSING on ${GUEST} — the capture cannot run (re-run: update-module.sh ${MODULE})"
        fi

        # A delivered runner with nothing to trigger it captures exactly nothing.
        # The timer is declarative (NixOS keeps /etc/systemd/system read-only), so
        # a guest whose config predates the TAPPaaS baseline simply has no unit —
        # a silent no-capture this check turns into a visible failure.
        info "  Check 4: the capture timer exists and is active on the guest"
        if tappaas_ssh_guest -o BatchMode=yes "tappaas@${GUEST}" \
                "systemctl is-active tappaas-fs-backup.timer" >/dev/null 2>&1; then
            ok "tappaas-fs-backup.timer is active on ${GUEST}"
        elif tappaas_ssh_guest -o BatchMode=yes "tappaas@${GUEST}" \
                "systemctl cat tappaas-fs-backup.timer" >/dev/null 2>&1; then
            bad "tappaas-fs-backup.timer exists on ${GUEST} but is not active — nothing triggers the capture"
        else
            bad "${GUEST} declares no tappaas-fs-backup.timer — the runner would never fire. Add the TAPPaaS baseline unit (templates/tappaas-common.nix) to this guest's NixOS config."
        fi
    fi
fi

if [[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]]; then
    info "  Check 5 (deep): a capture exists and is recent"
    # Query the datastore from the PBS NODE itself. Not `proxmox-backup-client`:
    # that needs a user@host repository spec and a credential, neither of which
    # a test on the mothership has — it silently returned nothing and reported
    # "no capture found" while a capture sat right there.
    snaps="$(_pbs_node_run proxmox-backup-debug api get \
        "/admin/datastore/$(pbs_storage_name)/snapshots" --ns "${NS}" --output-format json 2>/dev/null \
        | jq -r --arg m "${MODULE}" '.[]? | select(."backup-id"==$m) | ."backup-time"' 2>/dev/null \
        | sort -n | tail -1)"
    if [[ -n "${snaps}" ]]; then
        age=$(( $(date +%s) - snaps ))
        if [[ "${age}" -lt 172800 ]]; then ok "most recent capture is $((age/3600))h old"
        else note "most recent capture is $((age/86400))d old (>48h)"; fi
    else
        note "no capture found yet in ${NS} — the first run may not have happened"
    fi
fi

info "  Results: ${GN}${pass} passed${CL}, ${fail} failed, ${warns} warnings"
[[ "${fail}" -eq 0 ]]
