#!/usr/bin/env bash
#
# Unit tests for leaving `external` (ADR-012 §2.3, #607) — pbs-reset.sh. The
# naming and config rewrite are pure; the storage rename runs over ssh, so ssh
# is replaced by a stub that captures the script the node would run, and the
# test asserts its ORDER: the old entry is removed last, after the new one is
# up, and never when it does not come up.
#
# Usage: ./test-pbs-reset.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { :; }; warn() { :; }; error() { echo "ERR: $*" >&2; }; debug() { :; }
# shellcheck disable=SC2034  # read by the sourced library
BOLD=""; CL=""; BL=""; GN=""; BGN=""
get_node_hostname() { echo "tappaas1"; }

# shellcheck source=pbs-reset.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-reset.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pbsreset.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# ── names ────────────────────────────────────────────────────────────
ck "former storage: <sname>_former"          tappaas_backup_former "$(pbs_reset_former_storage tappaas_backup)"
ck "peer name from a bare host"              former-pbs            "$(pbs_reset_peer_name pbs.lan.example)"
ck "peer name from a URL with port and path" former-offsite        "$(pbs_reset_peer_name https://offsite.example.org:8007/x)"
ck "peer name keeps only peer-name characters" former-my-pbs       "$(pbs_reset_peer_name 'my pbs.example')"

# ── backup.json rewrite ──────────────────────────────────────────────
out="$(echo '{"placementState":"external","pbsUrl":"pbs.lan.example","pbsStorageName":"tappaas_backup"}' \
    | pbs_reset_config_filter backup.mgmt.internal tappaas_backup_former store1 ns1 former-pbs 20260918-12:00:00)"
ck "state → shim"                  shim                     "$(jq -r .placementState <<<"${out}")"
ck "pbsUrl → the local default"    backup.mgmt.internal     "$(jq -r .pbsUrl <<<"${out}")"
ck "formerExternal keeps the old URL, storage, datastore, namespace, peer" \
   '{"pbsUrl":"pbs.lan.example","storage":"tappaas_backup_former","datastore":"store1","namespace":"ns1","peer":"former-pbs","resetAt":"20260918-12:00:00"}' \
   "$(jq -c .formerExternal <<<"${out}")"
ck "other fields untouched"        tappaas_backup           "$(jq -r .pbsStorageName <<<"${out}")"

# ── the pvesm add argv ───────────────────────────────────────────────
CFG='{"type":"pbs","server":"pbs.lan","datastore":"store1","username":"tappaas@pbs","namespace":"site a","fingerprint":"aa:bb","port":8007,"content":"backup"}'
args="$(pbs_reset_add_args "${CFG}")"
eval "set -- ${args}"
ck "argv: server, datastore, username, namespace (quoted), fingerprint, port, disabled" \
   "--server|pbs.lan|--datastore|store1|--username|tappaas@pbs|--namespace|site a|--fingerprint|aa:bb|--port|8007|--content|backup|--disable|1" \
   "$(IFS='|'; echo "$*")"
ck "argv: optional fields left out when absent" \
   "--server pbs.lan --datastore store1 --username u@pbs --content backup --disable 1" \
   "$(eval "echo $(pbs_reset_add_args '{"type":"pbs","server":"pbs.lan","datastore":"store1","username":"u@pbs"}')")"
pbs_reset_add_args '{"type":"dir","path":"/x"}' >/dev/null && ck "a non-pbs storage is refused" 1 0 || ck "a non-pbs storage is refused" 1 1
pbs_reset_add_args '{"type":"pbs","server":"s"}' >/dev/null && ck "an incomplete pbs entry is refused" 1 0 || ck "an incomplete pbs entry is refused" 1 1

# ── the rename script, in order ──────────────────────────────────────
ssh() { cat > "${TMP}/remote.sh"; printf '%s\n' "$@" > "${TMP}/ssh-args"; return 0; }
pbs_storage_rename tappaas_backup tappaas_backup_former "${CFG}" mgmt; rc=$?
ck "rename runs"                   0 "${rc}"
grep -q "root@tappaas1.mgmt.internal" "${TMP}/ssh-args" && ck "on a mgmt node" ok ok || ck "on a mgmt node" ok "$(cat "${TMP}/ssh-args")"
order="$(grep -oE 'pvesm (add pbs|set|remove)|cp -p "\$\{priv\}/\$\{old\}\.(pw|enc)"' "${TMP}/remote.sh" | tr '\n' ',')"
ck "add (disabled) → copy password → copy key → enable → … → remove old LAST" \
   'pvesm add pbs,cp -p "${priv}/${old}.pw",cp -p "${priv}/${old}.enc",pvesm set,pvesm remove,pvesm remove,' "${order}"
grep -q 'master.pem' "${TMP}/remote.sh" && ck "the master key is carried too" ok ok || ck "the master key is carried too" ok missing
grep -q 'pvesm remove "${new}"; exit 1' "${TMP}/remote.sh" \
    && ck "a new entry that does not come up is taken away, and the old one kept" ok ok \
    || ck "a new entry that does not come up is taken away, and the old one kept" ok missing
grep -q -- "--disable 1" "${TMP}/remote.sh" && ck "the new entry is added disabled (no password needed yet)" ok ok || ck "added disabled" ok missing
# The script must be valid bash as the node receives it (old/new as $1 $2).
bash -n "${TMP}/remote.sh" && ck "the node script parses" ok ok || ck "the node script parses" ok broken

echo ""
echo "pbs-reset: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
