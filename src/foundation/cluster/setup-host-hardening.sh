#!/usr/bin/env bash
#
# setup-host-hardening.sh — CPU microcode and an audit trail on a Proxmox node (#128).
#
# Runs ON the node, as root. cluster/update.sh feeds it over the key login, as
# it does ssh-key-only.sh (#19), so nothing has to be copied there first:
#
#     ssh root@<node> 'bash -s -- apply' < setup-host-hardening.sh
#
# Two controls from the Proxmox hardening guide (docs/pve9-hardening-guide.md):
#
#   microcode   the CPU vendor's package (amd64-microcode / intel-microcode) is
#               installed, so the next boot loads the current microcode early.
#               Present on every node we have seen, but by accident of the
#               installer; now it is declared and checked.
#
#   audit       auditd records CHANGES MADE FROM A LOGIN SESSION — SSH (the
#               mothership's sweep included), the console, the web UI's node
#               Shell — to the cluster's configuration (/etc/pve) and to who can
#               get in (/etc/ssh, /root/.ssh), and to the node's network
#               (/etc/network). Measured on hrossen 2026-10-04: every write to
#               /etc/pve is ~7 a minute, nearly all pvescheduler taking locks;
#               daemons carry no login uid, so `auid!=unset` keeps exactly the
#               changes a person or the sweep made. Changes made through the web
#               UI or the API are pveproxy/pvedaemon's own task log lines, which
#               already reach Loki.
#               auditd's syslog plugin is switched on, so the records go through
#               the journal and the logging module's rsyslog forwarder to Loki
#               (`{source="proxmox"} |= "tappaas-pve"`) — searched across the
#               cluster, not node by node, and not only on the node that could
#               have been tampered with. /var/log/audit/audit.log stays as the
#               local copy.
#               The /etc/pve rules are NOT in rules.d: audit-rules.service loads
#               those at boot, before pmxcfs mounts /etc/pve, and one rule on a
#               missing path fails the whole load — auditd then does not start
#               (tappaas1 after a reboot, 2026-10-08). tappaas-audit-pve.service
#               loads them from ${PVE_RULES} once pve-cluster is up.
#
#   rootkeys    a 5-minute check of WHICH KEYS root's authorized_keys holds
#               (tappaas-rootkeys-check.timer). It logs
#               `tappaas-rootkeys-changed: …` only when the set of key
#               fingerprints changes — a key added or removed — naming each one;
#               the logging module alerts on that line. The audit rule above
#               records every WRITE, and Proxmox rewrites the file on its own:
#               `pvecm updatecerts` runs from the pve packages' postinst, so every
#               night that patched them alerted on all three nodes (hrossen,
#               2026-10-08) though no key had changed. Rewrites, reordering and
#               comment edits no longer alert; the audit trail stays.
#
# Not here, on purpose (see #128): unattended-upgrades (the nightly sweep patches
# the nodes behind its snapshot and test gates), fail2ban (the web UI is reached
# from mgmt and the admin tunnel only; SSH is key-only), a second Corosync link
# (#590, needs the cabling).
#
#   apply   install what is missing, write the rules and the plugin setting when
#           they differ, load them, read back
#   check   exit 0 when both controls are in force, 1 when not; one line each
#
# Exit: 0 done / in force · 1 failed / not in force · 2 usage
#
# Tests: HOST_HARDENING_ROOT prefixes every path it writes and lifts the root
# check; HOST_HARDENING_DRY=1 skips apt, auditctl, augenrules and systemctl
# (cluster/lib/test-host-hardening.sh).

set -uo pipefail

MODE="${1:-apply}"
R="${HOST_HARDENING_ROOT:-}"
DRY="${HOST_HARDENING_DRY:-0}"
RULES="${R}/etc/audit/rules.d/50-tappaas.rules"
PVE_RULES="${R}/etc/audit/tappaas-pve.rules"
CHECKER="${R}/usr/local/sbin/tappaas-rootkeys-check"
UNIT_DIR="${R}/etc/systemd/system"
SYSLOG_PLUGIN="${R}/etc/audit/plugins.d/syslog.conf"
CPUINFO="${HOST_HARDENING_CPUINFO:-/proc/cpuinfo}"
KEYS="tappaas-rootkeys tappaas-pve tappaas-ssh tappaas-network"

case "${MODE}" in apply|check) ;; *) echo "usage: $0 apply|check" >&2; exit 2 ;; esac
[[ -n "${R}" || "$(id -u)" -eq 0 ]] || { echo "host-hardening: must run as root" >&2; exit 2; }

# One rule per path and architecture: a 32-bit syscall would otherwise slip past
# a 64-bit-only rule. The first rule that matches names the record, so root's
# authorized_keys comes first with a key of its own (tappaas-rootkeys): the
# logging module alerts on it (#126), and a SYSCALL line carries the key but
# not the file name. On PVE /root/.ssh/authorized_keys is a symlink to the
# cluster-wide /etc/pve/priv/authorized_keys; both are named.
# Paths that do not exist on this node are left out, because
# auditctl refuses a rule on a missing path and that would fail the whole file.
# want_rules boot|pve: `pve` is everything that lives in pmxcfs (the symlinked
# /root/.ssh/authorized_keys too), loaded after pve-cluster; `boot` the rest.
want_rules() {
    local set="$1" p kind key a
    cat <<'EOF'
## Managed by TAPPaaS (cluster/setup-host-hardening.sh, #128) — do not edit.
## Changes made from a login session to the cluster's configuration, to who can
## get in, and to the node's network. Daemon writes carry no login uid and are
## not recorded; web UI / API changes are in PVE's own task log.
EOF
    while read -r kind p key; do
        case "${p}" in
            /etc/pve*|/root/.ssh/authorized_keys) [[ "${set}" == pve ]] || continue ;;
            *) [[ "${set}" == boot ]] || continue ;;
        esac
        [[ -e "${R}${p}" ]] || continue
        for a in b64 b32; do
            echo "-a always,exit -F arch=${a} -F ${kind}=${p} -F perm=wa -F auid!=unset -k ${key}"
        done
    done <<'EOF'
path /etc/pve/priv/authorized_keys tappaas-rootkeys
path /root/.ssh/authorized_keys tappaas-rootkeys
dir /etc/pve tappaas-pve
dir /etc/ssh tappaas-ssh
dir /root/.ssh tappaas-ssh
path /etc/network/interfaces tappaas-network
dir /etc/network/interfaces.d tappaas-network
EOF
}

# The key-set check, installed as ${CHECKER}. Env overrides are for the tests.
want_checker() {
    cat <<'EOF'
#!/usr/bin/env bash
# tappaas-rootkeys-check — managed by TAPPaaS (cluster/setup-host-hardening.sh). Do not edit.
#
# Logs `tappaas-rootkeys-changed: …` when the SET of keys in root's
# authorized_keys changes (fingerprints, not bytes): a rewrite with the same
# keys — Proxmox's `pvecm updatecerts` — says nothing. The first run records a
# baseline. Runs from tappaas-rootkeys-check.timer every 5 minutes.
set -uo pipefail
FILES="${ROOTKEYS_FILES:-/etc/pve/priv/authorized_keys /root/.ssh/authorized_keys}"
STATE="${ROOTKEYS_STATE:-/var/lib/tappaas/rootkeys}"
LOG="${ROOTKEYS_LOGGER:-logger -t tappaas-rootkeys -p auth.warning}"
mkdir -p "${STATE}"
seen=""
for f in ${FILES}; do
    [[ -e "${f}" ]] || continue
    real="$(readlink -f "${f}")"
    [[ " ${seen} " == *" ${real} "* ]] && continue    # /root/.ssh/… -> /etc/pve/priv/…
    seen+=" ${real}"
    # One line per key: "<fingerprint> (<type>) <comment>", sorted by fingerprint.
    now="$(ssh-keygen -l -E sha256 -f "${real}" 2>/dev/null \
           | awk '{fp=$2; t=$NF; $1=""; $2=""; $NF=""; c=$0; gsub(/^ +| +$/,"",c); print fp" "t" "c}' | sort -u -k1,1)"
    st="${STATE}/$(printf '%s' "${real}" | tr '/' '_').fp"
    if [[ ! -f "${st}" ]]; then
        printf '%s\n' "${now}" > "${st}"
        ${LOG} "tappaas-rootkeys: baseline for ${real}: $(grep -c . <<<"${now}") key(s)"
        continue
    fi
    old="$(cat "${st}")"
    added="$(comm -13 <(cut -d' ' -f1 <<<"${old}" | sort -u) <(cut -d' ' -f1 <<<"${now}" | sort -u))"
    removed="$(comm -23 <(cut -d' ' -f1 <<<"${old}" | sort -u) <(cut -d' ' -f1 <<<"${now}" | sort -u))"
    [[ -z "${added}${removed}" ]] && continue
    msg="tappaas-rootkeys-changed: ${real}"
    for k in ${added};   do msg+=" | + $(grep -m1 "^${k} " <<<"${now}")"; done
    for k in ${removed}; do msg+=" | - $(grep -m1 "^${k} " <<<"${old}")"; done
    ${LOG} "${msg}"
    printf '%s\n' "${now}" > "${st}"
done
EOF
}
want_service() {
    printf '%s\n' '[Unit]' 'Description=TAPPaaS: log changes to the set of root SSH keys (#128)' \
        '[Service]' 'Type=oneshot' 'ExecStart=/usr/local/sbin/tappaas-rootkeys-check'
}
want_pve_unit() {
    printf '%s\n' '[Unit]' 'Description=TAPPaaS: audit rules for /etc/pve, once pmxcfs is up (#128)' \
        'After=pve-cluster.service auditd.service audit-rules.service' 'Requires=pve-cluster.service' 'Wants=auditd.service' \
        '[Service]' 'Type=oneshot' 'RemainAfterExit=yes' 'ExecStart=/usr/sbin/auditctl -R /etc/audit/tappaas-pve.rules' \
        '' '[Install]' 'WantedBy=multi-user.target'
}
want_timer() {
    printf '%s\n' '[Unit]' 'Description=TAPPaaS: check the set of root SSH keys every 5 minutes (#128)' \
        '[Timer]' 'OnBootSec=2min' 'OnUnitActiveSec=5min' 'AccuracySec=30s' '' '[Install]' 'WantedBy=timers.target'
}
# write_if_changed <file> <content> [mode] — echoes "changed" when it wrote.
write_if_changed() {
    [[ "$(cat "$1" 2>/dev/null)" == "$2" ]] && return 0
    mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; chmod "${3:-0644}" "$1"; echo changed
}

microcode_pkg() {
    case "$(awk -F': ' '/^vendor_id/{print $2; exit}' "${CPUINFO}" 2>/dev/null)" in
        AuthenticAMD) echo amd64-microcode ;;
        GenuineIntel) echo intel-microcode ;;
        *)            echo "" ;;
    esac
}
installed() { [[ "${DRY}" == 1 ]] && { [[ -e "${R}/var/lib/dpkg/fake-installed/$1" ]]; return; }
              dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed'; }
apt_install() { [[ "${DRY}" == 1 ]] && { mkdir -p "${R}/var/lib/dpkg/fake-installed"; for p in "$@"; do : > "${R}/var/lib/dpkg/fake-installed/$p"; done; return 0; }
                DEBIAN_FRONTEND=noninteractive apt-get -y -qq install "$@" >/dev/null 2>&1; }
plugin_active() { [[ -f "${SYSLOG_PLUGIN}" ]] && grep -qE '^[[:space:]]*active[[:space:]]*=[[:space:]]*yes' "${SYSLOG_PLUGIN}"; }
rules_loaded() {
    [[ "${DRY}" == 1 ]] && { [[ -f "${RULES}" ]]; return; }
    local k l; l="$(auditctl -l 2>/dev/null)"
    for k in ${KEYS}; do grep -q "key=${k}\b" <<<"${l}" || return 1; done
}

# ── check ────────────────────────────────────────────────────────────────
check() {
    local ok=0 pkg; pkg="$(microcode_pkg)"
    if [[ -z "${pkg}" ]]; then
        echo "microcode: unknown CPU vendor — nothing to install"
    elif installed "${pkg}"; then
        echo "microcode: ${pkg} installed"
    else
        echo "microcode: ${pkg} NOT installed"; ok=1
    fi
    if [[ "${DRY}" != 1 ]] && ! systemctl is-active --quiet auditd; then
        echo "audit: auditd not running"; ok=1
    elif ! rules_loaded; then
        echo "audit: TAPPaaS rules not loaded"; ok=1
    elif [[ ! -f "${UNIT_DIR}/tappaas-audit-pve.service" ]] || grep -q /etc/pve "${RULES}" 2>/dev/null; then
        echo "audit: /etc/pve rules are loaded at boot, before pmxcfs — auditd fails to start on the next reboot"; ok=1
    elif ! plugin_active; then
        echo "audit: rules loaded, but the syslog plugin is off — records stay on the node"; ok=1
    else
        echo "audit: rules loaded (${KEYS// /, }), forwarded via syslog"
    fi
    if [[ ! -x "${CHECKER}" ]]; then
        echo "rootkeys: tappaas-rootkeys-check not installed"; ok=1
    elif [[ "${DRY}" != 1 ]] && ! systemctl is-active --quiet tappaas-rootkeys-check.timer; then
        echo "rootkeys: tappaas-rootkeys-check.timer not active"; ok=1
    else
        echo "rootkeys: key-set check every 5 minutes (alerts on an added or removed key only)"
    fi
    return "${ok}"
}

[[ "${MODE}" == check ]] && { check; exit $?; }

# ── apply ────────────────────────────────────────────────────────────────
fail=0
pkg="$(microcode_pkg)"
if [[ -n "${pkg}" ]] && ! installed "${pkg}"; then
    # Debian ships microcode in non-free-firmware, which the PVE installer
    # enables; a node without it gets a reason, not a silent skip.
    if apt_install "${pkg}"; then
        echo "microcode: installed ${pkg} — loaded at the next boot"
    else
        echo "microcode: could not install ${pkg} (is non-free-firmware in the apt sources?)" >&2; fail=1
    fi
fi

if ! installed auditd || ! installed audispd-plugins; then
    apt_install auditd audispd-plugins || { echo "audit: could not install auditd" >&2; exit 1; }
    echo "audit: installed auditd"
fi

# The /etc/pve set and the unit that loads it go first: the boot file below
# drops those rules, and a reload of it (-D) clears every loaded rule.
pv="$(write_if_changed "${PVE_RULES}" "$(want_rules pve)" 0640)"
pv+="$(write_if_changed "${UNIT_DIR}/tappaas-audit-pve.service" "$(want_pve_unit)")"
if [[ "${DRY}" != 1 && -n "${pv}" ]]; then
    systemctl daemon-reload; systemctl enable --quiet tappaas-audit-pve.service || fail=1
fi

mkdir -p "$(dirname "${RULES}")"
new="$(want_rules boot)"
if [[ "$(cat "${RULES}" 2>/dev/null)" != "${new}" ]]; then
    printf '%s\n' "${new}" > "${RULES}.tappaas-new"
    if [[ "${DRY}" != 1 ]]; then
        # augenrules compiles every rules.d file into audit.rules; check the
        # result BEFORE loading, and keep the previous file when it is refused.
        prev="$(cat "${RULES}" 2>/dev/null || true)"
        mv -f "${RULES}.tappaas-new" "${RULES}"
        if ! augenrules --load >/dev/null 2>&1; then
            if [[ -n "${prev}" ]]; then printf '%s\n' "${prev}" > "${RULES}"; else rm -f "${RULES}"; fi
            augenrules --load >/dev/null 2>&1 || true
            echo "audit: rules refused by augenrules — previous rules kept" >&2; exit 1
        fi
    else
        mv -f "${RULES}.tappaas-new" "${RULES}"
    fi
    echo "audit: rules written and loaded"
    pv+=boot
fi

if ! plugin_active; then
    mkdir -p "$(dirname "${SYSLOG_PLUGIN}")"
    if [[ -f "${SYSLOG_PLUGIN}" ]] && grep -qE '^[[:space:]]*active[[:space:]]*=' "${SYSLOG_PLUGIN}"; then
        sed -E 's/^([[:space:]]*active[[:space:]]*=[[:space:]]*).*/\1yes/' "${SYSLOG_PLUGIN}" > "${SYSLOG_PLUGIN}.tappaas-new" \
            && cat "${SYSLOG_PLUGIN}.tappaas-new" > "${SYSLOG_PLUGIN}" && rm -f "${SYSLOG_PLUGIN}.tappaas-new"
    else
        printf 'active = yes\ndirection = out\npath = /sbin/audisp-syslog\ntype = always\nargs = LOG_INFO\nformat = string\n' > "${SYSLOG_PLUGIN}"
    fi
    if [[ "${DRY}" != 1 ]]; then
        systemctl enable --quiet auditd 2>/dev/null || true
        # auditd refuses a manual stop (RefuseManualStop); a reload (SIGHUP)
        # re-reads plugins.d, and is all a changed plugin needs.
        if systemctl is-active --quiet auditd; then
            systemctl reload auditd >/dev/null 2>&1 || service auditd reload >/dev/null 2>&1 || fail=1
        else
            systemctl start auditd >/dev/null 2>&1 || fail=1
        fi
    fi
    echo "audit: syslog plugin on — records go to the journal and on to Loki"
fi
[[ "${DRY}" == 1 ]] || systemctl enable --quiet --now auditd 2>/dev/null || true
# (Re)load the /etc/pve set when it or the boot set changed, or when something
# — an auditd package upgrade's augenrules — dropped it since. After auditd is
# up: starting it runs audit-rules, whose -D clears every loaded rule.
if [[ "${DRY}" != 1 ]] && { [[ -n "${pv}" ]] || ! rules_loaded; }; then
    systemctl restart tappaas-audit-pve.service >/dev/null 2>&1 \
        || { echo "audit: could not load ${PVE_RULES}" >&2; fail=1; }
fi
[[ -n "${pv}" ]] && echo "audit: /etc/pve rules load after pve-cluster (tappaas-audit-pve.service)"

# The key-set check (rootkeys above).
rk="$(write_if_changed "${CHECKER}" "$(want_checker)" 0755)"
rk+="$(write_if_changed "${UNIT_DIR}/tappaas-rootkeys-check.service" "$(want_service)")"
rk+="$(write_if_changed "${UNIT_DIR}/tappaas-rootkeys-check.timer" "$(want_timer)")"
if [[ "${DRY}" != 1 ]]; then
    [[ -n "${rk}" ]] && systemctl daemon-reload
    systemctl enable --quiet --now tappaas-rootkeys-check.timer || fail=1
    # First run now: it records the baseline, so the next real change is caught.
    [[ -n "${rk}" ]] && systemctl start tappaas-rootkeys-check.service >/dev/null 2>&1 || true
fi
[[ -n "${rk}" ]] && echo "rootkeys: key-set check installed (timer every 5 minutes)"

out="$(check)"; rc=$?
printf '%s\n' "${out}"
(( rc == 0 && fail == 0 ))
