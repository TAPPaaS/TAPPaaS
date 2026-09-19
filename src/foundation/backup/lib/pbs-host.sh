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
