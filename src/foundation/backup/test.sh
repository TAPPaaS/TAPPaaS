#!/usr/bin/env bash
# backup/test.sh — module test for the backup (Proxmox Backup Server) module.
#
# FAST (default): the pure unit suites for the PBS helper libs (lib/test-*.sh) —
#   no cluster access (vmid-list CSV logic, ACL-path / parent-chain / retention).
#   These were previously orphaned (no module test.sh aggregated them).
# DEEP (TAPPAAS_TEST_DEEP=1): read-only live PBS reachability via backup-controller.
#
# Note: the per-VM backup verification (services/vm/test-service.sh) is a SERVICE
# test run by test-module.sh for each module that declares `dependsOn backup:vm`
# — it belongs to those consumer modules, not here.
#
# Usage: ./test.sh        (fast) ; TAPPAAS_TEST_DEEP=1 ./test.sh   (+ live PBS)
set -uo pipefail

# Accept --deep as well as TAPPAAS_TEST_DEEP=1. Every gate below reads the
# variable, so exporting it here is all a flag needs to do — and exporting (not
# just setting) is what carries it into any suite this one dispatches. Without
# this, `test.sh --deep` silently ran the fast path.
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && export TAPPAAS_TEST_DEEP=1; done


here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

echo "== backup: PBS helper unit tests (offline) =="
shopt -s nullglob
for t in "${here}"/lib/test-*.sh "${here}"/pulse/test-*.sh; do
    echo "-- $(basename "${t}") --"
    bash "${t}" || rc=1
done

# ── #604: nothing in install.sh touches the PBS host's filesystem locally ──
# The datastore lives on the PBS node. A mkdir/rm/chown against a /<storage>
# path without an ssh runs on the MOTHERSHIP instead, where that path is not a
# mount — it silently creates a stray tree on the root filesystem, and (under
# `set -e`, with a sudo that asks for a password) can abort the install outright.
echo "== backup: no local filesystem writes to a PBS storage path (#604) =="
_stray="$(grep -nE '^[[:space:]]*(sudo[[:space:]]+)?(mkdir|rm|chown|chmod|touch)[^|]*[[:space:]]/\$\{?STORAGE' \
    "${here}/install.sh" "${here}/update.sh" 2>/dev/null || true)"
if [[ -z "${_stray}" ]]; then
    echo "  ok: install.sh/update.sh never write to /\${STORAGE} without ssh"
else
    echo "  FAIL: a local write to the PBS storage path — it would run on the mothership:"
    printf '%s\n' "${_stray}" | sed 's/^/      /'
    rc=1
fi

if [[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]]; then
    echo "== backup (deep): live PBS reachability =="
    if command -v backup-controller >/dev/null 2>&1; then
        # `list` takes a MODULE argument (`list <module>`), so a bare `list` is a
        # usage error, not a reachability result — it exited non-zero on every
        # healthy system and reported "could not reach PBS". Probe with verbs that
        # genuinely query PBS and need no arguments.
        if backup-controller job-status >/dev/null 2>&1 \
           && backup-controller namespaces >/dev/null 2>&1; then
            echo "  ✓ backup-controller reaches PBS (job + namespaces queryable)"
        else
            echo "  ✗ backup-controller could not reach PBS"
            backup-controller job-status 2>&1 | tail -3 | sed 's/^/      /'
            backup-controller namespaces 2>&1 | tail -3 | sed 's/^/      /' 
            rc=1
        fi
    else
        echo "  SKIP: backup-controller not on PATH (run the module install first)"
    fi

    # ADR-031: the pulse runs on the backup node, and nothing it watches is down.
    echo "== backup (deep): the pulse on the backup node =="
    _pnode="$(jq -r '.node // empty' "${CONFIG_DIR:-/home/tappaas/config}/backup.json" 2>/dev/null)"
    # A cluster node is a `kind: machine` module too (pvehost): site.json says which
    # it is. A debianhost is reached by its address; a satellite has no pulse yet.
    _pcfg="${CONFIG_DIR:-/home/tappaas/config}/${_pnode}.json"
    _paddr="${_pnode}.mgmt.internal"
    if ! jq -e --arg n "${_pnode}" '[.hardware.nodes[]?.name] | index($n) != null' \
            "${CONFIG_DIR:-/home/tappaas/config}/site.json" >/dev/null 2>&1; then
        _paddr="$(jq -r '.address // empty' "${_pcfg}" 2>/dev/null)"
        jq -e '(.moduleSource // "") | test("/satellite/?$")' "${_pcfg}" >/dev/null 2>&1 && _paddr=""
    fi
    if [[ -z "${_pnode}" || -z "${_paddr}" ]]; then
        echo "  SKIP: no pulse here (no backup node, a satellite, or one without an address)"
    else
        _pout="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes "root@${_paddr}" \
            "systemctl is-active tappaas-pulse.timer; /usr/local/sbin/tappaas-pulse --status" 2>/dev/null)"
        if [[ "$(head -1 <<< "${_pout}")" == "active" ]]; then
            echo "  ✓ the pulse timer runs on ${_pnode}"
            _pdown="$(awk 'NR>2 && $2=="DOWN"{print $1}' <<< "${_pout}" | paste -sd, -)"
            if [[ -n "${_pdown}" ]]; then echo "  WARN: the pulse reports down: ${_pdown} (backup-manager pulse)"
            else echo "  ✓ nothing the pulse watches is down"; fi
        else
            echo "  ✗ the pulse is not running on ${_pnode} — the backup update installs it"
            rc=1
        fi
    fi

    # #760: VM and container backups are encrypted (ADR-012 §2.5) — the storage
    # carries a key, and the escrow holds the same one. Without the key, vzdump
    # writes plaintext; without the escrowed copy, a rebuilt cluster cannot read
    # a single backup.
    echo "== backup (deep): VM and container backups are encrypted =="
    declare -F get_node_hostname >/dev/null 2>&1 \
        || . /home/tappaas/bin/common-install-routines.sh 2>/dev/null || true
    if command -v jq >/dev/null 2>&1 && declare -F get_node_hostname >/dev/null 2>&1; then
        _store="$(jq -r '.pbsStorageName // "tappaas_backup"' "${CONFIG_DIR:-/home/tappaas/config}/backup.json" 2>/dev/null)"
        _node="$(get_node_hostname 0 2>/dev/null)"
        _key="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes "root@${_node}.mgmt.internal" \
            "cat /etc/pve/priv/storage/${_store}.enc 2>/dev/null" 2>/dev/null)"
        _esc="/etc/secrets/backup-fs/pve-storage-${_store}.key"
        if [[ -z "${_key}" ]]; then
            echo "  ✗ storage ${_store} has NO encryption key — VM and container backups are plaintext (#760)"
            echo "      fix: module-manager module update backup"
            rc=1
        elif [[ "${_key}" != "$(cat "${_esc}" 2>/dev/null || sudo -n cat "${_esc}" 2>/dev/null)" ]]; then
            echo "  ✗ storage ${_store} encrypts, but ${_esc} does not hold its key — a rebuilt cluster could not restore"
            echo "      fix: module-manager module update backup"
            rc=1
        else
            echo "  ✓ backups to ${_store} are encrypted; the key is escrowed"
        fi
    else
        echo "  SKIP: cannot reach the cluster from here"
    fi

    # #742: has each backup:filesystem consumer ever actually captured?
    #
    # The unit's own state cannot answer this. A capture that has NEVER succeeded
    # and one that failed last night both leave a failed unit, and on a mothership
    # the nightly rebuild clears that — which is how a site went ten days with no
    # capture of its config while reporting zero failed units and ok: true. PBS
    # holds the only durable answer: an empty namespace means never.
    echo "== backup (deep): has every filesystem capture ever run? =="
    _fs_lib="${here}/lib/pbs-fs.sh"
    if [[ -r "${_fs_lib}" ]] && command -v jq >/dev/null 2>&1; then
        # shellcheck disable=SC1090
        . "${here}/lib/pbs-job.sh" 2>/dev/null || true
        # pbs-namespace.sh defines _pbs_node_run, which is how anything reaches
        # the PBS node. Without it every query returns empty and an entirely
        # healthy site reads as "never captured" — a false FAIL is worse than no
        # check at all, so the guard below refuses to judge unless it loaded.
        # shellcheck disable=SC1090
        . "${here}/lib/pbs-namespace.sh" 2>/dev/null || true
        # shellcheck disable=SC1090
        . "${_fs_lib}" 2>/dev/null || true
        if ! declare -F _pbs_node_run >/dev/null 2>&1; then
            echo "  SKIP: _pbs_node_run not loaded — cannot reach PBS, so nothing is claimed"
        elif declare -F pbs_fs_consumers >/dev/null 2>&1; then
            _now="$(date +%s)"; _seen=0
            while read -r _m; do
                [[ -n "${_m}" ]] || continue
                _seen=$(( _seen + 1 ))
                _last="$(pbs_fs_last_capture "${_m}" 2>/dev/null)"
                if [[ -z "${_last}" || "${_last}" == "null" ]]; then
                    echo "  FAIL: ${_m} has NEVER captured — its namespace holds no snapshot"
                    echo "        a missing encryption key does this silently (#742); try:"
                    echo "        module-manager module update ${_m}"
                    rc=1
                elif (( _now - _last > 172800 )); then
                    # Two daily windows: one missed run is a hiccup, two is a fault.
                    echo "  TEST-WARN: ${_m}'s newest capture is $(( (_now - _last) / 86400 ))d old ($(date -d "@${_last}" '+%Y-%m-%d %H:%M' 2>/dev/null))"
                else
                    echo "  ✓ ${_m} captured $(date -d "@${_last}" '+%Y-%m-%d %H:%M' 2>/dev/null)"
                fi
            done < <(pbs_fs_consumers)
            (( _seen > 0 )) || echo "  (no module declares backup:filesystem on this site)"
        else
            echo "  SKIP: pbs-fs.sh did not load its helpers"
        fi
    else
        echo "  SKIP: lib/pbs-fs.sh not readable, or jq missing"
    fi
else
    echo "  (deep tier skipped — set TAPPAAS_TEST_DEEP=1 for the live PBS check)"
fi

echo ""
[[ "${rc}" -eq 0 ]] && echo "backup: all tests passed" || echo "backup: FAILURES above"
exit "${rc}"
