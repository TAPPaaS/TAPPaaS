# shellcheck shell=bash
# pbs-dns.sh — the PBS's DNS name follows its Host (ADR-012 §2.7, #612).
#
# Backup is `kind: application`: it owns no VM, so `vmname` named nothing. What
# the field was really used for is the name every client pushes to —
# `backup.mgmt.internal`. That name is the backup INSTANCE's name
# (config/<instance>.json, ADR-026 D6.1; default `backup`), and it is registered
# as a CNAME on the dnsmasq entry of the Host in `placementState: node:<host>` —
# a cluster node or a `debianhost` machine — not as an A record of an address
# captured at install. When the PBS moves, the alias moves with one call; when
# the Host's address changes, nothing needs to.
#
#   pbs_dns_name <instance> <zone>          → <instance>.<zone>.internal
#   pbs_dns_ensure <instance> <zone> <host> → the alias exists and points at <host>
#
# `external` and `shim` register nothing: an external PBS is reached by its own
# pbsUrl, and a shim has no PBS to name.
#
# Requires: common-install-routines.sh (info/warn/CONFIG_DIR) sourced first, and
# dns-manager on PATH.

# ── Pure helpers ─────────────────────────────────────────────────────

pbs_dns_name() { printf '%s.%s.internal\n' "${1:-backup}" "${2:-mgmt}"; }

# The instance a backup script runs for: its first argument (update-module.sh
# and install-module.sh pass the instance name), else the default `backup`.
pbs_instance() { printf '%s\n' "${1:-backup}"; }

# ── Cluster ops (the firewall, through dns-manager) ──────────────────

# Is <fqdn> a dnsmasq host entry (an A record) right now? `dns-manager list`
# prints "  <fqdn>  -> <ip>  (<description>)".
_pbs_dns_is_host_entry() {
    dns-manager --no-ssl-verify list 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

# Make sure <host>.<zone>.internal has a dnsmasq entry a CNAME can point at.
# Cluster nodes ship with one; a `debianhost` machine may not, so it gets one
# from its instance's `address` (resolved when it is a name).
_pbs_dns_ensure_host_entry() {
    local host="$1" zone="$2" fqdn addr ip cfg
    fqdn="${host}.${zone}.internal"
    _pbs_dns_is_host_entry "${fqdn}" && return 0
    cfg="${CONFIG_DIR:-/home/tappaas/config}/${host}.json"
    addr="$(jq -r '.address // empty' "${cfg}" 2>/dev/null)"
    [[ -n "${addr}" ]] || { warn "  ${fqdn} has no DNS entry and config/${host}.json no address — cannot point the PBS name at it"; return 1; }
    if [[ "${addr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then ip="${addr}"
    else ip="$(getent ahostsv4 "${addr}" 2>/dev/null | awk 'NR==1 {print $1}')"; fi
    [[ -n "${ip}" ]] || { warn "  cannot resolve ${addr} for ${fqdn}"; return 1; }
    info "  registering ${fqdn} → ${ip} (the Host the PBS name will follow)"
    dns-manager --no-ssl-verify add "${host}" "${zone}.internal" "${ip}" --description "TAPPaaS machine ${host}" >/dev/null
}

# The IP a dnsmasq host entry <fqdn> points at, from `dns-manager list`.
_pbs_dns_entry_ip() {
    dns-manager --no-ssl-verify list 2>/dev/null | awk -v f="$1" '$1 == f {print $3; exit}'
}

# pbs_dns_ensure <instance> <zone> <host> — idempotent. Replaces the legacy A
# record of the same name (every install before #612 wrote one) with the alias;
# the gap between the two calls is one firewall reconfigure.
#
# Never leaves the name unresolvable: the alias verb is probed BEFORE the A
# record is touched (a control plane not yet refreshed has a dns-manager
# without it — which deleted hrossen's record once, 2026-09-19), and if adding
# the alias fails after the delete, the A record is put back.
pbs_dns_ensure() {
    local instance="$1" zone="$2" host="$3" name old_ip=""
    name="$(pbs_dns_name "${instance}" "${zone}")"
    [[ -n "${host}" ]] || { warn "  no Host for ${name} — not registering it"; return 1; }
    dns-manager --no-ssl-verify alias list >/dev/null 2>&1 \
        || { warn "  this dns-manager has no 'alias' verb yet (control plane not refreshed?) — ${name} left as it is"; return 1; }
    _pbs_dns_ensure_host_entry "${host}" "${zone}" || return 1
    if _pbs_dns_is_host_entry "${name}"; then
        old_ip="$(_pbs_dns_entry_ip "${name}")"
        info "  replacing the A record ${name} with an alias of ${host}.${zone}.internal (#612)"
        dns-manager --no-ssl-verify delete "${instance}" "${zone}.internal" >/dev/null \
            || { warn "  could not remove the old A record ${name}"; return 1; }
    fi
    if ! dns-manager --no-ssl-verify alias add "${name}" "${host}" "${zone}.internal" >/dev/null; then
        warn "  could not point ${name} at ${host}.${zone}.internal"
        if [[ -n "${old_ip}" ]]; then
            dns-manager --no-ssl-verify add "${instance}" "${zone}.internal" "${old_ip}" --description "PBS Backup Server" >/dev/null \
                && warn "  restored the A record ${name} → ${old_ip}" \
                || warn "  ${name} DOES NOT RESOLVE — restore it: dns-manager add ${instance} ${zone}.internal ${old_ip}"
        fi
        return 1
    fi
    info "  ${GN}✓${CL} ${name} → ${host}.${zone}.internal"
}
