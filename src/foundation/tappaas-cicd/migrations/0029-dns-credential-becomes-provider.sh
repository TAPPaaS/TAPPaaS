#!/usr/bin/env bash
# 0029-dns-credential-becomes-provider.sh — the ACME DNS credential becomes a ca-manager provider
#
# Introduced: 2.4.  Required by: ADR-043 D6/D7 (ca-manager holds the DNS providers).
# Touches: config/certificates.json (its providers), and the key dir's
#          providers/<name>.env (TAPPAAS_CA_DIR, default ~tappaas/.tappaas-ca).
# Reversible: yes — restore config/.migrations/backup/0029/certificates.json (or
#          delete it, when the backup holds none) and remove providers/<name>.env.
#
# WHY. Until ADR-043 the one DNS-API credential lived in ~/.acme-dns-credentials.txt,
# which acme-setup.sh read and nothing owned. ca-manager now issues the wildcard
# through a named provider, so the file's credential becomes one, serving any
# domain, as the file did. It is written as ca-manager writes it, not through
# ca-manager: a migration runs right after the pull, before the managers are
# rebuilt. The file itself is left: acme-setup.sh, a shim for one release, still
# reads it when ca-manager has nothing.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): a certificates.json that is
# not JSON, a file with no provider= line or no dns_… field, and a provider of
# that name that ca-manager already has with other fields.
#
# Usage: 0029-dns-credential-becomes-provider.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a state it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0029}"
CREDS="${TAPPAAS_ACME_CREDS:-${HOME}/.acme-dns-credentials.txt}"
KEY_DIR="${TAPPAAS_CA_DIR:-/home/tappaas/.tappaas-ca}"
RECORD="${CONFIG_DIR}/certificates.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo -e "\033[32m[Info]\033[m   0029: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0029: $*" >&2; exit 1; }

[[ -f "${CREDS}" ]] || { say "no ${CREDS} — nothing to migrate"; exit 0; }
[[ ! -f "${RECORD}" ]] || jq empty "${RECORD}" 2>/dev/null || stop "${RECORD} is not valid JSON — refusing to touch it"

provider=""; fields=()
while IFS= read -r line; do
    line="${line%%#*}"; line="$(printf '%s' "${line}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ "${line}" == *=* ]] || continue
    k="$(printf '%s' "${line%%=*}" | sed -E 's/[[:space:]]+$//')"; v="$(printf '%s' "${line#*=}" | sed -E 's/^[[:space:]]+//')"
    case "${k}" in
        provider) provider="${v}" ;;
        dns_*)    [[ -n "${v}" ]] && fields+=("${k}=${v}") ;;
    esac
done < "${CREDS}"
[[ -n "${provider}" ]] || stop "${CREDS} names no provider= — a person should say which provider it is for"
[[ ${#fields[@]} -gt 0 ]] || stop "${CREDS} has no dns_… field — nothing to carry over"

name="$(printf '%s' "${provider#dns_}" | tr '[:upper:]_' '[:lower:]-')"
keys_json="$(printf '%s\n' "${fields[@]}" | sed 's/=.*//' | sort | jq -R . | jq -sc .)"
if [[ -f "${RECORD}" ]] && jq -e --arg n "${name}" '.providers[$n] // empty' "${RECORD}" >/dev/null; then
    [[ "$(jq -c --arg n "${name}" '.providers[$n].keys' "${RECORD}")" == "${keys_json}" ]] \
        || stop "ca-manager already has a provider ${name} with other fields — a person should choose which credential is right"
    say "ca-manager already has the provider ${name} — nothing to migrate"
    exit 0
fi

if [[ "${CHECK}" -eq 1 ]]; then
    say "would make ${CREDS} the ca-manager provider ${name} (${provider}, any domain): $(jq -r 'join(", ")' <<<"${keys_json}")"
    exit 0
fi

mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
[[ ! -f "${RECORD}" ]] || cp -p "${RECORD}" "${BACKUP_DIR}/certificates.json" || stop "cannot back up ${RECORD} — refusing to write"

# The secret first, mode 600, as ca-manager keeps it.
(umask 077; mkdir -p "${KEY_DIR}/providers")
secret="${KEY_DIR}/providers/${name}.env"
(umask 077; printf '%s\n' "${fields[@]}" | sort > "${secret}.tmp") && mv -f "${secret}.tmp" "${secret}"

base='{"version":1,"cas":{},"certificates":{}}'
[[ -f "${RECORD}" ]] && base="$(cat "${RECORD}")"
tmp="${RECORD}.0029.tmp"
jq --arg n "${name}" --arg t "${provider}" --argjson k "${keys_json}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.providers = ((.providers // {}) + {($n): {type: $t, domains: [], keys: $k, added: $at}})' <<<"${base}" > "${tmp}" \
    || { rm -f "${tmp}"; stop "rewrite failed — ${RECORD} is unchanged"; }
jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the rewritten record is not valid JSON — it is unchanged"; }
mv -f "${tmp}" "${RECORD}"
say "${CREDS} is now the ca-manager provider ${name} (${provider}, any domain); the file is left for acme-setup.sh"
