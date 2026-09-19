#!/usr/bin/env bash
#
# dns-sample.sh — which installed modules Standard 4 may hold to a DNS record.
#
# Standard 4 asserts that an installed module resolves at <vmname>.<zone>.
# internal. That is only true of a module with a RUNNING guest: the record
# comes from the DHCP lease the guest takes, so a module with no guest has no
# record, and the check fails on a site that is behaving exactly as designed.
#
# `module delete` defaults to --archive — the supported way to retire a module —
# which destroys the VM and KEEPS the config, `vmname` and all. Nothing ever
# restores a lease for a VM that no longer exists, so an archived module failed
# Standard 4 permanently, and since Standard 4 runs as a pre-update gate, that
# wedged `modify network` at the site for good (#631). A merely stopped module
# failed the same way until someone started it again.
#
# The two exclusions that were already here are the same shape — aliasType=
# network (#241/#255) names a set of devices, and a backup module with no local
# datastore (ADR-012 §2.1) has no host of its own. This adds the third.
#
# Nothing here bridges config and runtime: the config says which modules exist,
# the cluster says which guests run, and a module is checked only when both
# agree it should answer.
#

# dns_sample_running_vmids <config-node> — the vmids of every RUNNING guest in
# the cluster, one per line, from the first node that answers.
#
# Prints nothing and returns 1 when no node answers. That is NOT "nothing is
# running": the caller must tell the two apart, because treating an unreachable
# cluster as an empty runtime silently excludes every module and turns Standard
# 4 into a green tick over an unexamined site.
dns_sample_running_vmids() {
    local cand raw
    for cand in "$@"; do
        [[ -n "${cand}" ]] || continue
        raw="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes \
                   -o StrictHostKeyChecking=accept-new \
                   "root@${cand}.mgmt.internal" \
                   "pvesh get /cluster/resources --type vm --output-format json" \
               2>/dev/null)" || continue
        [[ -n "${raw}" ]] || continue
        jq -r '.[] | select(.status == "running") | .vmid' <<< "${raw}" 2>/dev/null
        return 0
    done
    return 1
}

# dns_sample_select <config-dir> <running-vmids-file|""> — decide which modules
# Standard 4 should check. Sets, rather than prints, because the caller needs
# the tallies as well as the list:
#
#   DNS_SAMPLE_MODULES    newline-separated vmnames, sorted and deduped
#   DNS_SAMPLE_RECORDS    newline-separated "<vmname>\t<zone0>", same selection.
#                         The zone is read from the SAME config file the vmname
#                         came from — which is the whole point (#657): the
#                         caller used to re-read the config keyed by vmname, and
#                         a module whose config file is named differently (a
#                         variant, or an install in a non-default environment)
#                         returned nothing, fell back to the literal "srvHome"
#                         and was then failed on a name the estate never
#                         declared. An empty zone means the config declares
#                         none; the caller reports that rather than inventing
#                         one.
#   DNS_SAMPLE_N_ALIAS    excluded: aliasType=network
#   DNS_SAMPLE_N_HOSTLESS excluded: backup with no local datastore
#   DNS_SAMPLE_N_GUESTLESS excluded: no running guest
#
# An empty second argument means the runtime is UNKNOWN (no node answered): the
# guest filter is then skipped entirely and only the config-only exclusions
# apply, so an unreachable cluster degrades to the old, wider check rather than
# to an empty one.
# shellcheck disable=SC2034  # read by the sourcing test script
DNS_SAMPLE_MODULES=""
# shellcheck disable=SC2034  # read by the sourcing test script
DNS_SAMPLE_RECORDS=""
DNS_SAMPLE_N_ALIAS=0
DNS_SAMPLE_N_HOSTLESS=0
DNS_SAMPLE_N_GUESTLESS=0

dns_sample_select() {
    local config_dir="$1" running="${2:-}"
    local f vmname alias_type placement_state status vmid zone picked="" picked_records=""
    DNS_SAMPLE_N_ALIAS=0; DNS_SAMPLE_N_HOSTLESS=0; DNS_SAMPLE_N_GUESTLESS=0

    for f in "${config_dir}"/*.json; do
        [[ -f "${f}" ]] || continue
        vmname="$(jq -r '.vmname // empty' "${f}" 2>/dev/null)" || continue
        # The backup module owns no VM and has no vmname (#612): its name is
        # the instance's — <instance>.<zone>.internal, an alias of its Host —
        # and it is sampled under that, not dropped for lacking a vmname.
        if [[ -z "${vmname}" ]] && jq -e 'has("placementState")' "${f}" >/dev/null 2>&1; then
            vmname="$(basename "${f}" .json)"
        fi
        [[ -n "${vmname}" ]] || continue

        # #241/#255: a device-set alias has no <vmname> record by design.
        alias_type="$(jq -r '.aliasType // "host"' "${f}" 2>/dev/null)"
        if [[ "${alias_type}" == "network" ]]; then
            DNS_SAMPLE_N_ALIAS=$((DNS_SAMPLE_N_ALIAS + 1)); continue
        fi

        # ADR-012 §2.1: a backup module realizing no LOCAL PBS — a shim (no
        # datastore anywhere) or external (someone else's, reached by URL) —
        # has no host of its own. `remote-only` is the legacy spelling of
        # external, still seen until the module's next update.
        placement_state="$(jq -r '.placementState // empty' "${f}" 2>/dev/null)"
        case "${placement_state}" in
            shim|external|remote-only)
                DNS_SAMPLE_N_HOSTLESS=$((DNS_SAMPLE_N_HOSTLESS + 1)); continue ;;
        esac

        # #631: no running guest, so no lease and no record. `archived` is the
        # marker `module delete --archive` leaves behind and needs no cluster
        # to read; a stopped guest is only visible in the runtime.
        status="$(jq -r '.status // empty' "${f}" 2>/dev/null)"
        if [[ "${status}" == "archived" ]]; then
            DNS_SAMPLE_N_GUESTLESS=$((DNS_SAMPLE_N_GUESTLESS + 1)); continue
        fi
        if [[ -n "${running}" ]]; then
            vmid="$(jq -r '.vmid // empty' "${f}" 2>/dev/null)"
            # A config with no vmid describes no guest we can look up — a
            # policy-only module or a static host entry. Leave it in rather
            # than excluding on an absence: being wrong here costs a check,
            # and this file exists because the other direction costs the site.
            if [[ -n "${vmid}" ]] && ! grep -qxF "${vmid}" "${running}"; then
                DNS_SAMPLE_N_GUESTLESS=$((DNS_SAMPLE_N_GUESTLESS + 1)); continue
            fi
        fi

        # Pattern A nests fields under .config."<module>:<service>", so the zone
        # is found by descent, not at the top level — the same shape that hid
        # proxyAllowedZones from Standard 12 (#555).
        zone="$(jq -r '[..|objects|select(has("zone0"))|.zone0] | map(select(. != null and . != "")) | first // empty' "${f}" 2>/dev/null || true)"
        picked+="${vmname}"$'\n'
        picked_records+="${vmname}"$'\t'"${zone}"$'\n'
    done

    # shellcheck disable=SC2034  # read by the sourcing test script
    DNS_SAMPLE_MODULES="$(printf '%s' "${picked}" | sort -u)"
    # shellcheck disable=SC2034  # read by the sourcing test script
    DNS_SAMPLE_RECORDS="$(printf '%s' "${picked_records}" | sort -u)"
}
