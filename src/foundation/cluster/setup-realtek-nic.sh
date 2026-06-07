#!/usr/bin/env bash
#
# TAPPaaS Realtek RTL8127 10GbE NIC fix (issue #308 — MS-S1 MAX hardware quirk)
#
# Runs on a Proxmox node. Idempotent and HARDWARE-GATED: it does nothing unless
# the node actually has a Realtek RTL8127 controller, so it is safe to run on
# every node of a mixed cluster (e.g. Intel-igc nodes are skipped).
#
# Why: the Minisforum MS-S1 MAX's two 10GbE ports are Realtek RTL8127
# [10ec:8127]. The in-tree `r8169` driver fails to re-initialise them across a
# warm/soft reboot — the NIC drops off the PCIe bus and only a full power cycle
# brings it back. The fix (confirmed on the same chipset) is to install Realtek's
# dedicated `r8127` DKMS driver and blacklist `r8169` so the correct driver
# binds; after that, warm reboots keep the NICs.
#
# Safety: r8169 is blacklisted ONLY after the r8127 module is confirmed to build
# and load on the running kernel, so a failed/unbuildable DKMS never leaves the
# node with no NIC driver.
#
# Two steps this script CANNOT do from the OS (it detects and instructs):
#   1. Disable Secure Boot in the BIOS — an unsigned DKMS module will not load
#      while Secure Boot is enabled.
#   2. One power cycle — the node is currently running r8169; only a full power
#      cycle (not a warm reboot) switches cleanly to r8127 the first time.
#
# The driver package is vendored at assets/<deb> (verified by SHA256); if absent
# the same release is downloaded from the pinned URL.
#
# Usage: setup-realtek-nic.sh
#

set -euo pipefail

# ── Pinned driver (keep in sync with assets/README.md) ───────────────
readonly R8127_DEB="r8127-dkms_11.015.00-1_all.deb"
readonly R8127_SHA256="b946bf2f72fd82f95640ed82397b17475be008ec145def3565e4a1996777ccff"
readonly R8127_URL="https://github.com/minisforum-repo/r8127-dkms/releases/download/11.015.00-1/${R8127_DEB}"
readonly PCI_ID="10ec:8127"
readonly BLACKLIST_FILE="/etc/modprobe.d/tappaas-r8127.conf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ── Self-contained logging (runs standalone on a node) ───────────────
info() { echo "[realtek-nic] $*"; }
warn() { echo "[realtek-nic][WARN] $*" >&2; }
err()  { echo "[realtek-nic][ERROR] $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "must run as root"
    exit 1
fi

# ── 1. Hardware gate ─────────────────────────────────────────────────
if ! lspci -d "${PCI_ID}" 2>/dev/null | grep -q .; then
    info "No Realtek RTL8127 (${PCI_ID}) on $(hostname -s) — nothing to do."
    exit 0
fi
info "Detected Realtek RTL8127 (${PCI_ID}) on $(hostname -s)."

# Returns 0 if every RTL8127 device is currently driven by r8127.
all_devices_on_r8127() {
    local drivers
    drivers=$(lspci -d "${PCI_ID}" -k 2>/dev/null | awk -F': ' '/Kernel driver in use/{print $2}')
    [[ -n "$drivers" ]] && ! echo "$drivers" | grep -qv '^r8127$'
}

blacklist_present() { [[ -f "${BLACKLIST_FILE}" ]] && grep -q '^[[:space:]]*blacklist[[:space:]]\+r8169' "${BLACKLIST_FILE}"; }

# ── 2. Already fully active? ─────────────────────────────────────────
if all_devices_on_r8127; then
    if blacklist_present; then
        info "Already fixed: RTL8127 on r8127 and r8169 blacklisted. Nothing to do."
        exit 0
    fi
    info "RTL8127 already on r8127 but r8169 not blacklisted yet — asserting blacklist."
fi

# ── 3. Install build prerequisites ───────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
KREL="$(uname -r)"

ensure_headers() {
    if [[ -d "/lib/modules/${KREL}/build" ]]; then
        return 0
    fi
    info "Installing kernel headers for ${KREL}..."
    apt-get update -qq || true
    # Proxmox kernels: try the version-pinned header pkgs, then the meta package.
    apt-get install -y "pve-headers-${KREL}" 2>/dev/null \
        || apt-get install -y "proxmox-headers-${KREL}" 2>/dev/null \
        || apt-get install -y proxmox-default-headers 2>/dev/null \
        || true
    [[ -d "/lib/modules/${KREL}/build" ]]
}

if ! ensure_headers; then
    err "Kernel headers for ${KREL} not available — cannot build the r8127 DKMS module. Aborting (r8169 left in place)."
    exit 1
fi
apt-get install -y dkms build-essential >/dev/null 2>&1 || {
    err "Failed to install dkms/build-essential. Aborting (r8169 left in place)."
    exit 1
}

# ── 4. Locate / fetch the driver .deb, verify SHA256 ─────────────────
resolve_deb() {
    local c
    for c in "${SCRIPT_DIR}/assets/${R8127_DEB}" "${SCRIPT_DIR}/${R8127_DEB}" "/root/tappaas/${R8127_DEB}"; do
        [[ -f "$c" ]] && { echo "$c"; return 0; }
    done
    # Fallback: download the pinned release.
    local tmp="/tmp/${R8127_DEB}"
    info "Vendored driver not found locally — downloading ${R8127_URL}"
    if curl -fSL -o "$tmp" "${R8127_URL}"; then
        echo "$tmp"; return 0
    fi
    return 1
}

DEB="$(resolve_deb)" || { err "Could not obtain ${R8127_DEB} (no local copy, download failed)."; exit 1; }

ACTUAL_SHA="$(sha256sum "$DEB" | awk '{print $1}')"
if [[ "${ACTUAL_SHA}" != "${R8127_SHA256}" ]]; then
    err "SHA256 mismatch for ${DEB}: expected ${R8127_SHA256}, got ${ACTUAL_SHA}. Aborting."
    exit 1
fi
info "Driver package verified: ${DEB}"

# ── 5. Install the DKMS package (builds against ${KREL}) ─────────────
info "Installing r8127 DKMS package..."
apt-get install -y "$DEB" || {
    err "r8127 DKMS package install failed. Aborting (r8169 left in place)."
    exit 1
}

# ── 6. Verify the module actually built AND loads on this kernel ─────
# This gate is what makes blacklisting r8169 safe: we only disable the working
# driver once the replacement is proven good on the running kernel.
if ! modinfo r8127 >/dev/null 2>&1; then
    err "r8127 module not found after install (DKMS build failed?). NOT blacklisting r8169."
    exit 1
fi
# Load it now (it won't seize the device while r8169 still holds it, but a
# successful modprobe proves the build is loadable on this kernel).
if ! modprobe r8127 2>/dev/null; then
    err "r8127 built but failed to load (Secure Boot blocking the unsigned module?). NOT blacklisting r8169."
    if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
        err "Secure Boot is ENABLED — disable it in the BIOS (or MOK-sign r8127), then re-run."
    fi
    exit 1
fi
info "r8127 module builds and loads on ${KREL}."

# ── 7. Blacklist r8169 (idempotent) + rebuild initramfs ──────────────
if ! blacklist_present; then
    info "Blacklisting r8169 via ${BLACKLIST_FILE}"
    cat > "${BLACKLIST_FILE}" <<'EOF'
# TAPPaaS issue #308: the RTL8127 10GbE NIC (MS-S1 MAX) must use the r8127
# driver. The in-tree r8169 grabs the device and then drops it on warm reboot
# (only a power cycle recovers it), so r8169 is blacklisted here.
blacklist r8169
EOF
    update-initramfs -u
else
    info "r8169 already blacklisted (${BLACKLIST_FILE}) — leaving as-is."
fi

# ── 8. Report state + required manual steps ──────────────────────────
echo
if all_devices_on_r8127; then
    info "DONE: RTL8127 active on r8127, r8169 blacklisted. Warm reboots are now safe."
else
    warn "STAGED: r8127 installed and r8169 blacklisted, but the device is still bound to r8169."
    warn "  A full POWER CYCLE (not a warm reboot) is required once to switch to r8127:"
    warn "    drain the node (HA maintenance), poweroff, unplug ~30s, power on."
    if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
        warn "  NOTE: Secure Boot is ENABLED — also disable it in the BIOS, or r8127 will not load."
    fi
fi
exit 0
