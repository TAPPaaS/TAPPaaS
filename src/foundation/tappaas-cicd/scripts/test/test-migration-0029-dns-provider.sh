#!/usr/bin/env bash
# test-migration-0029-dns-provider.sh — the fixture test for migration 0029 (ADR-043 D6).
#
# The legacy credential file becomes a ca-manager provider: its fields in the key
# dir, mode 600, their names only in certificates.json; the CAs already recorded
# are kept; --check writes nothing; a second run is a no-op; a provider of that
# name with other fields, a file naming no provider, and a broken record stop it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0029-dns-credential-becomes-provider.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0029.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"; K="${TMP}/keys"; C="${TMP}/creds"
reset() { rm -rf "${CFG}" "${K}"; mkdir -p "${CFG}"; printf 'provider=cloudflare\ndns_cf_token=s3cr3t # comment\ndns_cf_account_id=42\n' > "${C}"; }
run() { CONFIG_DIR="${CFG}" TAPPAAS_CA_DIR="${K}" TAPPAAS_ACME_CREDS="${C}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0029" bash "${M}" "$@" 2>&1; }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

reset
out="$(run --check)"; ck "--check succeeds" 0 $?
ck "--check writes nothing" "no" "$([[ -e "${CFG}/certificates.json" || -e "${K}" ]] && echo yes || echo no)"
run >/dev/null; ck "applies" 0 $?
ck "the provider is recorded, serving any domain" '{"type":"cloudflare","domains":[],"keys":["dns_cf_account_id","dns_cf_token"]}' "$(jq -c '.providers.cloudflare | del(.added)' "${CFG}/certificates.json")"
ck "the record holds no secret" "no" "$(grep -q s3cr3t "${CFG}/certificates.json" && echo yes || echo no)"
ck "the secret is in the key dir, mode 600" "600 dns_cf_token=s3cr3t" "$(mode "${K}/providers/cloudflare.env") $(grep token "${K}/providers/cloudflare.env")"
ck "the file is left for acme-setup.sh" "yes" "$([[ -f "${C}" ]] && echo yes || echo no)"
out="$(run)"; ck "a second run is a no-op" "yes" "$([[ "${out}" == *"nothing to migrate"* ]] && echo yes || echo no)"

reset; echo '{"version":1,"cas":{"internal":{"scope":"internal"}},"certificates":{}}' > "${CFG}/certificates.json"
run >/dev/null; ck "the CAs already recorded are kept" "internal cloudflare" "$(jq -r '[(.cas|keys[]), (.providers|keys[])] | join(" ")' "${CFG}/certificates.json")"
ck "…and backed up first" "yes" "$([[ -f "${CFG}/.migrations/backup/0029/certificates.json" ]] && echo yes || echo no)"

reset; echo '{"version":1,"cas":{},"certificates":{},"providers":{"cloudflare":{"type":"cloudflare","domains":[],"keys":["dns_cf_other"]}}}' > "${CFG}/certificates.json"
run >/dev/null; ck "a provider of that name with other fields stops it" 1 $?
reset; printf 'dns_cf_token=x\n' > "${C}"; run >/dev/null; ck "a file naming no provider stops it" 1 $?
reset; echo '{' > "${CFG}/certificates.json"; run >/dev/null; ck "a broken record stops it" 1 $?
reset; rm -f "${C}"; out="$(run)"; ck "no file: nothing to do" 0 $?

echo ""
echo "test-migration-0029-dns-provider: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
