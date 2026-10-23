#!/usr/bin/env bash
#
# adopt-module.sh — make a module of a machine that already runs (ADR-026 D8.1).
#
# `module-manager module adopt <address>`. The machine is reached, learned, and
# handed to the module for its OS. The one change on it is the module's: a
# debianhost makes SSH key-only unless adopted with --set sshKeyOnly=false (#756):
#
#   1. Reach   — log in as root with the mothership's key (never a password).
#                If that fails, print the one command that authorises the key and
#                wait for it (--wait seconds, default 300); nothing is written
#                until the key works.
#   2. Learn   — hostname, /etc/os-release ID, whether it is a Proxmox node.
#   3. Module  — one module per OS (ADR-026 D7): debian → debianhost, and a
#                Proxmox VE node (Debian underneath) → pvehost (#665). An OS with
#                no machine module stops the adoption; there is no near match.
#                A Proxmox node is adopted only if it is a member of THIS Site's
#                cluster (its own cluster status names another of the site's
#                nodes, or, for the first node, the site) — joining is
#                `site-manager node add`, never a side effect of adopting. Its
#                tankXY zpools become its storagePools (unless --set names them):
#                the pvehost instance is the node's record (ADR-036 D6).
#   4. Name    — the instance is named after the machine (ADR-022f D2); a name
#                already taken by another machine is refused (--instance
#                overrides). Adopting the same machine again changes nothing,
#                except that a node whose instance was archived (node delete)
#                is registered again.
#   5. Zone    — the zone whose subnet holds its address (most specific wins);
#                an address in no active zone stops the adoption (--zone overrides).
#   6. Module  — install-module.sh <module> --instance --address --zone0 --os,
#                which writes config/<instance>.json and runs the module's install.sh.
#
# Refused as well: a Proxmox VE host that is not a member of this Site's
# cluster, and an address another instance already has.
#
# --set field=value (repeatable) is written into the new config before the
# module's install runs. A debianhost's config always states sshKeyOnly, so
# what was chosen at adoption is visible in it (true unless --set says false).
#
# Usage: adopt-module.sh <address> [--instance NAME] [--zone ZONE] [--wait SECONDS] [--set field=value]...
# Exit:  0 adopted, or already adopted · 1 refused or failed (nothing written)

set -uo pipefail

CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"

# ── pure functions (unit-tested: scripts/test/test-adopt.sh) ─────────────

# adopt_field_args <module> [field=value...] — the install-module.sh overrides
# for the --set fields, one `--field value` pair per line pair. A debianhost
# states sshKeyOnly (true unless set) so the config shows what adoption chose.
# rc 1 on an argument that is not field=value.
adopt_field_args() {
    local module="$1" kv key_only=""; shift
    for kv in "$@"; do
        [[ "${kv}" =~ ^([A-Za-z][A-Za-z0-9_.]*)=(.*)$ ]] || { echo "--set '${kv}' is not field=value" >&2; return 1; }
        [[ "${BASH_REMATCH[1]}" == sshKeyOnly ]] && key_only="${BASH_REMATCH[2]}"
        printf -- '--%s\n%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    done
    [[ "${module}" == debianhost && -z "${key_only}" ]] && printf -- '--sshKeyOnly\ntrue\n'
    return 0
}

_ip2int() { local IFS=.; local a b c d; read -r a b c d <<< "$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }

# adopt_zone_for_ip <ipv4> <zones.json> — the most specific ACTIVE zone whose
# subnet holds <ipv4> (a zone whose state is Inactive or Disabled is skipped: a
# machine is not placed in a zone that is switched off). rc 1 when none does.
adopt_zone_for_ip() {
    local ip="$1" zones="$2" best="" bestlen=-1 name cidr net len mask ipn
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    ipn="$(_ip2int "${ip}")"
    while read -r name cidr; do
        net="${cidr%/*}"; len="${cidr#*/}"
        [[ "${net}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "${len}" =~ ^[0-9]+$ ]] || continue
        (( len <= 32 )) || continue
        mask=$(( len == 0 ? 0 : (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
        if (( (ipn & mask) == ($(_ip2int "${net}") & mask) && len > bestlen )); then
            best="${name}"; bestlen="${len}"
        fi
    done < <(jq -r 'to_entries[]
        | select((.value | type) == "object" and ((.value.ip? // "") | type) == "string" and (.value.ip? // "") != "")
        | select(((.value.state // "") | ascii_downcase) as $s | ($s != "inactive" and $s != "disabled"))
        | "\(.key) \(.value.ip)"' "${zones}" 2>/dev/null)
    [[ -n "${best}" ]] || return 1
    printf '%s\n' "${best}"
}

# adopt_module_for_os <os-release ID> [pve] — the machine module for that OS
# (D7). A Proxmox VE node reports ID=debian — PVE is a role on Debian, not an OS
# (ADR-022f D7) — so the second argument says whether pveversion answered.
adopt_module_for_os() {
    case "$1:${2:-}" in
        debian:pve) echo pvehost ;;
        debian:*)   echo debianhost ;;
        *) return 1 ;;
    esac
}

# A Proxmox node's membership of the Site's cluster is tappaas_cluster_member
# (cluster-nodes.sh, re-exported by common-install-routines.sh).

# adopt_pools_json <zpool names...> — the tankXY pools as a JSON array, sorted.
adopt_pools_json() {
    printf '%s\n' "$@" | grep -E '^tank' | LC_ALL=C sort -u | jq -Rsc 'split("\n") | map(select(. != ""))'
}

# adopt_ip_of <address> — an IPv4 address as is, a DNS name resolved (rc 1 when
# it does not resolve). Duplicates are compared by this, so the same machine
# given once as 10.0.0.90 and once by name is still one machine.
adopt_ip_of() {
    if [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s\n' "$1"; return 0; fi
    local r; r="$(getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1 {print $1}')"
    [[ -n "${r}" ]] || return 1
    printf '%s\n' "${r}"
}

# ── the adoption ──────────────────────────────────────────────────────────

_adopt_ssh() {
    ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o LogLevel=ERROR \
        "root@${ADDRESS}" "$@"
}

_adopt_print_key_instructions() {
    local pub; pub="$(cat "${HOME}/.ssh/id_ed25519.pub" 2>/dev/null)"
    warn "root@${ADDRESS} does not accept the mothership's key yet. On the machine, as root, run:"
    echo ""
    echo "  install -d -m 700 /root/.ssh && echo '${pub}' >> /root/.ssh/authorized_keys"
    echo ""
    warn "If root already has a restricted entry (Debian cloud images: \"Please login as the user debian\"),"
    warn "use '>' instead of '>>' — sshd uses the first line that matches."
}

main() {
    . /home/tappaas/bin/common-install-routines.sh

    ADDRESS=""; local instance="" zone="" wait_s=300
    local -a sets=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --set)      sets+=("${2:-}"); shift 2 ;;
            --instance) instance="${2:-}"; shift 2 ;;
            --zone)     zone="${2:-}"; shift 2 ;;
            --wait)     wait_s="${2:-}"; shift 2 ;;
            -h|--help)  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;   # the whole header
            -*)         die "adopt: unknown option '$1'" ;;
            *)          [[ -z "${ADDRESS}" ]] || die "adopt: one address only (got '${ADDRESS}' and '$1')"; ADDRESS="$1"; shift ;;
        esac
    done
    [[ -n "${ADDRESS}" ]] || die "Usage: adopt-module.sh <address> [--instance NAME] [--zone ZONE] [--wait SECONDS] [--set field=value]..."
    [[ "${wait_s}" =~ ^[0-9]+$ ]] || die "--wait takes seconds"

    local ip
    ip="$(adopt_ip_of "${ADDRESS}")" || die "cannot resolve '${ADDRESS}' to an IPv4 address"
    info "${BOLD}Adopting ${BL}${ADDRESS}${CL}${BOLD} (${ip})${CL}"

    # 1. Reach
    if ! _adopt_ssh true >/dev/null 2>&1; then
        _adopt_print_key_instructions
        info "Waiting up to ${wait_s}s for the key to work ..."
        # One try every 20s, not faster: each refused login is an authfail to
        # OpenSSH's PerSourcePenalties (Debian 13: 5s each, enforced from 15s),
        # and polling faster locks the MOTHERSHIP's address out of that machine
        # — the operator's own ssh from it included — for up to 10 minutes.
        local waited=0
        until _adopt_ssh true >/dev/null 2>&1; do
            (( waited >= wait_s )) && die "root@${ADDRESS} still refuses the mothership's key after ${wait_s}s — nothing was written"
            sleep 20; waited=$((waited + 20))
        done
    fi
    info "  ${GN}✓${CL} root by key"

    # 2. Learn
    local facts host id ver pve
    facts="$(_adopt_ssh 'hostname -s; . /etc/os-release; echo "${ID:-}"; echo "${VERSION_ID:-}"; if [ -d /etc/pve ] || command -v pveversion >/dev/null 2>&1; then echo pve; else echo -; fi' 2>/dev/null)" \
        || die "could not read the machine's facts"
    host="$(sed -n 1p <<< "${facts}" | tr '[:upper:]' '[:lower:]')"
    id="$(sed -n 2p <<< "${facts}")"; ver="$(sed -n 3p <<< "${facts}")"; pve="$(sed -n 4p <<< "${facts}")"
    info "  ${GN}✓${CL} ${host} — ${id:-unknown} ${ver}"

    # 3. Module
    local module
    module="$(adopt_module_for_os "${id}" "${pve}")" \
        || die "no machine module for os '${id:-unknown}' — one module per OS (ADR-026 D7); nothing was written"
    if [[ "${module}" == pvehost ]]; then
        local status site_name
        status="$(_adopt_ssh 'pvesh get /cluster/status --output-format json' 2>/dev/null)" || status=""
        site_name="$(jq -r '.name // ""' "${CONFIG_DIR}/site.json" 2>/dev/null)"
        tappaas_cluster_member "${host}" "${status}" "${site_name}" "${CONFIG_DIR}" \
            || die "${ADDRESS} is a Proxmox VE host that is not in this Site's cluster — join it with 'site-manager node add ${host}'; adopting never joins"
        [[ -z "${instance}" || "${instance}" == "${host}" ]] \
            || die "a cluster node's instance is its node name '${host}' — --instance does not apply"
        # The node's record carries the pools it has, unless --set names them.
        if ! printf '%s\n' ${sets[@]+"${sets[@]}"} | grep -q '^storagePools='; then
            local zp
            zp="$(_adopt_ssh 'zpool list -H -o name' 2>/dev/null)" || zp=""
            # shellcheck disable=SC2086
            sets+=("storagePools=$(adopt_pools_json ${zp})")
        fi
    fi

    # 4. Name
    instance="${instance:-${host}}"
    instance_name_ok "${instance}" \
        || die "'${instance}' is not a usable instance name — name it with --instance (a DNS label, not a name config/ already uses)"
    local existing="${CONFIG_DIR}/${instance}.json"
    if [[ -f "${existing}" ]]; then
        local had; had="$(jq -r '.address // empty' "${existing}")"
        if [[ -n "${had}" && "$(adopt_ip_of "${had}")" == "${ip}" && "$(module_of "${instance}" 2>/dev/null)" == "${module}" ]]; then
            if [[ "${module}" == pvehost && "$(jq -r '.status // ""' "${existing}")" == archived ]]; then
                # A deleted node that joined again: its record is the node, so
                # it is registered again (the release's status back, its pools).
                local rel pools
                rel="$(jq -r '.status // "Development"' "$(jq -r '.moduleSource' "${existing}")/pvehost.json" 2>/dev/null)" || rel=Development
                pools="$(printf '%s\n' ${sets[@]+"${sets[@]}"} | sed -n 's/^storagePools=//p' | tail -1)"
                jq --arg s "${rel:-Development}" --argjson p "${pools:-null}" \
                    '.status = $s | if $p == null then . else .storagePools = $p end' "${existing}" > "${existing}.tmp" \
                    && mv "${existing}.tmp" "${existing}" || die "could not re-register ${instance}"
                info "${GN}✓${CL} ${ADDRESS} is registered again as ${instance} (its instance was archived)"
                exit 0
            fi
            info "${GN}✓${CL} ${ADDRESS} is already adopted as ${instance} — nothing to do"
            exit 0
        fi
        die "config/${instance}.json already exists and is not this machine — name this one with --instance"
    fi
    local f other
    for f in "${CONFIG_DIR}"/*.json; do
        [[ -f "${f}" ]] || continue
        other="$(jq -r 'if type == "object" and (.address | type) == "string" then .address else empty end' "${f}" 2>/dev/null)"
        [[ -n "${other}" ]] || continue
        [[ "${other}" == "${ADDRESS}" || "$(adopt_ip_of "${other}")" == "${ip}" ]] \
            && die "${ADDRESS} is already adopted as $(basename "${f}" .json) (address ${other}) — one machine, one instance"
    done

    # 5. Zone
    local zones="${CONFIG_DIR}/zones.json"
    if [[ -n "${zone}" ]]; then
        jq -e --arg z "${zone}" 'has($z)' "${zones}" >/dev/null 2>&1 || die "--zone '${zone}' is not a zone in ${zones}"
    else
        zone="$(adopt_zone_for_ip "${ip}" "${zones}")" \
            || die "${ip} is in no active zone — off-site (a Location reached through a tunnel) or outside the Administrative Domain? Decide, then name it with --zone"
    fi
    info "  ${GN}✓${CL} module ${module}, instance ${instance}, zone ${zone}"

    # 6. Become a module
    local -a fields=()
    local field_lines _l
    field_lines="$(adopt_field_args "${module}" ${sets[@]+"${sets[@]}"})" || die "adopt: --set takes field=value"
    if [[ -n "${field_lines}" ]]; then
        while IFS= read -r _l; do fields+=("${_l}"); done <<< "${field_lines}"
    fi
    install-module.sh "${module}" --instance "${instance}" --address "${ADDRESS}" --zone0 "${zone}" --os "${id}" \
        ${fields[@]+"${fields[@]}"} \
        || die "the ${module} install of ${instance} failed (see above)"
    info "${GN}✓${CL} ${ADDRESS} adopted as ${BL}${instance}${CL} (${module})"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
