# shellcheck shell=bash
# pbs-host.sh — something patches the PBS's Host (#603, ADR-012 §1.3, ADR-026).
#
# The backup module installs PBS onto a Host; it does not own that Host's OS.
# Whoever owns the Host patches it — and with it the PBS packages, which are
# ordinary apt packages on it:
#
#   a cluster node      the cluster module (update-os.sh, Step 1 of its update)
#   a machine           its `debianhost` instance (apt full-upgrade in the sweep)
#
# So the backup module's job is only to make sure the Host HAS an owner: a
# machine that is not yet a module instance is adopted — registration only,
# nothing on it changes (ADR-026 D8.1). If that fails, every update says loudly
# that nothing patches the PBS host, instead of the silence #603 reported.
#
# Requires: common-install-routines.sh (info/warn, module_of, CONFIG_DIR) and
# pbs-placement.sh (pbs_node_is_cluster_member) sourced first; adopt-module.sh
# on PATH.

# pbs_host_owner <host> <zone> — who patches <host>; echoes ONE word:
#   cluster      a member of this cluster: the cluster module
#   <module>     a registered machine instance (debianhost, pvehost, …)
#   adopted      it was not registered; it now is (as debianhost, by adopt)
#   none         nothing patches it (rc 1) — adopt failed, or it is not a machine
#   unknown      the cluster did not answer, so membership is unknown (rc 2)
pbs_host_owner() {
    local host="$1" zone="${2:-mgmt}" rc=0 module
    [[ -n "${host}" ]] || { echo none; return 1; }
    pbs_node_is_cluster_member "${host}" "${zone}" || rc=$?
    case "${rc}" in
        0) echo cluster; return 0 ;;
        2) echo unknown; return 2 ;;
    esac
    if [[ -f "${CONFIG_DIR:-/home/tappaas/config}/${host}.json" ]]; then
        module="$(module_of "${host}" 2>/dev/null)"
        if [[ -n "${module}" ]]; then echo "${module}"; return 0; fi
    fi
    if adopt-module.sh "${host}.${zone}.internal" --wait 0 >/dev/null 2>&1; then
        echo adopted; return 0
    fi
    echo none; return 1
}

# pbs_host_ensure_patched <host> <zone> — say who patches the PBS's Host, and
# warn (never fail: the backups themselves are unaffected) when nothing does.
pbs_host_ensure_patched() {
    local host="$1" zone="${2:-mgmt}" owner rc=0
    owner="$(pbs_host_owner "${host}" "${zone}")" || rc=$?
    case "${owner}" in
        cluster)  info "  ${GN}✓${CL} the PBS host ${host} is a cluster node — patched by the cluster module" ;;
        adopted)  info "  ${GN}✓${CL} the PBS host ${host} is now a debianhost instance — patched by the sweep (#603)" ;;
        unknown)  warn "  cannot tell whether ${host} is a cluster node (cluster unreachable) — not checking who patches it" ;;
        none)     warn "  NOTHING PATCHES the PBS host ${host}: it is not a cluster node and could not be adopted as a machine."
                  warn "    Register it by its address: module-manager module adopt <ip-or-fqdn of ${host}> (#603)" ;;
        *)        info "  ${GN}✓${CL} the PBS host ${host} is a ${owner} instance — patched by the sweep" ;;
    esac
    return "${rc}"
}

# ── A PBS on a machine: reaching it, and installing it (ADR-012 §1.3) ──

# pbs_host_path_ensure <host> — let the nodes reach the PBS on <host>. A Host's
# module may ship `pbs-path.sh <instance> open`: a satellite does, since the
# nodes reach it only through its tunnel (ADR-010 §8.4.3). A cluster node, or a
# machine on the LAN (debianhost), needs nothing and has no such script.
pbs_host_path_ensure() {
    local host="$1" dir
    [[ -n "${host}" && -f "${CONFIG_DIR:-/home/tappaas/config}/${host}.json" ]] || return 0
    dir="$(get_module_dir "${host}" 2>/dev/null)" || return 0
    [[ -x "${dir}/pbs-path.sh" ]] || return 0
    info "  the PBS host ${host} is reached through its module (${dir##*/}): opening the path"
    (cd "${dir}" && ./pbs-path.sh "${host}" open)
}

# pbs_install_on_machine <host> <zone> — the official PBS onto a Debian machine
# that is not a cluster node (ADR-012 §1.3): the Proxmox repository key and the
# pbs-no-subscription source, then proxmox-backup-server + -client. Idempotent. A
# cluster node gets its packages from install.sh's PVE path instead (its keyring
# is already there).
pbs_install_on_machine() {
    local host="$1" zone="${2:-mgmt}"
    ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        "root@$(pbs_host_addr "${host}" "${zone}")" 'bash -s' <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release
[ "${ID:-}" = debian ] || { echo "not Debian (${ID:-?}) — PBS installs on Debian only" >&2; exit 1; }
if command -v proxmox-backup-manager >/dev/null 2>&1; then
    echo "proxmox-backup-server already installed"; exit 0
fi
cn="${VERSION_CODENAME:-trixie}"
apt-get -q update >/dev/null && apt-get -q -y install curl ca-certificates >/dev/null
curl -fsSL "https://enterprise.proxmox.com/debian/proxmox-release-${cn}.gpg" -o /usr/share/keyrings/proxmox-archive-keyring.gpg \
  || curl -fsSL "http://download.proxmox.com/debian/proxmox-release-${cn}.gpg" -o /usr/share/keyrings/proxmox-archive-keyring.gpg
printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pbs\nSuites: %s\nComponents: pbs-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' \
    "${cn}" > /etc/apt/sources.list.d/proxmox.sources
apt-get -q update >/dev/null
apt-get -q -y install proxmox-backup-server proxmox-backup-client >/dev/null
rm -f /etc/apt/sources.list.d/pbs-enterprise.sources
echo "proxmox-backup-server installed: $(proxmox-backup-manager version 2>/dev/null | head -1)"
REMOTE
}
