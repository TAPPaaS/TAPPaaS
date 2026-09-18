# shellcheck shell=bash
# pbs-reset.sh — leave `external`: the one deliberate door (ADR-012 §2.3, #607).
#
# `external` is sticky so that an operator's choice is never re-derived away.
# Leaving it is therefore an explicit act, `backup-manager placement reset`, and
# it must not lose a single backup on the way out:
#
#   1. The PBS it consumed keeps every snapshot — nothing there is touched.
#   2. Its Proxmox storage entry is RENAMED <pbsStorageName>_former, credential
#      and encryption key with it, so the history stays listable and restorable
#      from Proxmox the whole time. Leaving it under the module's own name would
#      be the trap: the local install finds that name "already configured" and
#      keeps pushing to the external PBS for ever.
#   3. It is written down as a `pull` peer (config only): once the local PBS
#      exists, onboarding it pulls the history into pull/<peer> (§4.3).
#   4. backup.json: placementState → shim, pbsUrl → the local default, and
#      `formerExternal` records what was left behind. The next update promotes
#      the shim to node:<name> on the tankc pool and the clients move there.
#
# Refused: any state but `external`; and a site with no tankc pool to move to —
# a shim backs nothing up, and trading a working external PBS for no backups is
# the one outcome a reset must never have. The old storage entry is removed only
# by `placement finish-reset`, after the pull and a test restore (§4.3).
#
# Requires: common-install-routines.sh and pbs-placement.sh sourced first.

# ── Pure helpers (no cluster access — unit-testable) ─────────────────

# The name of the storage entry the old PBS keeps: <sname>_former.
pbs_reset_former_storage() { printf '%s_former\n' "${1:-tappaas_backup}"; }

# The pull peer the old PBS becomes: "former-<first DNS label of its URL>",
# reduced to what a peer name may hold. Args: <url>
pbs_reset_peer_name() {
    local host="${1#*://}"
    host="${host%%/*}"; host="${host%%:*}"; host="${host%%.*}"
    host="$(printf '%s' "${host}" | tr -c 'A-Za-z0-9_-' '-' | sed 's/-*$//')"
    printf 'former-%s\n' "${host:-pbs}"
}

# Rewrite backup.json for the reset (stdin → stdout). Args: <default-url>
# <former-storage> <datastore> <namespace> <peer> <timestamp>
pbs_reset_config_filter() {
    jq --arg url "$1" --arg fs "$2" --arg ds "$3" --arg ns "$4" --arg peer "$5" --arg t "$6" '
        .formerExternal = {pbsUrl: .pbsUrl, storage: $fs, datastore: $ds, namespace: $ns, peer: $peer, resetAt: $t}
        | .placementState = "shim"
        | .pbsUrl = $url'
}

# ── Cluster ops (a mgmt node; pvesm) ─────────────────────────────────

# The `pvesm add` argv (after `pvesm add pbs <new>`) that recreates the PBS
# storage described by <cfg-json> (pvesh get /storage/<old>), DISABLED: a
# disabled entry is not connected to, so it needs no password yet. One
# shell-quoted line. Pure — parsed here, because a Proxmox node has no jq.
pbs_reset_add_args() {
    local cfg="$1" a=() k v
    [[ "$(jq -r '.type // empty' <<<"${cfg}")" == pbs ]] || return 1
    for k in server datastore username; do
        v="$(jq -r --arg k "$k" '.[$k] // empty' <<<"${cfg}")"
        [[ -n "$v" ]] || return 1
        a+=("--${k}" "$v")
    done
    for k in namespace fingerprint port nodes; do
        v="$(jq -r --arg k "$k" '.[$k] // empty | tostring' <<<"${cfg}")"
        if [[ -n "$v" ]]; then a+=("--${k}" "$v"); fi
    done
    a+=(--content backup --disable 1)
    printf '%q ' "${a[@]}"
}

# Rename a PBS storage entry <old> → <new>, keeping its server, datastore,
# namespace, login, fingerprint, port, node restriction, password, encryption
# key and master key. Proxmox has
# no rename, so: add <new> disabled, copy the secrets, enable it, check it is
# active, and only then remove <old>. Any failure before the remove leaves <old>
# untouched (and takes <new> away again). Args: <old> <new> <cfg-json> [zone]
pbs_storage_rename() {
    local old="$1" new="$2" cfg="$3" zone="${4:-mgmt}" node addargs
    node="$(get_node_hostname 0)"
    addargs="$(pbs_reset_add_args "${cfg}")" || { warn "storage ${old} is not a complete pbs storage entry"; return 1; }
    # SC2087: the heredoc is unquoted on purpose — ${addargs} is expanded HERE
    # (already %q-quoted); everything the node must expand is escaped.
    # shellcheck disable=SC2087
    ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.${zone}.internal" "bash -s -- $(printf '%q %q' "${old}" "${new}")" <<REMOTE
set -euo pipefail
old="\$1" new="\$2" priv=/etc/pve/priv/storage
if pvesm status --storage "\${new}" >/dev/null 2>&1; then echo "storage \${new} already exists" >&2; exit 1; fi
pvesm add pbs "\${new}" ${addargs}
if [ -f "\${priv}/\${old}.pw" ];  then cp -p "\${priv}/\${old}.pw"  "\${priv}/\${new}.pw";  fi
if [ -f "\${priv}/\${old}.enc" ]; then cp -p "\${priv}/\${old}.enc" "\${priv}/\${new}.enc"; fi
if [ -f "\${priv}/\${old}.master.pem" ]; then cp -p "\${priv}/\${old}.master.pem" "\${priv}/\${new}.master.pem"; fi
pvesm set "\${new}" --delete disable
if ! pvesm status --storage "\${new}" | grep -q active; then
    echo "storage \${new} did not come up — \${old} is left as it was" >&2
    pvesm remove "\${new}"; exit 1
fi
pvesm remove "\${old}"
REMOTE
}
