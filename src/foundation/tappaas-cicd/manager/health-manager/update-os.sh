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

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly MGMT="mgmt"

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh
# The site's time and locale, rendered per OS family (#472, #87). Optional: a
# mothership that has not deployed it yet updates as before, without the facts.
# shellcheck source=site-locale.sh
[[ -f /home/tappaas/bin/site-locale.sh ]] && . /home/tappaas/bin/site-locale.sh

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
release_move_of() {
    local ip="$1" nixpkgs_arg="$2" cfg="$3" cur top new
    cur="$(ssh -o BatchMode=yes "tappaas@${ip}" \
        "grep -oE '^[0-9]+\\.[0-9]+' /run/current-system/nixos-version" 2>/dev/null)" || return 1
    top="$(ssh -o BatchMode=yes "tappaas@${ip}" \
        "sudo nix-build '<nixpkgs/nixos>' -A system ${nixpkgs_arg} -I nixos-config=${cfg} --no-out-link" \
        2>/dev/null | tail -n 1)" || return 1
    [[ "${top}" == /nix/store/* ]] || return 1
    new="$(ssh -o BatchMode=yes "tappaas@${ip}" "grep -oE '^[0-9]+\\.[0-9]+' ${top}/nixos-version" 2>/dev/null)" || return 1
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
    info "Running nixos-rebuild ON the target VM (not --target-host)..."
    # Build LOCALLY on the target VM so the module's
    # `imports = [ /etc/nixos/hardware-configuration.nix ]` resolves to the
    # VM's OWN hw-config (right disk UUIDs / boot device), not the cicd's.
    # The previous --target-host path built locally on cicd → wrong hw-config
    # → activation broke sshd/qemu-agent on the target every time. See the
    # automated-install-state memory note ("Latent issue NOT yet fixed").
    #
    # Mechanics: scp the .nix into /etc/nixos/<vmname>.nix on the VM, then
    # ssh in and run `nixos-rebuild switch` locally. nixos-rebuild on the VM
    # uses its own nixpkgs channel + can pull from cache.nixos.org via the
    # firewall — no closure-copying over the slow ssh path.
    local nix_basename remote_nix_path
    nix_basename="$(basename "${nix_config}")"
    remote_nix_path="/etc/nixos/${nix_basename}"

    info "Copying ${nix_config} to ${vm_ip}:${remote_nix_path}"
    scp -q -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${nix_config}" "tappaas@${vm_ip}:/tmp/${nix_basename}" \
        || die "failed to scp ${nix_config} to ${vm_ip}"
    ssh -o BatchMode=yes "tappaas@${vm_ip}" "sudo install -m 0644 /tmp/${nix_basename} ${remote_nix_path} && rm -f /tmp/${nix_basename}" \
        || die "failed to install ${remote_nix_path} on ${vm_ip}"

    # Copy sibling .nix helpers the main .nix imports via pkgs.callPackage.
    # Skips the already-copied main file. Failure is non-fatal. Fixes #286.
    for _sib in ./*.nix; do
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
        info "Copying JSON config to ${vm_ip}:${_companion_remote}"
        scp -q -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${_flat_tmp}" "tappaas@${vm_ip}:/tmp/${_source_vmname}.json" \
            || { rm -f "${_flat_tmp}"; die "failed to scp JSON config to ${vm_ip}"; }
        ssh -o BatchMode=yes "tappaas@${vm_ip}" "sudo install -m 0644 /tmp/${_source_vmname}.json ${_companion_remote} && rm -f /tmp/${_source_vmname}.json" \
            || { rm -f "${_flat_tmp}"; die "failed to install JSON config on ${vm_ip}"; }
        rm -f "${_flat_tmp}"
    fi

    # An empty capture-timer fragment so the module's fixed import resolves on a
    # guest that captures nothing (#691). Never overwrites a real one:
    # backup:filesystem writes that, and it must survive this step.
    ssh -o BatchMode=yes "tappaas@${vm_ip}" \
        "test -f /etc/nixos/tappaas-backup.nix || printf '{ }\n' | sudo tee /etc/nixos/tappaas-backup.nix >/dev/null" \
        || warn "could not place the capture-timer placeholder on ${vm_ip}"

    # The site's own time and locale, written where the module's .nix imports it
    # from (#472). Before the rebuild, so this run applies it rather than the next.
    # The baseline itself (tappaas-common.nix) is NOT shipped yet: every module
    # still inlines its own copy, so importing it conflicts option by option —
    # that de-duplication is #324.
    if declare -F apply_site_locale_nixos >/dev/null 2>&1; then
        local _zone
        _zone="$(jq -r '(.zone0 // (.config? // {} | to_entries[]?.value.zone0?)) // ""' "${CONFIG_DIR}/${vmname}.json" 2>/dev/null | head -1)"
        info "Writing /etc/nixos/tappaas-site.nix (site time + locale)"
        apply_site_locale_nixos "${vm_ip}" "${_zone}" \
            || warn "could not write the site fragment on ${vm_ip} — the VM keeps its current time and locale"
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
    # 25.11) regardless of when the VM was provisioned. -I nixpkgs=<tarball> takes
    # precedence over NIX_PATH, so the VM's channel no longer determines the build.
    local flake_lock="/home/tappaas/TAPPaaS/src/foundation/templates/flake.lock"
    local nixpkgs_arg="" pinned_rev=""
    if [[ -f "${flake_lock}" ]]; then
        pinned_rev="$(jq -r '.nodes.nixpkgs.locked.rev // empty' "${flake_lock}" 2>/dev/null)"
    fi
    if [[ -n "${pinned_rev}" ]]; then
        nixpkgs_arg="-I nixpkgs=https://github.com/NixOS/nixpkgs/archive/${pinned_rev}.tar.gz"
        info "Pinning nixpkgs to template rev ${pinned_rev:0:12} (reproducible — not the VM's channel)"
    else
        warn "Could not read pinned nixpkgs rev from ${flake_lock} — falling back to the VM's nix-channel"
    fi

    # Retry: even with local builds, a freshly-cloned VM can hiccup on its
    # first activation (services restart while sshd reloads, cloud-init
    # finishing, growPartition). The build itself is idempotent (resumable
    # via the nix store), so re-trying after a settle window recovers.
    local attempt rebuilt=0 rc staged=0 _move=""

    # A release move is STAGED, not switched (#728) — as the mothership does it
    # (#725, tappaas-self-rebuild.sh). Across a nixpkgs release `switch` applies
    # but cannot reload dbus-broker, and exits 4 (hrossen, 2026-09-24: Nextcloud,
    # 25.11 -> 26.05). The retry below happened to rescue that — attempt 2 found
    # nothing left to reload — but on another site all three attempts failed and
    # the guest rolled back. A boot has nothing to reload: `nixos-rebuild boot`
    # makes the new release the next generation, and the reboot below takes it.
    info "Building the target system on ${vm_ip}..."
    if _move="$(release_move_of "${vm_ip}" "${nixpkgs_arg}" "${remote_nix_path}")"; then
        info "Release move on ${vmname}: ${_move% *} -> ${_move#* } — staging it for the next boot (#728)"
        ( run_quiet "nixos-rebuild boot on ${vm_ip}" \
            ssh -o BatchMode=yes "tappaas@${vm_ip}" "sudo nixos-rebuild boot ${nixpkgs_arg} -I nixos-config=${remote_nix_path}" ) \
            || die "staging the release move on ${vmname} failed — it is still on ${_move% *}"
        rebuilt=1; staged=1
    fi

    (( staged )) || for attempt in 1 2 3; do
        rc=0
        # Wrap in a subshell so run_quiet's die() (exit 1) only kills the
        # subshell — set -e in the parent would otherwise terminate before we
        # reach the retry. Capture rc with || so set -e doesn't fire here.
        if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
            ( ssh -o BatchMode=yes "tappaas@${vm_ip}" "sudo nixos-rebuild switch ${nixpkgs_arg} -I nixos-config=${remote_nix_path}" ) || rc=$?
        else
            ( run_quiet "nixos-rebuild on ${vm_ip} (attempt ${attempt}/3)" \
                ssh -o BatchMode=yes "tappaas@${vm_ip}" "sudo nixos-rebuild switch ${nixpkgs_arg} -I nixos-config=${remote_nix_path}" ) || rc=$?
        fi
        if [[ "$rc" -eq 0 ]]; then
            rebuilt=1; break
        fi
        [[ "$attempt" -lt 3 ]] || break
        warn "nixos-rebuild attempt ${attempt} failed (exit ${rc}) — re-syncing host key and waiting for sshd..."
        sleep 15  # let any in-flight reboot settle
        update_ssh_known_hosts "${vm_ip}"
        # Give sshd up to 90 s to come back before attempting the next rebuild.
        wait_for_ssh "${vm_ip}" 90 || warn "ssh still unreachable after 90 s — trying nixos-rebuild anyway"
    done
    [[ "$rebuilt" == "1" ]] || die "nixos-rebuild failed after 3 attempts"

    # nixos-rebuild switch already activated the new generation; the reboot
    # applies kernel/bootloader changes. Gated by tappaas.automaticReboot
    # (issue #275) — covers the identity VM and any other NixOS guest. When
    # false the operator reboots manually under supervision.
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
    elif automatic_reboot_enabled; then
        info "Rebooting VM to apply configuration..."
        # A backup holding the guest refuses the reboot (#686). The rebuild has
        # already succeeded and the new generation is active, so a lock here is
        # a postponed reboot, not a failed update — it used to fail the whole
        # re-apply and report a correctly-updated module as FAILED.
        if declare -F wait_for_vm_unlock >/dev/null 2>&1; then
            wait_for_vm_unlock "${vmid}" "${node}" "${TAPPAAS_LOCK_WAIT:-600}" || true
        fi
        if ! ssh "root@${node}.${MGMT}.internal" "qm reboot ${vmid}"; then
            local _holder=""
            declare -F vm_lock_holder >/dev/null 2>&1 && _holder="$(vm_lock_holder "${vmid}" "${node}")"
            if [[ -n "${_holder}" ]]; then
                if (( staged )); then
                    warn "Could not reboot ${vmname}: the VM is locked (${_holder}). The release move is staged, not active;"
                else
                    warn "Could not reboot ${vmname}: the VM is locked (${_holder}). The new generation IS active;"
                fi
                warn "  the reboot is still pending — the next update takes it, or: ssh root@${node}.${MGMT}.internal 'qm reboot ${vmid}'"
                return 0
            fi
            die "could not reboot ${vmname} (VM ${vmid}) after the rebuild"
        fi

        # Wait for sshd to come back (replaces fixed sleep 60 — issue #376).
        update_ssh_known_hosts "${vm_ip}"
        wait_for_ssh "${vm_ip}" 120 || warn "sshd unreachable after 120 s — subsequent service updaters may fail"
        # sshd answering is NOT the module being able to serve (#468): it comes
        # up seconds after boot while the module's own service may need far
        # longer, and the post-update tests run straight after this returns.
        wait_for_module_ready "${vmname}" "${vm_ip}" 180 \
            || warn "  post-update tests may run against a still-starting '${vmname}'"
    else
        warn "automaticReboot=false — skipping reboot of VM ${vmid} (${vmname})."
        if (( staged )); then
            warn "  The release move (${_move% *} -> ${_move#* }) is STAGED, not active: ${vmname} keeps running"
            warn "  ${_move% *} until it reboots. Nothing was switched, so nothing is half-applied."
        else
            warn "  The new NixOS generation is active, but a reboot is needed to apply kernel/bootloader changes."
        fi
        warn "  Reboot manually under supervision: ssh root@${node}.${MGMT}.internal 'qm reboot ${vmid}'"
        # sshd and networking restart during nixos switch activation even without a reboot.
        # Wait for SSH to stabilise before returning so subsequent service updaters can reach the VM.
        update_ssh_known_hosts "${vm_ip}"
        wait_for_ssh "${vm_ip}" 90 || warn "sshd unreachable after 90 s — subsequent service updaters may fail"
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
