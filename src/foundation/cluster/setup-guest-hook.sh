#!/usr/bin/env bash
#
# setup-guest-hook.sh — guests wait for the firewall before they start (#127).
#
# Runs ON the node, as root. cluster/update.sh feeds it over the key login:
#
#     ssh root@<node> 'bash -s -- apply <firewall-vmid>' < setup-guest-hook.sh
#
# Guests take their address by DHCP from the firewall VM. After a cold start of
# the whole site (a power cut) each node starts its own guests as soon as it is
# up, while the firewall is an HA resource that starts only once the cluster has
# quorum — so a guest can boot into a network with no DHCP and no DNS. Proxmox's
# `startup: order=` cannot help: it orders guests on one node only, and is
# ignored for HA resources.
#
# So every guest except the firewall carries a pre-start hookscript
# (local:snippets/tappaas-guest-hook.sh) that waits until the firewall answers
# DNS (TCP 53 on the node's default gateway) — at most FW_WAIT_MAX seconds,
# then the guest starts anyway. With the firewall up the wait is one probe
# (~2 ms); the hook never fails a start. A guest that already carries another
# hookscript keeps it and is reported.
#
#   apply <vmid|->   install the hook and its settings, attach it to this node's
#                    guests; `-` = no firewall VM on this site (the hook is a no-op)
#   check            exit 0 when the hook is installed and every guest here has it
#
# Tests: HOST_HOOK_ROOT prefixes every path; HOST_HOOK_DRY=1 records `qm`/`pct`
# instead of running them; HOST_HOOK_NODE / HOST_HOOK_GW stand in for the
# hostname and the default gateway.
set -uo pipefail

MODE="${1:-apply}"
R="${HOST_HOOK_ROOT:-}"
DRY="${HOST_HOOK_DRY:-0}"
NODE="${HOST_HOOK_NODE:-$(hostname)}"
HOOK="${R}/var/lib/vz/snippets/tappaas-guest-hook.sh"
HOOK_REF="local:snippets/tappaas-guest-hook.sh"
ENVF="${R}/etc/tappaas/firewall-wait.env"
WAIT_MAX="${FW_WAIT_MAX:-180}"

case "${MODE}" in apply|check) ;; *) echo "usage: $0 apply <firewall-vmid|-> | check" >&2; exit 2 ;; esac
[[ -n "${R}" || "$(id -u)" -eq 0 ]] || { echo "guest-hook: must run as root" >&2; exit 2; }

want_hook() {
    cat <<'EOF'
#!/usr/bin/env bash
# tappaas-guest-hook — managed by TAPPaaS (cluster/setup-guest-hook.sh, #127). Do not edit.
# Proxmox hookscript: before a guest starts, wait for the firewall to answer DNS,
# at most FW_WAIT_MAX seconds. Never fails a start.
vmid="$1"; phase="$2"
[[ "${phase}" == pre-start ]] || exit 0
[[ -r /etc/tappaas/firewall-wait.env ]] || exit 0
. /etc/tappaas/firewall-wait.env
[[ -n "${FW_VMID:-}" && -n "${FW_ADDR:-}" && "${vmid}" != "${FW_VMID}" ]] || exit 0
max="${FW_WAIT_MAX:-180}"; t=0
port="${FW_PORT:-53}"
until timeout 2 bash -c "</dev/tcp/${FW_ADDR}/${port}" 2>/dev/null; do
    (( t == 0 )) && logger -t tappaas-guest-hook "guest ${vmid}: waiting up to ${max}s for the firewall (${FW_ADDR}:${port}) before it starts"
    if (( t >= max )); then
        logger -t tappaas-guest-hook -p daemon.warning "guest ${vmid}: the firewall (${FW_ADDR}) did not answer in ${max}s — starting anyway"
        exit 0
    fi
    sleep 5; t=$(( t + 5 ))
done
(( t > 0 )) && logger -t tappaas-guest-hook "guest ${vmid}: the firewall answered after ${t}s — starting"
exit 0
EOF
}

gateway() { [[ -n "${HOST_HOOK_GW:-}" ]] && { echo "${HOST_HOOK_GW}"; return; }; ip route show default 2>/dev/null | awk '{print $3; exit}'; }

# This node's guests as "<qm|pct> <vmid> <hookscript or empty>".
guests() {
    local kind dir f id hs
    for kind in qm pct; do
        dir="${R}/etc/pve/nodes/${NODE}/qemu-server"; [[ "${kind}" == pct ]] && dir="${R}/etc/pve/nodes/${NODE}/lxc"
        for f in "${dir}"/*.conf; do
            [[ -e "${f}" ]] || continue
            id="$(basename "${f}" .conf)"
            # The live section only: snapshots ([name]) repeat the keys.
            hs="$(awk '/^\[/{exit} /^hookscript:/{print $2; exit}' "${f}")"
            echo "${kind} ${id} ${hs}"
        done
    done
}

fw_vmid() { [[ -r "${ENVF}" ]] && sed -n 's/^FW_VMID=//p' "${ENVF}"; }

check() {
    local ok=0 fw kind id hs missing="" foreign=""
    if [[ ! -x "${HOOK}" ]]; then echo "guest-hook: hook not installed"; return 1; fi
    if [[ "$(cat "${HOOK}")" != "$(want_hook)" ]]; then echo "guest-hook: hook differs from this release"; ok=1; fi
    fw="$(fw_vmid)"
    if [[ -z "${fw}" ]]; then echo "guest-hook: no firewall VM on this site — the hook waits for nothing"; return "${ok}"; fi
    while read -r kind id hs; do
        [[ -n "${id}" && "${id}" != "${fw}" ]] || continue
        if [[ -z "${hs}" ]]; then missing+=" ${id}"
        elif [[ "${hs}" != "${HOOK_REF}" ]]; then foreign+=" ${id}"
        fi
    done < <(guests)
    [[ -n "${missing}" ]] && { echo "guest-hook: guests without the hook:${missing}"; ok=1; }
    [[ -n "${foreign}" ]] && echo "guest-hook: guests keeping their own hookscript (not waiting for the firewall):${foreign}"
    [[ "${ok}" -eq 0 ]] && echo "guest-hook: every guest here waits for the firewall (VM ${fw}, ${WAIT_MAX}s at most)"
    return "${ok}"
}

[[ "${MODE}" == check ]] && { check; exit $?; }

# ── apply ────────────────────────────────────────────────────────────
FW="${2:-}"
[[ "${FW}" == "-" || "${FW}" =~ ^[0-9]+$ ]] || { echo "guest-hook: apply needs the firewall VMID or '-'" >&2; exit 2; }
fail=0
mkdir -p "$(dirname "${HOOK}")" "$(dirname "${ENVF}")"
if [[ "$(cat "${HOOK}" 2>/dev/null)" != "$(want_hook)" ]]; then
    want_hook > "${HOOK}"; chmod 0755 "${HOOK}"; echo "guest-hook: hook installed"
fi
if [[ "${FW}" == "-" ]]; then
    want_env=""
else
    gw="$(gateway)"
    [[ -n "${gw}" ]] || { echo "guest-hook: no default gateway on ${NODE} — cannot tell where the firewall answers" >&2; exit 1; }
    want_env="$(printf 'FW_VMID=%s\nFW_ADDR=%s\nFW_WAIT_MAX=%s' "${FW}" "${gw}" "${WAIT_MAX}")"
fi
if [[ "$(cat "${ENVF}" 2>/dev/null)" != "${want_env}" ]]; then
    printf '%s\n' "${want_env}" > "${ENVF}"; echo "guest-hook: settings written (firewall VM ${FW})"
fi
if [[ "${FW}" != "-" ]]; then
    while read -r kind id hs; do
        [[ -n "${id}" && "${id}" != "${FW}" && -z "${hs}" ]] || continue
        if [[ "${DRY}" == 1 ]]; then
            echo "${kind} set ${id} --hookscript ${HOOK_REF}" >> "${R}/hook-calls.log"
            c="${R}/etc/pve/nodes/${NODE}/$([[ "${kind}" == qm ]] && echo qemu-server || echo lxc)/${id}.conf"
            { echo "hookscript: ${HOOK_REF}"; cat "${c}"; } > "${c}.new" && mv "${c}.new" "${c}"
        elif ! "${kind}" set "${id}" --hookscript "${HOOK_REF}" >/dev/null 2>&1; then
            echo "guest-hook: could not attach the hook to ${id}" >&2; fail=1; continue
        fi
        echo "guest-hook: attached to ${id}"
    done < <(guests)
fi
out="$(check)"; rc=$?
printf '%s\n' "${out}"
(( rc == 0 && fail == 0 ))
