#!/usr/bin/env bash
#
# test-pbs-encryption.sh — the storage encryption key (#760, ADR-012 §2.5).
#
# vzdump encrypts VM and container backups only when the storage entry carries
# a key; TAPPaaS registered it without one, so every such backup was plaintext.
# pbs_storage_key_ensure runs against a stubbed cluster here: /etc/pve/priv is a
# temp dir, `pvesm` a few lines of bash. What must hold in every state: the
# storage ends up with a key, the escrow holds the same key, and an escrowed key
# is never replaced by a new one — older backups need it.
#
# Usage: ./test-pbs-encryption.sh   (exit 0 = all passed)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }

info() { :; }; warn() { :; }; GN=""; CL=""
get_node_hostname() { echo tappaas1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pbs-enc.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export PBS_ENC_ESCROW_DIR="${TMP}/escrow"
# shellcheck source=pbs-encryption.sh disable=SC1091
. "${HERE}/pbs-encryption.sh"

echo "── the decision ──"
ck "key, escrow agrees → nothing"            none    "$(_pbs_key_action key same)"
ck "key, no escrow → escrow it"              escrow  "$(_pbs_key_action key none)"
ck "key, escrow differs → rotate (keep old)" rotate  "$(_pbs_key_action key differs)"
ck "no key, escrow → restore (rebuilt cluster)" restore "$(_pbs_key_action none same)"
ck "no key, no escrow → create"              create  "$(_pbs_key_action none none)"
_pbs_key_action bogus none >/dev/null; ck "anything else is refused" 1 "$?"

# ── a stubbed cluster ────────────────────────────────────────────────
PRIV="${TMP}/priv"; GENERATED=0
_pbs_enc_ssh() {
    shift   # zone
    local cmd="$*"
    case "${cmd}" in
        "pvesm status --storage "*) [[ -f "${TMP}/registered" ]] ;;
        "cat /etc/pve/priv/storage/"*) local f="${cmd#cat /etc/pve/priv/storage/}"; cat "${PRIV}/${f%% *}" 2>/dev/null ;;
        *"--encryption-key autogen"*) GENERATED=$((GENERATED+1)); mkdir -p "${PRIV}"
            printf '{"kdf":null,"key":"generated-%s"}' "${GENERATED}" > "${PRIV}/tappaas_backup.enc" ;;
        *"--encryption-key '"*) mkdir -p "${PRIV}"
            local k="${cmd#*--encryption-key \'}"; printf '%s' "${k%%\'*}" > "${PRIV}/tappaas_backup.enc" ;;
        *) return 1 ;;
    esac
}
reset() { rm -rf "${PRIV}" "${PBS_ENC_ESCROW_DIR}"; mkdir -p "${PRIV}" "${PBS_ENC_ESCROW_DIR}"; touch "${TMP}/registered"; GENERATED=0; }
ESC="$(pbs_storage_key_escrow_path tappaas_backup)"
cluster() { cat "${PRIV}/tappaas_backup.enc" 2>/dev/null; }
escrow()  { cat "${ESC}" 2>/dev/null; }

echo "── a site that never had a key (every site before #760) ──"
reset
pbs_storage_key_ensure tappaas_backup; rc=$?
ck "succeeds"                                 0 "${rc}"
ck "the storage now has a key"                yes "$([[ -n "$(cluster)" ]] && echo yes || echo no)"
ck "…and the escrow holds the same one"       "$(cluster)" "$(escrow)"
ck "the escrowed copy is private"             600 "$(stat -c %a "${ESC}" 2>/dev/null || stat -f %Lp "${ESC}")"
pbs_storage_key_ensure tappaas_backup >/dev/null
ck "a second run changes nothing (no second key)" 1 "${GENERATED}"

echo "── a rebuilt cluster: no key, but the imported escrow has one ──"
reset
printf '{"kdf":null,"key":"the-original"}' > "${ESC}"
pbs_storage_key_ensure tappaas_backup; rc=$?
ck "succeeds"                                 0 "${rc}"
ck "the ESCROWED key is put back — never a new one" '{"kdf":null,"key":"the-original"}' "$(cluster)"
ck "nothing was generated"                    0 "${GENERATED}"

echo "── a key on the cluster the escrow never saw ──"
reset
printf '{"kdf":null,"key":"made-by-hand"}' > "${PRIV}/tappaas_backup.enc"
pbs_storage_key_ensure tappaas_backup >/dev/null
ck "it is escrowed"                           '{"kdf":null,"key":"made-by-hand"}' "$(escrow)"

echo "── the cluster's key was replaced ──"
reset
printf '{"kdf":null,"key":"old"}' > "${ESC}"
printf '{"kdf":null,"key":"new"}' > "${PRIV}/tappaas_backup.enc"
pbs_storage_key_ensure tappaas_backup >/dev/null
ck "the escrow follows the cluster"           '{"kdf":null,"key":"new"}' "$(escrow)"
ck "…and the old key is KEPT beside it (older backups need it)" '{"kdf":null,"key":"old"}' \
   "$(cat "${PBS_ENC_ESCROW_DIR}"/pve-storage-tappaas_backup.superseded-*.key 2>/dev/null)"
ck "the cluster's key is left alone"          '{"kdf":null,"key":"new"}' "$(cluster)"

echo "── no such storage ──"
reset; rm -f "${TMP}/registered"
pbs_storage_key_ensure tappaas_backup >/dev/null; rc=$?
ck "refused, nothing written"                 "1 no" "${rc} $([[ -e "${ESC}" ]] && echo yes || echo no)"

echo "── the module calls it ──"
ck "install.sh: and refuses to finish without it" yes "$(grep -q 'pbs_storage_key_ensure "${DATASTORE_NAME}"' "${HERE}/../install.sh" && grep -q 'refusing to finish an install that writes plaintext' "${HERE}/../install.sh" && echo yes || echo no)"
ck "update.sh: local and external storage"    2 "$(grep -c 'pbs_storage_key_ensure ' "${HERE}/../update.sh")"
ck "the escrow name is one key export already carries (*.key)" yes "$([[ "${ESC}" == *.key ]] && echo yes || echo no)"

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
