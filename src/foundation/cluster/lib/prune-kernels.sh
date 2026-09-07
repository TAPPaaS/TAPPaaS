#!/usr/bin/env bash
#
# prune-kernels.sh — remove superseded Proxmox kernels on the node this runs on.
#
# Fed to a node by cluster/update.sh via:  ssh root@<node> 'bash -s' < this-file
# (so it runs node-side; it takes no positional args in production).
#
# Keeps exactly three kernel versions and purges every older one:
#   - the RUNNING kernel   — never remove what is loaded; its modules live in
#                            /lib/modules/$(uname -r) and vanish if purged
#   - the LATEST installed
#   - LATEST-1             — a rollback if the newest fails to boot
#
# Deliberately NOT `apt autoremove`: on a node running an older kernel autoremove
# proposes removing the RUNNING kernel (#592), stripping /lib/modules from under
# the live system. The keep-set here ALWAYS contains `uname -r`, so the running
# kernel can never be purged, whatever the reboot state.
#
# Test hooks (production uses none of these):
#   --dry-run        print KEEP/REMOVE and exit; do not purge or touch the boot config
#   --stdin          read candidate package names from stdin, not dpkg-query
#   PRUNE_RUNNING=x  override the running kernel (default: uname -r)
#
set -euo pipefail

DRY_RUN=0
FROM_STDIN=0
for _a in "$@"; do
    case "$_a" in
        --dry-run) DRY_RUN=1 ;;
        --stdin)   FROM_STDIN=1 ;;
        *) printf 'prune-kernels: unknown arg: %s\n' "$_a" >&2; exit 2 ;;
    esac
done

running="${PRUNE_RUNNING:-$(uname -r)}"

# package name -> uname -r form (strip the prefix and the -signed suffix).
# Trailing newline is required: this feeds `sort -Vu` one version per line;
# `$(pkg_version ...)` strips the newline again for the single-value callers.
pkg_version() {
    local p="$1"
    p="${p#proxmox-kernel-}"; p="${p#pve-kernel-}"
    p="${p#proxmox-headers-}"; p="${p#pve-headers-}"
    printf '%s\n' "${p%-signed}"
}

# Installed, fully-versioned kernel image + header packages only. dpkg-query
# (never `dpkg -l`, which truncates the package column to terminal width and
# would corrupt long kernel names). The X.Y.Z-N-pve regex excludes the tracking
# metapackages (proxmox-kernel-9.0, proxmox-headers-9.0) and proxmox-kernel-
# helper, so those are never removed.
list_kernel_packages() {
    if [[ "$FROM_STDIN" -eq 1 ]]; then
        cat
    else
        dpkg-query -W -f='${Package}\n' \
            'proxmox-kernel-*' 'pve-kernel-*' 'proxmox-headers-*' 'pve-headers-*' 2>/dev/null || true
    fi | grep -E '^(proxmox|pve)-(kernel|headers)-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-pve(-signed)?$' || true
}

mapfile -t all_pkgs < <(list_kernel_packages)
mapfile -t versions < <(for p in "${all_pkgs[@]:-}"; do [ -n "$p" ] && pkg_version "$p"; done | sort -Vu)
n=${#versions[@]}

declare -A keep=()
[ -n "$running" ] && keep["$running"]=1
(( n >= 1 )) && keep["${versions[n-1]}"]=1     # latest
(( n >= 2 )) && keep["${versions[n-2]}"]=1     # latest-1

remove=()
for p in "${all_pkgs[@]:-}"; do
    [ -n "$p" ] || continue
    v="$(pkg_version "$p")"
    [ -n "${keep[$v]:-}" ] || remove+=("$p")
done

# Deterministic, sorted output so callers (and the unit test) can parse it.
printf 'KEEP: %s\n' "$(printf '%s\n' "${!keep[@]}" | sort -V | tr '\n' ' ' | sed 's/ *$//')"
if ((${#remove[@]})); then
    printf 'REMOVE: %s\n' "$(printf '%s\n' "${remove[@]}" | sort -V | tr '\n' ' ' | sed 's/ *$//')"
else
    printf 'REMOVE: (none)\n'
fi

[[ "$DRY_RUN" -eq 1 ]] && exit 0
((${#remove[@]})) || exit 0

# Purge exactly the enumerated packages — never autoremove. The running kernel
# is in the keep-set, so it is not in this list by construction.
DEBIAN_FRONTEND=noninteractive apt-get -y purge "${remove[@]}"

# Sync the bootloader only on ESP/systemd-boot nodes; a grub node has no
# proxmox-boot-uuids and the apt postrm hook already ran update-grub.
if [ -f /etc/kernel/proxmox-boot-uuids ]; then
    proxmox-boot-tool clean || true
    proxmox-boot-tool refresh || true
fi
