#!/usr/bin/env bash
#
# TAPPaaS OS Update Script
#
# Updates a VM's operating system based on its type (NixOS or Debian/Ubuntu).
# Handles IP detection, SSH setup, and OS-specific update procedures.
#
# Usage: update-os.sh <vmname> <vmid> <node>
#
# Arguments:
#   vmname - Name of the VM
#   vmid   - Proxmox VM ID
#   node   - Proxmox node name (e.g., tappaas1)
#
# For NixOS VMs, expects ./<vmname>.nix to exist in the current directory.
#
# Examples:
#   update-os.sh myvm 610 tappaas1   # Looks for ./myvm.nix if NixOS
#

set -Eeuo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly MGMT="mgmt"

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh
# The site's time and locale, rendered per OS family (#472, #87). Optional: a
# mothership that has not deployed it yet updates as before, without the facts.
# shellcheck source=site-locale.sh
[[ -f /home/tappaas/bin/site-locale.sh ]] && . /home/tappaas/bin/site-locale.sh
# shellcheck source=nix-site-key.sh
[[ -f /home/tappaas/bin/nix-site-key.sh ]] && . /home/tappaas/bin/nix-site-key.sh
# shellcheck source=log-shipping.sh
[[ -f /home/tappaas/bin/log-shipping.sh ]] && . /home/tappaas/bin/log-shipping.sh

# When invoked as a module-update sub-step (templates:nixos / templates:debian
# update-service.sh set TAPPAAS_OS_AS_DEBUG=1), route this script's [Info]
# milestones to [Debug] so a routine module update stays quiet — the parent
# already prints the "Calling templates:nixos update-service.sh …" line, making
# the full OS-update narration redundant noise. Progress dots (run_quiet) and
# warn/error/die are unaffected, and the detail is still recoverable with
# TAPPAAS_DEBUG=1. A standalone/operator run (health-manager update-os verb,
# env unset) keeps the normal [Info] output.
# announce() stays [Info] either way: the one line that says what the progress
# dots below it are.
announce() { [[ "${OPT_SILENT}" -eq 1 ]] || echo -e "${DGN}[Info]${CL} $*"; }
if [[ "${TAPPAAS_OS_AS_DEBUG:-0}" == "1" ]]; then
    info() { debug "$@"; }
fi

# An unguarded command that fails ends the script through `set -e`, printing
# nothing: #711 saw exactly that — the announce line, then silence, then the
# caller's bare "✗ templates:nixos re-apply failed", with no evidence left to
# say how far it got or what broke. `set -E` above carries this trap into the
# functions and subshells where the work actually happens; the trap only
# REPORTS (it does not exit), so `set -e` still decides the outcome and a
# `|| die` / `|| warn` path is untouched — those are not ERR events.
trap 'tappaas_err_report $? "${LINENO}" "${BASH_COMMAND}"' ERR
tappaas_err_report() {
    local rc="$1" line="$2" cmd="$3"
    # Report ONLY when errexit is still on, i.e. when this failure is about to
    # end the script unannounced. `set +e` does not suppress an ERR trap, so
    # without this check run_quiet's deliberate `set +e; <pipeline>; set -e`
    # retry idiom — which reads PIPESTATUS itself — would print an error for
    # every expected nixos-rebuild retry.
    case "$-" in *e*) ;; *) return 0 ;; esac
    # FUNCNAME[1] is the function the failing command ran in (FUNCNAME[0] is
    # this reporter); "main" when it failed at the top level.
    error "update-os.sh: ${FUNCNAME[1]:-main}() failed at line ${line} (exit ${rc}): ${cmd}"
}

# #533: managers run as the tappaas operator, never root — under sudo, SSH
# resolves identity from /root/.ssh and fails (ADR-018). Refuse root up front.
tappaas_require_operator

# Run a command quietly (progress dots in place of its output) while preserving
# its REAL exit code, and die on failure. A bare `cmd 2>&1 | while read; do
# printf .; done` pipeline reports the while-loop's exit status (always 0), so
# a failure of <cmd> is silently swallowed — which let a failed nixos-rebuild
# look like success (issue #201). PIPESTATUS[0] recovers the true code; `set
# +e` keeps the pipeline from aborting before we can read it.
#   run_quiet <description> <command> [args...]
run_quiet() {
    local desc="$1" rc
    shift
    # Tee the live output to a log so the dots stay terse but the REAL error is
    # recoverable on failure. Previously the output was discarded entirely, so a
    # failed nixos-rebuild surfaced only as a generic exit code — the actual
    # stderr that identifies which step exploded was lost (issue #309 ask 1).
    local _log
    _log="$(mktemp /tmp/tappaas-update-os.XXXXXX.log)"
    set +e
    "$@" 2>&1 | tee "${_log}" | while IFS= read -r _; do printf "."; done
    rc=${PIPESTATUS[0]}
    set -e
    echo ""
    if [[ "${rc}" -ne 0 ]]; then
        error "${desc} failed (exit ${rc}) — last 20 lines of output:"
        tail -n 20 "${_log}" | sed 's/^/    /' >&2
        warn "Full output of the failed step saved to ${_log}"
        die "${desc} failed (exit ${rc}); see ${_log}"
    fi
    rm -f "${_log}"
}

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <vmname> <vmid> <node>

Update a VM's operating system based on its type (NixOS or Debian/Ubuntu).

Arguments:
    vmname  Name of the VM
    vmid    Proxmox VM ID
    node    Proxmox node name (e.g., tappaas1)

Examples:
    ${SCRIPT_NAME} myvm 610 tappaas1

The script will:
  - Detect the VM's IP address (via guest agent or DHCP leases)
  - Detect the OS type (NixOS or Debian/Ubuntu)
  - For NixOS: Run nixos-rebuild using ./<vmname>.nix and reboot
  - For Debian/Ubuntu: Run apt update/upgrade
  - Fix DHCP hostname registration
EOF
}

# Get VM IP address via Proxmox guest agent
get_vm_ip_guest_agent() {
    local node="$1"
    local vmid="$2"

    ssh "root@${node}.${MGMT}.internal" "qm guest cmd ${vmid} network-get-interfaces" 2>/dev/null | \
        jq -r '.[] | select(.name | test("^lo$") | not) | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"' 2>/dev/null | \
        head -1
}

# Get VM IP address via DHCP leases on firewall
get_vm_ip_dhcp() {
    local node="$1"
    local vmid="$2"

    # Get the VM's MAC address
    local vm_mac
    vm_mac=$(ssh "root@${node}.${MGMT}.internal" "qm config ${vmid} | grep 'net0' | sed -n 's/.*virtio=\([^,]*\).*/\\1/p'" 2>/dev/null)

    if [[ -z "${vm_mac}" ]]; then
        return 1
    fi

    # Query DHCP leases on firewall
    local mac_lower
    mac_lower=$(echo "${vm_mac}" | tr '[:upper:]' '[:lower:]')
    ssh "root@firewall.${MGMT}.internal" "grep -i '${mac_lower}' /var/db/dnsmasq.leases" 2>/dev/null | awk '{print $3}'
}

# Wait for VM to get IP address using multiple methods
wait_for_vm_ip() {
    local node="$1"
    local vmid="$2"
    local max_attempts="${3:-30}"
    local vm_ip=""

    debug "Waiting for VM to get IP address..." >&2

    for ((i=1; i<=max_attempts; i++)); do
        # Try guest agent first
        vm_ip=$(get_vm_ip_guest_agent "${node}" "${vmid}")

        # Fall back to DHCP leases if guest agent doesn't work
        if [[ -z "${vm_ip}" ]]; then
            vm_ip=$(get_vm_ip_dhcp "${node}" "${vmid}")
        fi

        if [[ -n "${vm_ip}" ]]; then
            echo "${vm_ip}"
            return 0
        fi

        echo "  Attempt ${i}/${max_attempts}: waiting for IP address..." >&2
        sleep 10
    done

    return 1
}

# Update SSH known_hosts for an IP
update_ssh_known_hosts() {
    local ip="$1"

    # Capture ssh-keygen's stdout ("# Host <ip> found: line N", "known_hosts
    # updated.", "Original contents retained…") and route it to [Debug] — it is
    # noise on the console, useful only when troubleshooting.
    local _kh_out
    _kh_out="$(ssh-keygen -R "${ip}" 2>/dev/null || true)"
    [[ -n "${_kh_out}" ]] && while IFS= read -r _kh_l; do debug "  ${_kh_l}"; done <<<"${_kh_out}"
    # Best-effort: if the VM's sshd is mid-restart, ssh-keyscan returns non-zero
    # and the next wait_for_ssh/rebuild attempt will retry. Don't let a transient
    # failure here trip set -e and abort the retry loop.
    # grep -v '^#': ssh-keyscan emits a "# <ip>:22 SSH-2.0-..." banner per key,
    # which is never read back. Appending them every run had grown one operator's
    # known_hosts to 5711 lines of which 90% were these comments.
    ssh-keyscan -H "${ip}" 2>/dev/null | grep -v '^#' >> ~/.ssh/known_hosts || true
}

# Wait for SSH to become available (cloud-init may still be setting up keys)
wait_for_ssh() {
    local ip="$1"
    local max_wait="${2:-120}"
    local waited=0

    info "Waiting for SSH to become available on ${ip}..."
    while ! ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new -o BatchMode=yes "tappaas@${ip}" "exit 0" &>/dev/null; do
        sleep 3
        waited=$((waited + 3))
        if [[ $waited -ge $max_wait ]]; then
            warn "SSH not available on ${ip} after ${max_wait}s"
            return 1
        fi
    done
    info "SSH is available on ${ip}"
    return 0
}

# wait_for_guest_settled <ip> [max seconds] — until systemd on the guest has no
# job queued, seen empty twice in a row (#753). sshd answering once is not a
# settled guest: right after a switch it can still be the OLD sshd, which the
# activation restarts a moment later, and right after a boot units are still
# starting. The verify step that follows reconnects by name, and on hrossen
# 2026-10-01 it hit that gap — coturn's update failed and rolled back for an
# SSH check that would have passed seconds later. Bounded; a guest that never
# settles is reported, not failed: the verify step judges it.
wait_for_guest_settled() {
    local ip="$1" max="${2:-90}" waited=0 empty=0 jobs
    while (( waited < max )); do
        jobs="$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "tappaas@${ip}" \
            "systemctl list-jobs --no-legend --no-pager 2>/dev/null | wc -l" 2>/dev/null)" || jobs=""
        if [[ "${jobs}" == "0" ]]; then
            (( ++empty >= 2 )) && { debug "guest ${ip} settled after ${waited}s"; return 0; }
        else
            empty=0
        fi
        sleep 3; waited=$(( waited + 3 ))
    done
    warn "guest ${ip} still had systemd jobs queued after ${max}s — verifying anyway"
    return 1
}

# Reboot a guest and wait until its module can SERVE, not merely until sshd
# answers (#468). The one reboot path: the post-rebuild reboot below and
# `health-manager reboot` (reboot-guest.sh) both take it (#730).
# A backup holding the guest refuses the reboot (#686). That is a postponed
# reboot, not a failure: rc 3, with the lock holder in REBOOT_LOCK_HOLDER.
REBOOT_LOCK_HOLDER=""
reboot_guest() {
    local vmname="$1" vmid="$2" node="$3" vm_ip="$4"
    REBOOT_LOCK_HOLDER=""
    if declare -F wait_for_vm_unlock >/dev/null 2>&1; then
        wait_for_vm_unlock "${vmid}" "${node}" "${TAPPAAS_LOCK_WAIT:-600}" || true
    fi
    if ! ssh "root@${node}.${MGMT}.internal" "qm reboot ${vmid}"; then
        declare -F vm_lock_holder >/dev/null 2>&1 && REBOOT_LOCK_HOLDER="$(vm_lock_holder "${vmid}" "${node}")"
        [[ -z "${REBOOT_LOCK_HOLDER}" ]] || return 3
        die "could not reboot ${vmname} (VM ${vmid})"
    fi

    # Wait for sshd to come back (replaces fixed sleep 60 — issue #376).
    update_ssh_known_hosts "${vm_ip}"
    wait_for_ssh "${vm_ip}" 120 || warn "sshd unreachable after 120 s — subsequent service updaters may fail"
    wait_for_guest_settled "${vm_ip}" 90 || true
    # sshd answering is NOT the module being able to serve (#468): it comes
    # up seconds after boot while the module's own service may need far
    # longer, and the post-update tests run straight after this returns.
    wait_for_module_ready "${vmname}" "${vm_ip}" 180 \
        || warn "  post-update tests may run against a still-starting '${vmname}'"
}

# Detect OS type on the VM
detect_os_type() {
    local ip="$1"

    # Try to detect NixOS
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "tappaas@${ip}" "test -f /etc/NIXOS" 2>/dev/null; then
        echo "nixos"
        return 0
    fi

    # Try to detect Debian/Ubuntu
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "tappaas@${ip}" "test -f /etc/debian_version" 2>/dev/null; then
        echo "debian"
        return 0
    fi

    echo "unknown"
}

# run_quiet without the die(): returns the real exit code so the caller can
# classify it. Leaves the saved log path in RUN_QUIET_LOG.
#   run_quiet_rc <description> <command> [args...]
RUN_QUIET_LOG=""
# A rebuild's ssh must be able to NOTICE a dead connection (#720).
#
# ConnectTimeout bounds only the handshake. Once connected, ssh will wait for a
# peer that is never coming — and a `switch` that restarts sshd or dbus-broker is
# exactly how the peer stops coming. On hrossen's first boundary that stranded one
# guest for 93 minutes with no output: the remote nixos-rebuild had finished ("Done.
# The new configuration is ...") and the connection simply never returned. The
# retry below is correct and was unreachable, because the attempt never ended.
#
# Keepalives turn that silence into exit 255 in ~3 minutes, which is precisely the
# case the retry already handles. REBUILD_MAX_SECONDS is a second, blunter net for
# an ssh that wedges without the keepalive firing; it is deliberately generous —
# a cross-release guest rebuild runs minutes, not an hour.
SSH_REBUILD_OPTS=(-o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=6)
REBUILD_MAX_SECONDS="${REBUILD_MAX_SECONDS:-3600}"

run_quiet_rc() {
    local desc="$1" rc
    shift
    RUN_QUIET_LOG="$(mktemp /tmp/tappaas-update-os.XXXXXX.log)"
    set +e
    "$@" 2>&1 | tee "${RUN_QUIET_LOG}" | while IFS= read -r _; do printf "."; done
    rc=${PIPESTATUS[0]}
    set -e
    echo ""
    if [[ "${rc}" -ne 0 ]]; then
        error "${desc} failed (exit ${rc}) — last 20 lines of output:"
        tail -n 20 "${RUN_QUIET_LOG}" | sed 's/^/    /' >&2
        warn "Full output of the failed step saved to ${RUN_QUIET_LOG}"
        return "${rc}"
    fi
    rm -f "${RUN_QUIET_LOG}"
    RUN_QUIET_LOG=""
    return 0
}

# What a non-zero `ssh … nixos-rebuild switch` exit means, in one phrase.
nixos_rebuild_exit_meaning() {
    local rc="$1"
    case "${rc}" in
        255) echo "ssh connection failed or was dropped" ;;
        1)   echo "nix evaluation/build error, or the command itself could not run (sudo, PATH)" ;;
        2)   echo "activation: a unit failed to reload (switch-to-configuration bit 2)" ;;
        4)   echo "activation: a unit failed to START (switch-to-configuration bit 4) — the new generation is active but a service is down" ;;
        6)   echo "activation: units failed to reload AND to start (switch-to-configuration bits 2+4)" ;;
        *)   echo "unclassified exit code" ;;
    esac
}

# Which units failed and why — the information that names the real cause.
# Best effort: must never mask the original failure.
report_failed_units() {
    local ip="$1" units u
    units="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "tappaas@${ip}" \
        "systemctl --failed --no-legend --plain 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
    if [[ -z "${units}" ]]; then
        warn "No failed units reported by ${ip} (or the guest is unreachable) — see the saved rebuild log above."
        return 0
    fi
    error "Failed units on ${ip}:"
    while IFS= read -r u; do
        [[ -z "${u}" ]] && continue
        error "  ── ${u} ──"
        ssh -o BatchMode=yes -o ConnectTimeout=15 "tappaas@${ip}" \
            "sudo journalctl -u '${u}' -n 40 --no-pager 2>/dev/null" 2>/dev/null \
            | sed 's/^/    /' >&2 || true
    done <<< "${units}"
}

# Wait for cloud-init to finish (Debian/Ubuntu)
wait_for_cloud_init() {
    local ip="$1"

    info "Waiting for cloud-init to finish..."
    # Its "status: done" is not ours to print.
    ssh "tappaas@${ip}" "cloud-init status --wait" >/dev/null 2>&1 || true
}

# Wait until the VM is actually ready for privileged provisioning: cloud-init
# has finished AND passwordless sudo works for the tappaas user. A VM (especially
# the first in a freshly-activated zone) can accept SSH on port 22 before
# cloud-init has finished laying down /etc/nixos, the tappaas account and its
# NOPASSWD sudoers entry — running nixos-rebuild against that half-set-up target
# is exactly the flaky-first-attempt failure in issue #309. Best-effort: warns
# and proceeds if the deadline passes, so a quirk here never hard-blocks install.
wait_for_provisioning() {
    local ip="$1"
    local max="${2:-150}"
    local waited=0

    info "Waiting for cloud-init to finish on ${ip}..."
    ssh -o BatchMode=yes "tappaas@${ip}" "cloud-init status --wait" >/dev/null 2>&1 || true

    info "Waiting for passwordless sudo on ${ip}..."
    while ! ssh -o BatchMode=yes "tappaas@${ip}" "sudo -n true" 2>/dev/null; do
        sleep 3
        waited=$((waited + 3))
        if [[ ${waited} -ge ${max} ]]; then
            warn "passwordless sudo not ready on ${ip} after ${max}s — proceeding anyway"
            return 0
        fi
    done
    info "  ${GN}✓${CL} cloud-init done and passwordless sudo ready"
}

# resolve_nixos_config <vmname> [nix_dir] [config_dir]
#
# Resolves the NixOS config file for a module. Plain deploys: <nix_dir>/<vmname>.nix.
# Resolution order once that's absent:
#   1. The module's declared `location` DIRECTORY, by instance name then by the
#      location basename (#495). This is where the .nix actually lives for a
#      deployed instance; searching only `nix_dir` made resolution depend on the
#      caller's working directory, so `module reconcile --apply` failed from
#      anywhere but the module's own directory while `update-module.sh` (which
#      cd's to the module dir first) always worked.
#   2. Basename of `location`, under nix_dir. Works regardless of how many
#      hyphenated components vmname has -- <source>, <source>-<env>, or
#      <source>-<env>-<instance> alike (#440: the old suffix-strip below only
#      ever handled the 2-part case, and silently no-op'd on 3-part vmnames
#      like <source>-<env>-<instance>, since environment there sits before the
#      instance name, not at the end).
#   3. Legacy fallback: strip a trailing -<environment> suffix from vmname
#      (#286, read .variant until it was retired in #438). Only correct for
#      the 2-part case; kept for modules without a `location` field. Searched
#      under the location dir first, then nix_dir.
# Echoes the resolved path and returns 0, or returns 1 with no output.
resolve_nixos_config() {
    local vmname="$1" nix_dir="${2:-.}" config_dir="${3:-${CONFIG_DIR:-}}"
    local nix_config="${nix_dir}/${vmname}.nix"
    if [[ -f "${nix_config}" ]]; then
        echo "${nix_config}"
        return 0
    fi

    local cfg="${config_dir}/${vmname}.json"
    [[ -f "${cfg}" ]] || return 1

    local location source_vmname candidate
    location=$(jq -r '.moduleSource // .location // empty' "${cfg}" 2>/dev/null)
    if [[ -n "${location}" ]]; then
        source_vmname="$(basename "${location}")"
        # Location dir first (#495), then nix_dir (preserves the #440 behaviour
        # for a recorded location whose directory is not present locally).
        for candidate in "${location}/${vmname}.nix" \
                         "${location}/${source_vmname}.nix" \
                         "${nix_dir}/${source_vmname}.nix"; do
            if [[ -f "${candidate}" ]]; then
                echo "${candidate}"
                return 0
            fi
        done
    fi

    local env
    env=$(jq -r '.environment // empty' "${cfg}" 2>/dev/null)
    if [[ -n "${env}" ]]; then
        source_vmname="${vmname%-"${env}"}"
        for candidate in "${location:+${location}/${source_vmname}.nix}" \
                         "${nix_dir}/${source_vmname}.nix"; do
            if [[ -n "${candidate}" && -f "${candidate}" ]]; then
                echo "${candidate}"
                return 0
            fi
        done
    fi

    return 1
}

# Update NixOS VM
# release_move_of <vm_ip> <nixpkgs_arg> <remote_nix_path>
# Echoes "<running> <target>" (e.g. "25.11 26.05") and returns 0 when the system
# this update would build is a different NixOS RELEASE from the one the guest
# runs. Returns 1 when it is the same release, or when either side cannot be read
# — the caller then switches as it always has, and a build error surfaces there.
#
# The build is the same derivation nixos-rebuild uses, so it costs nothing extra:
# the switch or boot that follows is a store hit. Only the numeric release is
# compared: a guest built from a nixpkgs tarball reports "26.05pre-git", one
# installed from the flake-built template "26.05.20260922.1bc55b9" — the same
# release, which must not read as a move (measured on hrossen's logging guest).
# The release is the first NN.NN anywhere in the line: a fresh clone of the image
# template reports "efi-qcow2-25.11.20260522.b77b3de", and a match anchored at the
# start read nothing there, so every fresh install switched across the release.
release_move_of() {
    local ip="$1" nixpkgs_arg="$2" cfg="$3" cur top new
    cur="$(ssh -o BatchMode=yes "tappaas@${ip}" \
        "grep -oE '[0-9]+\\.[0-9]+' /run/current-system/nixos-version | head -n 1" 2>/dev/null)" || return 1
    top="$(ssh -o BatchMode=yes "tappaas@${ip}" \
        "sudo nix-build '<nixpkgs/nixos>' -A system ${nixpkgs_arg} -I nixos-config=${cfg} --no-out-link" \
        2>/dev/null | tail -n 1)" || return 1
    [[ "${top}" == /nix/store/* ]] || return 1
    new="$(ssh -o BatchMode=yes "tappaas@${ip}" "grep -oE '[0-9]+\\.[0-9]+' ${top}/nixos-version | head -n 1" 2>/dev/null)" || return 1
    [[ -n "${cur}" && -n "${new}" && "${cur}" != "${new}" ]] || return 1
    printf '%s %s' "${cur}" "${new}"
}

# ── Guest systems are built on the mothership (#774) ─────────────────────────
# A guest that evaluates and builds its own system needs ~0.9 GB of headroom for
# the evaluation alone (measured on hrossen: 650–940 MB whatever the VM's size),
# up to 5 GB of disk for a release move, its own cores for what the cache lacks,
# and GitHub plus cache.nixos.org on every rebuild. Here the mothership does all
# of that and the guest only receives the closure and activates it.
#
# Why the mount namespace: modules import the guest's own files by absolute path
# (/etc/nixos/hardware-configuration.nix, tappaas-common.nix, tappaas-backup.nix,
# and through the baseline tappaas-site.nix and tappaas-nfs.nix). The old
# --target-host path evaluated them on the mothership and read the MOTHERSHIP's
# hardware config, which broke every guest it switched. A copy of the guest's
# /etc/nixos bind-mounted over /etc/nixos, in a namespace of its own, makes every
# such path resolve to the guest's file without changing a module. Proven on
# hrossen: built this way, vaultwarden's system is the same store path the guest
# had built for itself.
GUEST_BUILD_STAGE="${GUEST_BUILD_STAGE:-/var/lib/tappaas-guest-build}"
# Each guest's current and previous system stay rooted here, so a rollback still
# finds the previous one in the mothership's store; the rest goes with its GC.
GUEST_BUILD_GCROOTS="${GUEST_BUILD_GCROOTS:-/nix/var/nix/gcroots/tappaas-guests}"

# The pinned nixpkgs as a store path, fetched once by the lock's narHash — never
# re-downloaded once present, whatever tarball-ttl says. Empty when the lock does
# not pin a GitHub revision.
pinned_nixpkgs_source() {
    local lock="$1" expr
    expr="$(jq -r '.nodes.nixpkgs.locked | select(.type == "github" and .narHash != null)
        | "builtins.fetchTree { type = \"github\"; owner = \"\(.owner)\"; repo = \"\(.repo)\"; rev = \"\(.rev)\"; narHash = \"\(.narHash)\"; }"' \
        "${lock}" 2>/dev/null)" || return 1
    [[ -n "${expr}" ]] || return 1
    nix eval --impure --raw --expr "(${expr}).outPath" 2>/dev/null
}

# The pinned nixpkgs fetched ON THE GUEST, for the fallback where the guest
# builds its own system: fetchTarball with the lock's narHash (ADR-033 D8), so
# what GitHub serves is checked against the hash the signed release covers —
# never a bare tarball URL. Prints the guest's store path; fails when the lock
# carries no narHash, or the fetch fails or does not match.
guest_pinned_nixpkgs() {
    local ip="$1" lock="$2" owner repo rev hash out
    IFS=$'\t' read -r owner repo rev hash < <(jq -r '.nodes.nixpkgs.locked
        | select(.type == "github") | [.owner, .repo, .rev, .narHash] | @tsv' "${lock}" 2>/dev/null) || return 1
    [[ "${owner}/${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "${rev}" =~ ^[0-9a-f]{40}$ \
        && "${hash}" =~ ^sha256-[A-Za-z0-9+/]{43}=$ ]] || return 1
    out="$(ssh -n -o BatchMode=yes "tappaas@${ip}" "nix eval --impure --raw --expr 'builtins.fetchTarball { url = \"https://github.com/${owner}/${repo}/archive/${rev}.tar.gz\"; sha256 = \"${hash}\"; }'" 2>/dev/null)" || return 1
    [[ "${out}" =~ ^/nix/store/[a-z0-9]{32}-[^/[:space:]]+$ ]] || return 1
    printf '%s' "${out}"
}

# Whether any binary cache the mothership's Nix is configured with answers. Not
# a formality: before building a derivation Nix asks the cache for its output,
# and with the cache unreachable that lookup is fatal (fallback = false) — so a
# WAN outage stopped even a config-only update whose inputs were all in the store
# (#774, proven with egress blocked on hrossen). Probed once, 5 s per cache.
binary_cache_reachable() {
    local url
    for url in $(nix config show substituters 2>/dev/null); do
        curl -fsS -o /dev/null --max-time 5 "${url%/}/nix-cache-info" 2>/dev/null && return 0
    done
    return 1
}

# guest_build_on_cicd <vmname> <vm_ip> <config basename> <nixpkgs store path>
# Stages the guest's /etc/nixos, builds its system against it and copies the
# closure to the guest. Prints the system's store path — and nothing else on
# stdout: every message goes to stderr. The build is rooted as
# <vmname>.new until the switch succeeds (guest_build_promote).
guest_build_on_cicd() {
    local vmname="$1" vm_ip="$2" cfg="$3" src="$4"
    local stage="${GUEST_BUILD_STAGE}/${vmname}" link="${GUEST_BUILD_GCROOTS}/${vmname}.new" out

    sudo -n rm -rf "${stage}" && sudo -n install -d -m 0700 "${stage}" \
        && sudo -n install -d -m 0755 "${GUEST_BUILD_GCROOTS}" || return 1
    ssh -n -o BatchMode=yes "tappaas@${vm_ip}" "sudo -n tar -C /etc/nixos -cf - ." \
        | sudo -n tar -C "${stage}" -xf - || return 1

    # Unreachable cache: build from what the mothership's store holds, without
    # asking it. Reachable: fallback=true still builds whatever a cache that fails
    # part-way could not deliver.
    local substitute=true
    if ! binary_cache_reachable; then
        substitute=false
        # To stderr: this function's stdout is the store path it returns.
        warn "No binary cache answers — building ${vmname} from the mothership's store alone (#774)" >&2
    fi
    run_quiet_rc "building ${vmname}'s system on the mothership" \
        sudo -n unshare --mount --propagation private -- /bin/sh -c '
            PATH=/run/current-system/sw/bin:$PATH
            mount --bind "$1" /etc/nixos || exit 1
            exec nix-build "<nixpkgs/nixos>" -A system -I "nixpkgs=$2" \
                -I "nixos-config=/etc/nixos/$3" -o "$4" \
                --option substitute "$5" --option fallback true' \
            sh "${stage}" "${src}" "${cfg}" "${link}" "${substitute}" \
        >&2 || return 1
    out="$(readlink -f "${link}")"
    [[ "${out}" == /nix/store/*-nixos-system-* ]] || return 1

    # Signed with the site key (ADR-033 D8), the whole closure: what came from
    # cache.nixos.org keeps Hydra's signature as well. Unsigned, nothing is sent.
    local key="" check=()
    if ! declare -F nix_site_key_ensure >/dev/null 2>&1 || ! nix_site_key_ensure \
        || ! key="$(nix_site_key_public)" || ! nix_site_key_sign "${out}" >&2; then
        warn "could not sign ${vmname}'s system with the site's Nix key (ADR-033 D8)" >&2
        return 1
    fi
    # The guest checks every path against the keys it trusts. One that has not
    # learnt the site key yet (built before D8, or its tappaas-site.nix not
    # written) takes this copy unchecked, ONCE: the system it activates trusts
    # the key, so the next copy is checked. Skipping the check needs a trusted
    # user — tappaas is, through the baseline's trusted-users = @wheel.
    # No --substitute-on-destination: the guest is to fetch nothing itself.
    if ! guest_trusts_site_key "${vm_ip}" "${key}"; then
        warn "${vmname} does not trust the site's Nix key yet — this copy is unchecked; the system it gets trusts ${key%%:*} (ADR-033 D8)" >&2
        check=(--no-check-sigs)
    fi
    run_quiet_rc "copying ${vmname}'s system to ${vm_ip}" \
        env NIX_SSHOPTS="-o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=6" \
        nix copy ${check[@]+"${check[@]}"} --to "ssh-ng://tappaas@${vm_ip}" "${out}" >&2 || return 1
    printf '%s' "${out}"
}

# Whether the guest's Nix daemon trusts <public key> — read from the nix.conf
# it runs with (not the user's merged view), so a key only built into a system
# that is not activated yet does not count.
guest_trusts_site_key() {
    local ip="$1" key="$2"
    ssh -n -o BatchMode=yes "tappaas@${ip}" "cat /etc/nix/nix.conf" 2>/dev/null \
        | sed -n 's/^[[:space:]]*trusted-public-keys[[:space:]]*=//p' \
        | tr -s ' \t' '\n\n' | grep -qxF -- "${key}"
}

# After a successful switch: <vmname>.new becomes .current, the old .current
# becomes .previous. A failed switch drops .new.
guest_build_promote() {
    local vmname="$1" ok="$2"
    local r="${GUEST_BUILD_GCROOTS}/${vmname}"
    if [[ "${ok}" == 1 ]]; then
        if [[ -L "${r}.current" && "$(readlink "${r}.current")" != "$(readlink "${r}.new")" ]]; then
            sudo -n mv -fT "${r}.current" "${r}.previous" || true
        fi
        sudo -n mv -fT "${r}.new" "${r}.current" || true
    else
        sudo -n rm -f "${r}.new" || true
    fi
}

# The command that activates a system already in the guest's store — what
# nixos-rebuild does after its build: point the system profile at it, then run
# switch-to-configuration under systemd-run, so the activation survives the ssh
# session it restarts. Exit codes are switch-to-configuration's (bits 2 and 4).
guest_activate_cmd() {
    local system="$1" action="$2"
    printf '%s' "sudo nix-env -p /nix/var/nix/profiles/system --set ${system} && sudo systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER --collect --no-ask-password --pipe --quiet --service-type=exec --unit=tappaas-switch-to-configuration --wait ${system}/bin/switch-to-configuration ${action}"
}

# release_move_of for a system built here: the release it carries is read from
# the mothership's store, the running one from the guest.
release_move_to() {
    local ip="$1" system="$2" cur new
    cur="$(ssh -o BatchMode=yes "tappaas@${ip}" \
        "grep -oE '[0-9]+\\.[0-9]+' /run/current-system/nixos-version | head -n 1" 2>/dev/null)" || return 1
    new="$(grep -oE '[0-9]+\.[0-9]+' "${system}/nixos-version" 2>/dev/null | head -n 1)" || return 1
    [[ -n "${cur}" && -n "${new}" && "${cur}" != "${new}" ]] || return 1
    printf '%s %s' "${cur}" "${new}"
}

update_nixos() {
    local vmname="$1"
    local vmid="$2"
    local node="$3"
    local vm_ip="$4"

    # Gate on cloud-init done + passwordless sudo before any privileged step
    # (scp install, nixos-generate-config, nixos-rebuild). Stops the flaky
    # first-attempt failure where SSH is up but provisioning isn't (#309 ask 2).
    wait_for_provisioning "${vm_ip}"

    local nix_config
    if ! nix_config=$(resolve_nixos_config "${vmname}" "."); then
        die "NixOS configuration file not found for '${vmname}' (searched the module's .moduleSource directory, then ./${vmname}.nix, then the location-basename and -<environment> fallbacks)"
    fi
    # Source module name (e.g. "hermes"), used below for the companion JSON
    # copied to the VM -- always the resolved .nix file's own basename, so it
    # stays correct for both the direct-match and any fallback-resolved case.
    local _source_vmname
    _source_vmname="$(basename "${nix_config}" .nix)"

    info "Using NixOS config: ${nix_config}"
    # The guest's /etc/nixos stays the source of truth: everything below is
    # written there first. The system is then built on the mothership against a
    # copy of that directory (guest_build_on_cicd, #774), or on the guest itself
    # when that is impossible. Never --target-host: it read the mothership's own
    # /etc/nixos/hardware-configuration.nix and broke sshd/qemu-agent on every
    # guest it switched.
    local nix_basename remote_nix_path
    nix_basename="$(basename "${nix_config}")"
    remote_nix_path="/etc/nixos/${nix_basename}"

    info "Copying ${nix_config} to ${vm_ip}:${remote_nix_path}"
    scp -q -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${nix_config}" "tappaas@${vm_ip}:/tmp/${nix_basename}" \
        || die "failed to scp ${nix_config} to ${vm_ip}"
    ssh -o BatchMode=yes "tappaas@${vm_ip}" "sudo install -m 0644 /tmp/${nix_basename} ${remote_nix_path} && rm -f /tmp/${nix_basename}" \
        || die "failed to install ${remote_nix_path} on ${vm_ip}"

    # Copy the siblings the main .nix references: .nix helpers it imports via
    # pkgs.callPackage (#286), and patch files (./fix.patch) it applies (#740) —
    # without them, evaluation on the guest fails with "path … does not exist".
    # Skips the already-copied main file. Failure is non-fatal.
    for _sib in ./*.nix ./*.patch ./*.diff; do
        [[ -f "${_sib}" ]] || continue
        local _sib_base
        _sib_base="$(basename "${_sib}")"
        [[ "${_sib_base}" == "${nix_basename}" ]] && continue
        local _sib_remote="/etc/nixos/${_sib_base}"
        scp -q -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${_sib}" "tappaas@${vm_ip}:/tmp/${_sib_base}" \
            || { warn "failed to scp sibling ${_sib} — continuing"; continue; }
        ssh -o BatchMode=yes "tappaas@${vm_ip}" "sudo install -m 0644 /tmp/${_sib_base} ${_sib_remote} && rm -f /tmp/${_sib_base}" \
            || warn "failed to install sibling ${_sib_remote} — continuing"
    done

    # Copy companion JSON (<source_vmname>.json) to the VM so modules using
    # builtins.readFile ./module.json can evaluate. For variants the installed
    # config (carrying variant-specific values) is normalized to flat format
    # and deployed under the source module's JSON name. Fixes #286.
    local _companion_local="./${_source_vmname}.json"
    local _companion_remote="/etc/nixos/${_source_vmname}.json"
    if [[ -f "${_companion_local}" ]]; then
        local _flat_tmp
        _flat_tmp=$(mktemp)
        local _installed_cfg="${CONFIG_DIR}/${vmname}.json"
        if [[ -f "${_installed_cfg}" ]] && declare -F normalize_module_config >/dev/null 2>&1; then
            normalize_module_config < "${_installed_cfg}" > "${_flat_tmp}" \
                || cp "${_companion_local}" "${_flat_tmp}"
        else
            cp "${_companion_local}" "${_flat_tmp}"
        fi
        # The public name the proxy publishes this module under, derived or not
        # (#715): what nextcloud.nix and logging.nix need and could not see.
        declare -F with_public_domain >/dev/null 2>&1 && with_public_domain "${vmname}" "${_flat_tmp}"
        # Where Caddy reaches it from over IPv6, for a module that trusts its proxy
        # by address (ADR-030 D9).
        declare -F with_proxy_source_v6 >/dev/null 2>&1 && with_proxy_source_v6 "${vmname}" "${_flat_tmp}"
        info "Copying JSON config to ${vm_ip}:${_companion_remote}"
        scp -q -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${_flat_tmp}" "tappaas@${vm_ip}:/tmp/${_source_vmname}.json" \
            || { rm -f "${_flat_tmp}"; die "failed to scp JSON config to ${vm_ip}"; }
        ssh -o BatchMode=yes "tappaas@${vm_ip}" "sudo install -m 0644 /tmp/${_source_vmname}.json ${_companion_remote} && rm -f /tmp/${_source_vmname}.json" \
            || { rm -f "${_flat_tmp}"; die "failed to install JSON config on ${vm_ip}"; }
        rm -f "${_flat_tmp}"
    fi

    # Build facts (#797): what the guest runs, for a module whose build steps along
    # it (identity: Authentik's release lines, nextcloud: its majors). The build
    # runs on the mothership (#774), where the guest's own files do not exist, so
    # the module's build-facts.sh runs ON the guest and its KEY=value lines — never
    # a secret — land in /etc/nixos/tappaas-build-facts.env: staged with the rest
    # of /etc/nixos on the mothership, read in place by a build on the guest. No
    # facts must not look like a fresh install, so a collector that fails stops here.
    if [[ -f ./build-facts.sh ]]; then
        local _facts
        _facts="$(ssh -o BatchMode=yes "tappaas@${vm_ip}" 'sudo -n bash -s' < ./build-facts.sh)" \
            || die "collecting the build facts on ${vmname} failed — its build would not know what the guest runs (#797)"
        printf '%s\n' "${_facts}" | ssh -o BatchMode=yes "tappaas@${vm_ip}" \
            "sudo -n tee /etc/nixos/tappaas-build-facts.env >/dev/null" \
            || die "failed to write the build facts on ${vm_ip}"
        info "Build facts on ${vmname}: $(paste -sd' ' <<<"${_facts}")"
    else
        # Relative on purpose: the caller runs from the module directory
        # (update-service.sh cds there). Said, so a run from elsewhere that
        # skips a module's collector is visible (#861).
        debug "  no build-facts.sh in $(pwd) — ${vmname} builds without facts"
    fi

    # An empty capture-timer fragment so the module's fixed import resolves on a
    # guest that captures nothing (#691). Never overwrites a real one:
    # backup:filesystem writes that, and it must survive this step.
    ssh -o BatchMode=yes "tappaas@${vm_ip}" \
        "test -f /etc/nixos/tappaas-backup.nix || printf '{ }\n' | sudo tee /etc/nixos/tappaas-backup.nix >/dev/null" \
        || warn "could not place the capture-timer placeholder on ${vm_ip}"

    # The baseline every module imports (#324), from this checkout — the same
    # file the template image is built from, so a VM stays on the baseline its
    # release ships rather than the one baked into its image. Always overwritten:
    # it is the platform's file, not the guest's. A module that imports it and
    # did not get it would fail the rebuild on a missing path, so say so here.
    local _baseline="${TAPPAAS_BASELINE_NIX:-/home/tappaas/TAPPaaS/src/foundation/templates/tappaas-common.nix}"
    if [[ -f "${_baseline}" ]]; then
        info "Copying the NixOS baseline to ${vm_ip}:/etc/nixos/tappaas-common.nix"
        scp -q -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${_baseline}" "tappaas@${vm_ip}:/tmp/tappaas-common.nix" \
            && ssh -o BatchMode=yes "tappaas@${vm_ip}" "sudo install -m 0644 /tmp/tappaas-common.nix /etc/nixos/tappaas-common.nix && rm -f /tmp/tappaas-common.nix" \
            || die "failed to install the NixOS baseline on ${vm_ip}"
    elif sed -E 's/#.*$//' "${nix_config}" | grep -q 'tappaas-common\.nix'; then
        die "${nix_config} imports the NixOS baseline, but ${_baseline} does not exist"
    fi

    # The site's own time and locale, written where the baseline imports it from
    # (#472). Before the rebuild, so this run applies it rather than the next.
    if declare -F apply_site_locale_nixos >/dev/null 2>&1; then
        local _zone
        _zone="$(jq -r '(.zone0 // (.config? // {} | to_entries[]?.value.zone0?)) // ""' "${CONFIG_DIR}/${vmname}.json" 2>/dev/null | head -1)"
        info "Writing /etc/nixos/tappaas-site.nix (site time + locale)"
        apply_site_locale_nixos "${vm_ip}" "${_zone}" \
            || warn "could not write the site fragment on ${vm_ip} — the VM keeps its current time and locale"
    fi

    # The journal client (#770): written while the module declares logging:logs
    # and logging is deployed, removed otherwise — the baseline imports it.
    if declare -F apply_log_shipping_nixos >/dev/null 2>&1; then
        if log_shipping_wanted "${vmname}"; then
            info "Writing /etc/nixos/tappaas-logging.nix (journal → Loki)"
        fi
        apply_log_shipping_nixos "${vm_ip}" "${vmname}" \
            || warn "could not write the log-shipping fragment on ${vm_ip} — its journal stays on the VM"
    fi

    # The prebuilt NixOS template ships without /etc/nixos/hardware-configuration.nix
    # — generate it on-demand so the module's `imports = [ /etc/nixos/hardware-configuration.nix ]`
    # resolves on the FIRST rebuild. Idempotent: bootstrap.sh follows the same
    # pattern for tappaas-cicd; we extend the convention to every module install.
    info "Ensuring /etc/nixos/hardware-configuration.nix exists on ${vm_ip}"
    ssh -o BatchMode=yes "tappaas@${vm_ip}" '
        test -f /etc/nixos/hardware-configuration.nix && exit 0
        sudo nixos-generate-config --show-hardware-config 2>/dev/null \
          | sudo tee /etc/nixos/hardware-configuration.nix >/dev/null
    ' || die "failed to generate /etc/nixos/hardware-configuration.nix on ${vm_ip}"

    # Reproducible nixpkgs pin: build every module VM against the EXACT nixpkgs
    # revision pinned for the NixOS template (templates/flake.lock), overriding
    # whatever channel the VM happens to carry in its imperative `nix-channel`.
    # This makes module rebuilds deterministic and version-controlled in git, and
    # keeps every TAPPaaS NixOS VM on the same release as the template (currently
    # 25.11) regardless of when the VM was provisioned. -I nixpkgs=<path> takes
    # precedence over NIX_PATH, so the VM's channel no longer determines the build.
    # The pin is fetched by its narHash on whichever host builds (ADR-033 D8).
    local flake_lock="/home/tappaas/TAPPaaS/src/foundation/templates/flake.lock"
    local nixpkgs_arg="" pinned_rev=""
    if [[ -f "${flake_lock}" ]]; then
        pinned_rev="$(jq -r '.nodes.nixpkgs.locked.rev // empty' "${flake_lock}" 2>/dev/null)"
    fi
    if [[ -n "${pinned_rev}" ]]; then
        info "Pinning nixpkgs to template rev ${pinned_rev:0:12} (reproducible — not the VM's channel)"
        # A guest last built from a NEWER revision moves backwards on this switch,
        # silently — and an application whose data ratchets forward then refuses to
        # start. Name the change before it happens (#680 owns the refresh cadence).
        local _running_rev
        _running_rev="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "tappaas@${vm_ip}" \
            "nixos-version --json 2>/dev/null" 2>/dev/null | jq -r '.nixpkgsRevision // empty' 2>/dev/null || true)"
        if [[ -n "${_running_rev}" && "${_running_rev}" != "${pinned_rev}" ]]; then
            warn "nixpkgs revision changes on ${vmname}: running ${_running_rev:0:12} → pinned ${pinned_rev:0:12}"
            warn "  If the running revision is the newer one this rebuild is a DOWNGRADE (#680); a service"
            warn "  whose data ratchets forward (Nextcloud) will refuse to start — pin its package in its .nix."
        fi
    else
        warn "Could not read pinned nixpkgs rev from ${flake_lock} — falling back to the VM's nix-channel"
    fi

    # Retry ONLY a lost connection (ssh 255) — a first activation can restart sshd
    # mid-run. Every other exit is nixos-rebuild's own verdict and deterministic, so
    # retrying it just repeats the failure under a misleading connectivity banner.
    local attempt rebuilt=0 rc staged=0 _move=""
    local _rebuild_cmd=""

    # A release move is STAGED, not switched (#728) — as the mothership does it
    # (#725, tappaas-self-rebuild.sh). Across a nixpkgs release `switch` applies
    # but cannot reload dbus-broker, and exits 4 (hrossen, 2026-09-24: Nextcloud,
    # 25.11 -> 26.05). The retry below happened to rescue that — attempt 2 found
    # nothing left to reload — but on another site all three attempts failed and
    # the guest rolled back. A boot has nothing to reload: `nixos-rebuild boot`
    # makes the new release the next generation, and the reboot below takes it.
    #
    # The system is built on the mothership (#774) unless that is impossible —
    # then on the guest, as before, with a warning that names why. Opt out for one
    # run with TAPPAAS_GUEST_BUILD=guest. The mothership itself is never built
    # this way: tappaas-self-rebuild.sh builds it.
    local _built="" _src="" _stage_cmd
    if [[ "${TAPPAAS_GUEST_BUILD:-cicd}" != "guest" && "${vmname}" != "$(hostname)" ]]; then
        if ! _src="$(pinned_nixpkgs_source "${flake_lock}")" || [[ -z "${_src}" ]]; then
            warn "Building ${vmname} on the guest: the pinned nixpkgs could not be resolved from ${flake_lock} (#774)"
        elif _built="$(guest_build_on_cicd "${vmname}" "${vm_ip}" "${nix_basename}" "${_src}")"; then
            info "  ${GN}✓${CL} built on the mothership and copied: ${_built##*/}"
            _rebuild_cmd="$(guest_activate_cmd "${_built}" switch)"
        else
            _built=""
            guest_build_promote "${vmname}" 0
            warn "Building ${vmname} on the guest: building it on the mothership failed (#774)"
        fi
    fi

    if [[ -n "${_built}" ]]; then
        _move="$(release_move_to "${vm_ip}" "${_built}")" || _move=""
        _stage_cmd="$(guest_activate_cmd "${_built}" boot)"
    else
        # The guest builds: it fetches the pin itself, checked by narHash.
        if [[ -n "${pinned_rev}" ]]; then
            local _gsrc
            _gsrc="$(guest_pinned_nixpkgs "${vm_ip}" "${flake_lock}")" \
                || die "could not fetch the pinned nixpkgs on ${vmname} by the narHash in ${flake_lock} (ADR-033 D8) — not building against an unchecked one"
            nixpkgs_arg="-I nixpkgs=${_gsrc}"
        fi
        _rebuild_cmd="sudo nixos-rebuild switch ${nixpkgs_arg} -I nixos-config=${remote_nix_path}"
        info "Building the target system on ${vm_ip}..."
        _move="$(release_move_of "${vm_ip}" "${nixpkgs_arg}" "${remote_nix_path}")" || _move=""
        _stage_cmd="sudo nixos-rebuild boot ${nixpkgs_arg} -I nixos-config=${remote_nix_path}"
    fi
    if [[ -n "${_move}" ]]; then
        info "Release move on ${vmname}: ${_move% *} -> ${_move#* } — staging it for the next boot (#728)"
        ( run_quiet "staging the release move on ${vm_ip}" \
            timeout -k 30 "${REBUILD_MAX_SECONDS}" \
            ssh "${SSH_REBUILD_OPTS[@]}" "tappaas@${vm_ip}" "${_stage_cmd}" ) \
            || { [[ -n "${_built}" ]] && guest_build_promote "${vmname}" 0
                 die "staging the release move on ${vmname} failed — it is still on ${_move% *}"; }
        rebuilt=1; staged=1
    fi

    # What is activated right now, so a connection that dies mid-switch can be
    # judged rather than guessed (#720). A `switch` that reached activation moves
    # /run/current-system; one that did not, does not. Comparing the running
    # nixpkgs revision instead would lie whenever the guest was already on the
    # pinned revision and only its config changed.
    local _sys_before
    _sys_before="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "tappaas@${vm_ip}" \
        "readlink -f /run/current-system" 2>/dev/null || true)"

    (( staged )) || for attempt in 1 2 3; do
        rc=0
        if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
            timeout -k 30 "${REBUILD_MAX_SECONDS}" \
                ssh "${SSH_REBUILD_OPTS[@]}" "tappaas@${vm_ip}" "${_rebuild_cmd}" || rc=$?
        else
            # run_quiet_rc, not run_quiet: the latter die()s with exit 1 and would
            # erase the real exit code this classification depends on.
            run_quiet_rc "nixos-rebuild on ${vm_ip} (attempt ${attempt}/3)" \
                timeout -k 30 "${REBUILD_MAX_SECONDS}" \
                ssh "${SSH_REBUILD_OPTS[@]}" "tappaas@${vm_ip}" "${_rebuild_cmd}" || rc=$?
        fi
        if [[ "$rc" -eq 0 ]]; then
            rebuilt=1; break
        fi
        # 124/137: OUR ceiling fired (timeout -k). That is a connection fault of
        # our own making, not nixos-rebuild's verdict — without this it fell into
        # the branch below and died claiming the configuration was rejected.
        if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
            warn "nixos-rebuild on ${vm_ip} exceeded ${REBUILD_MAX_SECONDS}s and was killed — treating it as a lost connection"
            rc=255
        fi
        if [[ "$rc" -eq 255 && -n "${_sys_before}" ]]; then
            # The remote may well have finished: the 93-minute hang in #720 ended
            # with "Done. The new configuration is ..." already in the captured
            # output. Ask the guest what is activated before calling this a failure.
            local _sys_now
            _sys_now="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "tappaas@${vm_ip}" \
                "readlink -f /run/current-system" 2>/dev/null || true)"
            if [[ -n "${_sys_now}" && "${_sys_now}" != "${_sys_before}" ]]; then
                info "  ${GN}✓${CL} the connection dropped, but ${vmname} activated the new system anyway"
                info "      ${_sys_before##*-nixos-system-} -> ${_sys_now##*-nixos-system-}"
                rebuilt=1; break
            fi
        fi
        if [[ "$rc" -ne 255 ]]; then
            error "nixos-rebuild on ${vm_ip} failed with exit ${rc} — $(nixos_rebuild_exit_meaning "${rc}")."
            error "Not retrying: this is the configuration's verdict, not a connection fault."
            report_failed_units "${vm_ip}"
            [[ -n "${_built}" ]] && guest_build_promote "${vmname}" 0
            die "nixos-rebuild failed (exit ${rc}) on ${vmname}; fix the configuration and re-run"
        fi
        [[ "$attempt" -lt 3 ]] || break
        warn "nixos-rebuild attempt ${attempt}: ssh connection lost (exit 255) — re-syncing host key and waiting for sshd..."
        sleep 15  # let any in-flight reboot settle
        update_ssh_known_hosts "${vm_ip}"
        # Give sshd up to 90 s to come back before attempting the next rebuild.
        wait_for_ssh "${vm_ip}" 90 || warn "ssh still unreachable after 90 s — trying nixos-rebuild anyway"
    done
    [[ -n "${_built}" ]] && guest_build_promote "${vmname}" "${rebuilt}"
    [[ "$rebuilt" == "1" ]] || die "nixos-rebuild failed after 3 attempts (ssh connection lost each time)"

    # nixos-rebuild switch already activated the new generation; the reboot
    # applies kernel/bootloader changes. Gated by tappaas.automaticReboot
    # (issue #275) — covers the identity VM and any other NixOS guest — or by
    # the operator authorizing disruption for this run (ADR-020 D8,
    # --allow-disruption → TAPPAAS_ALLOW_DISRUPTION=1). A reboot not taken is
    # reported as a DEFERRED: line, which the sweep collects (#730).
    local _pending="the new NixOS generation"
    (( staged )) && _pending="the staged release move ${_move% *} -> ${_move#* }"
    if [[ "${vmname}" == "$(hostname)" ]]; then
        # SELF-UPDATE GUARD (incident 2026-06-09): never reboot/stop the VM that
        # is running THIS updater — doing so kills the orchestrator mid-run, so
        # the follow-up start never happens and the controller is stranded down
        # (and an in-flight config write like zones.json can be lost). The new
        # NixOS generation is already active; the operator reboots the controller
        # under supervision (the cicd is on local storage and can't live-migrate).
        warn "Skipping auto-reboot: ${vmname} is THIS controller VM — rebooting it from its own"
        if (( staged )); then
            warn "  update would kill the updater (incident 2026-06-09). The release move is STAGED, not active."
        else
            warn "  update would kill the updater (incident 2026-06-09). New generation is active."
        fi
        warn "  Reboot under supervision when ready: ssh root@${node}.${MGMT}.internal 'qm reboot ${vmid}'"
        warn "DEFERRED: ${vmname} reboot to take ${_pending} is pending — it runs this update, reboot it under supervision"
    elif [[ "${TAPPAAS_ALLOW_DISRUPTION:-0}" == "1" ]] || automatic_reboot_enabled; then
        info "Rebooting VM to apply configuration..."
        # The rebuild has already succeeded, so a lock here is a postponed
        # reboot, not a failed update — it used to fail the whole re-apply and
        # report a correctly-updated module as FAILED (#686).
        local _rrc=0
        reboot_guest "${vmname}" "${vmid}" "${node}" "${vm_ip}" || _rrc=$?
        if (( _rrc == 3 )); then
            if (( staged )); then
                warn "Could not reboot ${vmname}: the VM is locked (${REBOOT_LOCK_HOLDER}). The release move is staged, not active;"
            else
                warn "Could not reboot ${vmname}: the VM is locked (${REBOOT_LOCK_HOLDER}). The new generation IS active;"
            fi
            warn "  the reboot is still pending — the next update takes it, or: health-manager reboot ${vmname}"
            warn "DEFERRED: ${vmname} reboot to take ${_pending} is pending — the VM was locked (${REBOOT_LOCK_HOLDER})"
            return 0
        fi
    else
        warn "automaticReboot=false — skipping reboot of VM ${vmid} (${vmname})."
        if (( staged )); then
            warn "  The release move (${_move% *} -> ${_move#* }) is STAGED, not active: ${vmname} keeps running"
            warn "  ${_move% *} until it reboots. Nothing was switched, so nothing is half-applied."
        else
            warn "  The new NixOS generation is active, but a reboot is needed to apply kernel/bootloader changes."
        fi
        warn "  Reboot it when convenient: health-manager reboot ${vmname}"
        warn "  or authorize it for one run: module-manager module update ${vmname} --allow-disruption"
        warn "DEFERRED: ${vmname} reboot to take ${_pending} needs a disruptive change that is not authorized"
        # sshd and networking restart during nixos switch activation even without a reboot.
        # Wait for SSH to stabilise before returning so subsequent service updaters can reach the VM.
        update_ssh_known_hosts "${vm_ip}"
        wait_for_ssh "${vm_ip}" 90 || warn "sshd unreachable after 90 s — subsequent service updaters may fail"
        wait_for_guest_settled "${vm_ip}" 90 || true
    fi
}

# Stop cloud-init regenerating the guest's SSH host keys (root cause of the
# "Host key verification failed" churn). Proxmox rewrites the NoCloud drive
# whenever a module update touches the VM's cloud-init config, which changes
# the instance-id; on the next boot cloud-init sees a NEW instance and re-runs
# its per-instance modules, and cc_ssh regenerates /etc/ssh/ssh_host_*.
#
# The NixOS template has been immune since #226 (ssh_deletekeys = false in
# tappaas-common.nix, set there to stop a first-boot race with sshd-keygen).
# Debian guests never got the equivalent. This is it, as a drop-in so it
# survives apt upgrades of cloud-init.
#
# Safe for a template: the image carries no host keys, so first boot still
# generates a unique set per clone — this only stops the RE-generation.
ensure_persistent_host_keys() {
    local vm_ip="$1"
    local dropin=/etc/cloud/cloud.cfg.d/99-tappaas-ssh-hostkeys.cfg

    tappaas_ssh_guest -o BatchMode=yes -o ConnectTimeout=10 "tappaas@${vm_ip}" \
        "test -f ${dropin}" 2>/dev/null && return 0

    info "Pinning SSH host keys against cloud-init re-instantiation..."
    if tappaas_ssh_guest -o BatchMode=yes -o ConnectTimeout=10 "tappaas@${vm_ip}" \
        "printf '%s\n' '# TAPPaaS: keep host keys across cloud-init re-instantiation.' \
                       'ssh_deletekeys: false' \
         | sudo tee ${dropin} >/dev/null"; then
        info "  ${GN}✓${CL} ${dropin} installed"
    else
        warn "  could not install ${dropin} — host keys may change on the next reboot"
    fi
}

# Update Debian/Ubuntu VM
update_debian() {
    local vm_ip="$1"
    local vmname="${2:-}"    # for the site locale (#472): which config names this guest

    # BEFORE anything that ssh's: wait_for_cloud_init talks to the guest, so a
    # host key that changed since we last spoke would fail there first. Heal it,
    # then stop it recurring. Both are cheap and idempotent.
    update_ssh_known_hosts "${vm_ip}"

    wait_for_cloud_init "${vm_ip}"

    ensure_persistent_host_keys "${vm_ip}"

    info "Updating package lists..."
    if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
        tappaas_ssh_guest "tappaas@${vm_ip}" "sudo apt-get update" || die "apt-get update failed"
    else
        run_quiet "apt-get update" tappaas_ssh_guest "tappaas@${vm_ip}" "sudo apt-get update"
    fi

    info "Upgrading packages..."
    if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
        tappaas_ssh_guest "tappaas@${vm_ip}" "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y" || die "apt-get upgrade failed"
    else
        run_quiet "apt-get upgrade" tappaas_ssh_guest "tappaas@${vm_ip}" "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"
    fi

    # The site's time and locale, converged rather than declared (#472). A Debian
    # guest has no baseline to import, so the sweep is what keeps it true.
    if declare -F apply_site_locale_debian >/dev/null 2>&1; then
        local _zone
        _zone="$(jq -r '(.zone0 // (.config? // {} | to_entries[]?.value.zone0?)) // ""' "${CONFIG_DIR}/${vmname}.json" 2>/dev/null | head -1)"
        apply_site_locale_debian "${vm_ip}" "${_zone}" || true
    fi

    info "Installing/updating QEMU guest agent..."
    if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
        tappaas_ssh_guest "tappaas@${vm_ip}" "sudo apt-get install -y qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent" || die "qemu-guest-agent install failed"
    else
        run_quiet "qemu-guest-agent install" tappaas_ssh_guest "tappaas@${vm_ip}" "sudo apt-get install -y qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent"
    fi
}

# Fix DHCP hostname registration
fix_dhcp_hostname() {
    local vmname="$1"
    local vm_ip="$2"

    info "Fixing DHCP hostname registration..."

    # Method 1: Try NetworkManager (nmcli)
    local eth_connection
    local eth_device

    eth_connection=$(ssh "tappaas@${vm_ip}" "nmcli -t -f NAME,TYPE connection show 2>/dev/null" | grep ethernet | cut -d: -f1 | head -1) || true
    eth_device=$(ssh "tappaas@${vm_ip}" "nmcli -t -f DEVICE,TYPE device status 2>/dev/null" | grep ethernet | cut -d: -f1 | head -1) || true

    if [[ -n "${eth_connection}" ]] && [[ -n "${eth_device}" ]]; then
        debug "  Using NetworkManager for DHCP hostname fix"
        debug "  Ethernet connection: ${eth_connection}"
        debug "  Ethernet device: ${eth_device}"

        # Resolve nmcli's absolute path on the target (NixOS:
        # /run/current-system/sw/bin, Debian: /usr/bin).
        local nmcli_path
        nmcli_path=$(ssh "tappaas@${vm_ip}" "command -v nmcli" 2>/dev/null) || nmcli_path=nmcli

        # 1. Set the advertised hostname to vmname (not $(hostname): NM may have a
        #    stale transient hostname from a prior DHCP cycle that masks the static
        #    NixOS hostname — using vmname directly is always authoritative).
        ssh "tappaas@${vm_ip}" "sudo ${nmcli_path} connection modify '${eth_connection}' ipv4.dhcp-hostname '${vmname}'" || true

        # 2. Soft DHCP re-acquire via 'nmcli device reapply'. Unlike disconnect/
        #    connect, reapply does NOT drop the link — the SSH session survives,
        #    DNS stays live, and OPNsense Unbound updates within a few seconds.
        #    (The older disconnect/connect approach caused a DNS blackout of 30-90 s
        #    that blocked subsequent identity:identity service updates — issue #376.)
        # stdout too, not just stderr: nmcli prints "Connection successfully
        # reapplied to device 'ensN'." on success, which surfaced untagged in the
        # middle of a converge. The debug line below is this step's report.
        if ssh "tappaas@${vm_ip}" "sudo ${nmcli_path} device reapply ${eth_device}" >/dev/null 2>&1; then
            debug "  DHCP hostname re-applied to: ${vmname} (reapply succeeded)"
        else
            warn "  nmcli device reapply failed — DHCP hostname may not be registered until next lease renewal"
        fi
        return 0
    fi

    # Method 2: Try systemd-networkd (netplan/networkd)
    local networkd_active
    networkd_active=$(ssh "tappaas@${vm_ip}" "systemctl is-active systemd-networkd 2>/dev/null") || true

    if [[ "${networkd_active}" == "active" ]]; then
        debug "  Using systemd-networkd for DHCP hostname fix"
        # Find the .network file for the primary ethernet interface
        local network_file
        network_file=$(ssh "tappaas@${vm_ip}" "ls /run/systemd/network/*.network /etc/systemd/network/*.network 2>/dev/null | head -1") || true

        if [[ -n "${network_file}" ]]; then
            local network_basename
            network_basename=$(basename "${network_file}")
            local dropin_dir="/etc/systemd/network/${network_basename}.d"

            debug "  Creating drop-in for ${network_basename}"
            ssh "tappaas@${vm_ip}" "sudo mkdir -p '${dropin_dir}' && printf '[DHCPv4]\nSendHostname=yes\nHostname=${vmname}\n' | sudo tee '${dropin_dir}/hostname.conf' >/dev/null" || true
            ssh "tappaas@${vm_ip}" "sudo systemctl restart systemd-networkd" || true
            debug "  DHCP hostname updated to: ${vmname}"
            return 0
        fi
    fi

    warn "Could not find ethernet connection/device for DHCP fix"
}

# Main function
main() {
    # Check for help flag
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    # Validate arguments
    if [[ $# -lt 3 ]]; then
        error "Missing required arguments"
        usage
        exit 1
    fi

    local vmname="$1"
    local vmid="$2"
    local node="$3"

    # Callers pass the CONFIGURED node. A guest whose node change is deferred
    # (or failed) still runs on the old one, and asking the new one for its IP
    # waits five minutes for nothing (#825). Go where the guest is.
    local holder
    holder="$(vm_node_holding "${vmid}")"
    if [[ -n "${holder}" && "${holder}" != "${node}" ]]; then
        warn "VM ${vmid} runs on ${holder}, not on its configured node ${node} — updating it there"
        node="${holder}"
    fi

    info "=== TAPPaaS OS Update ==="
    info "VM: ${vmname} (VMID: ${vmid}) on ${node}"

    # Wait for VM to get IP address
    local vm_ip
    vm_ip=$(wait_for_vm_ip "${node}" "${vmid}" 30) || die "Could not get VM IP address after 5 minutes"
    info "VM IP address: ${vm_ip}"

    # Update SSH known_hosts
    update_ssh_known_hosts "${vm_ip}"

    # Wait for SSH to become available (cloud-init may still be setting up keys)
    wait_for_ssh "${vm_ip}" 120 || die "SSH not available on ${vm_ip}"

    # Detect OS type
    debug "Detecting OS type..."
    local os_type
    os_type=$(detect_os_type "${vm_ip}")
    info "Detected OS: ${BL}${os_type}${CL}"

    # Perform OS-specific update
    announce "OS update (${os_type}) on ${vmname}"
    case "${os_type}" in
        nixos)
            update_nixos "${vmname}" "${vmid}" "${node}" "${vm_ip}"
            ;;
        debian)
            update_debian "${vm_ip}" "${vmname}"
            ;;
        *)
            die "Unknown or unsupported OS type: ${os_type}"
            ;;
    esac

    # Wait for VM to come back up after updates (especially for NixOS reboot)
    if [[ "${os_type}" == "nixos" ]]; then
        info "Waiting for VM to come back up..."
        vm_ip=$(wait_for_vm_ip "${node}" "${vmid}" 12) || die "Could not get VM IP address after reboot"
        info "VM IP address after reboot: ${vm_ip}"
        update_ssh_known_hosts "${vm_ip}"
    fi

    # Fix DHCP hostname registration
    fix_dhcp_hostname "${vmname}" "${vm_ip}"

    # fix_dhcp_hostname triggers a DHCP re-acquire (nmcli device reapply). Wait until
    # the module's FQDN resolves in DNS (DHCP re-registration + Unbound update)
    # before returning — subsequent service updaters (e.g. identity:identity) SSH
    # by hostname and fail if DNS is still in the blackout window (issue #376).
    if [[ "${os_type}" == "nixos" ]]; then
        local _zone0
        _zone0=$(jq -r '.zone0 // empty' "${CONFIG_DIR}/${vmname}.json" 2>/dev/null || true)
        if [[ -n "${_zone0}" ]]; then
            local _fqdn="${vmname}.${_zone0}.internal"
            info "Waiting for DNS ${_fqdn} to register after DHCP reapply..."
            local _dns_ok=0 _dns_i
            for _dns_i in {1..30}; do
                if getent hosts "${_fqdn}" &>/dev/null; then
                    info "  DNS ${_fqdn} confirmed (t=$(( (_dns_i - 1) * 3 )) s)"
                    _dns_ok=1; break
                fi
                sleep 3
            done
            [[ "${_dns_ok}" -eq 1 ]] || warn "  DNS ${_fqdn} did not resolve after 90 s — subsequent service updaters may fail"
        fi
    fi

    echo ""
    info "${GN}=== OS update completed successfully ===${CL}"
    info "VM: ${vmname} (${vm_ip})"
}

# Skip execution when sourced (e.g. to unit-test resolve_nixos_config in
# isolation) -- only run when invoked directly, same idiom as the rest of the
# foundation scripts.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
