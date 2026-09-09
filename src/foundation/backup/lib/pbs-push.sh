# shellcheck shell=bash
# pbs-push.sh — register a REMOTE PBS as a local push target (ADR-012 P4, #402/#389).
#
# The missing leg of the symmetry (§3.1): the module already PULLS a buddy
# (services/remote, Class A) and RECEIVES a client's push (services/external,
# Class B). Here WE are the source that PUSHES to someone else's PBS — the mirror
# of external-receive, seen from the sender.
#
# Used by `remote-only` sites (single node / no local PBS, §3.4): the remote PBS
# is registered as a Proxmox `pbs` storage and the managed vzdump backup job
# writes VM backups straight there. The credential we hold is WRITE-NO-DELETE —
# the REMOTE grants it (its own `add-external`) and the REMOTE owns prune /
# retention / immutability. So a compromise here can add snapshots but cannot
# erase the off-site copy: the §3.5 append-only invariant, enforced remote-side.
#
# Requires: common-install-routines.sh (get_node_hostname, info/warn/die,
# colours) and lib/pbs-storage.sh — which owns the registration mechanic this
# shares with the external-consume path (§1.3) — sourced first.

# ── Pure helper (no cluster access — unit-testable) ──────────────────

# Local Proxmox storage name for a push target <name>.
_pbs_push_storage_name() { printf 'offsite-%s\n' "$1"; }

# ── Cluster ops (mgmt node; pvesm — delegated to pbs-storage.sh) ─────

# Register (idempotently) a remote PBS as the `offsite-<name>` Proxmox storage
# so vzdump can write to it. Args:
#   name host datastore namespace username password [fingerprint] [port] [zone]
pbs_push_storage_ensure() {
    local name="$1"; shift
    pbs_storage_register "$(_pbs_push_storage_name "$name")" "$@"
}

# Remove the local push storage for <name> (idempotent). Does NOT touch anything
# on the remote — the off-site data and its retention are the remote's to manage.
pbs_push_storage_delete() {
    pbs_storage_unregister "$(_pbs_push_storage_name "$1")" "${2:-mgmt}"
}
