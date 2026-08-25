#!/usr/bin/env bash
#
# test-unbound-prune.sh — unit tests for unbound_prune_host_override (#505) in
# common-install-routines.sh.
#
# Stubs `unbound-manager` on PATH and asserts the prune helper:
#   - deletes a stale per-service <host>.<zone> record when it exists,
#   - is a no-op when the record is absent,
#   - NEVER deletes the shared '*' wildcard (owned by acme-setup),
#   - is a no-op on an empty host.
#
# Never touches the live firewall or the cluster.
#
# Usage: test-unbound-prune.sh
# Prints "Results: N passed, M failed"; exits 1 on any failure.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/common-install-routines.sh"

PASS=0
FAIL=0
ok()  { echo "  ok: $*";   PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/unbound-prune.XXXXXX")"
cleanup() { [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"; return 0; }
trap cleanup EXIT INT TERM

# ── Stub unbound-manager on PATH ─────────────────────────────────────
# `list` prints a header + one row per FIXTURE line (host<TAB>zone); `delete
# <host> <zone>` appends "<host> <zone>" to DELETED_LOG. Flags are ignored.
export DELETED_LOG="${WORK}/deleted.log"
: > "${DELETED_LOG}"
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/unbound-manager" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
sub=""
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-ssl-verify) shift ;;
        --port) shift 2 ;;
        *) if [[ -z "${sub}" ]]; then sub="$1"; else args+=("$1"); fi; shift ;;
    esac
done
case "${sub}" in
    list)
        printf '%-20s %-28s %-6s %-16s %s\n' "HOST" "DOMAIN" "TYPE" "VALUE" "DESCRIPTION"
        if [[ -n "${FIXTURE:-}" ]]; then
            while IFS=$'\t' read -r h z; do
                [[ -z "${h}" ]] && continue
                printf '%-20s %-28s %-6s %-16s %s\n' "${h}" "${z}" "A" "10.6.0.1" "stub"
            done <<< "${FIXTURE}"
        fi
        ;;
    delete)
        printf '%s %s\n' "${args[0]:-}" "${args[1]:-}" >> "${DELETED_LOG}"
        ;;
esac
STUB
chmod +x "${WORK}/bin/unbound-manager"
export PATH="${WORK}/bin:${PATH}"

# Source the library under test (no $1 → no module JSON auto-load).
# shellcheck source=common-install-routines.sh disable=SC1091
. "${LIB}"

# ── Test 1: prunes an existing per-service override ───────────────────
: > "${DELETED_LOG}"
export FIXTURE=$'*\tmakerfloss.eu\nidentity\tmakerfloss.eu'
unbound_prune_host_override "identity" "makerfloss.eu" >/dev/null 2>&1
if grep -qx "identity makerfloss.eu" "${DELETED_LOG}"; then
    ok "prunes stale identity.makerfloss.eu"
else
    bad "did not prune existing identity.makerfloss.eu (log: $(cat "${DELETED_LOG}"))"
fi

# ── Test 2: no-op when the record is absent ──────────────────────────
: > "${DELETED_LOG}"
export FIXTURE=$'*\tmakerfloss.eu'
unbound_prune_host_override "identity" "makerfloss.eu" >/dev/null 2>&1
if [[ ! -s "${DELETED_LOG}" ]]; then
    ok "no-op when the record is absent"
else
    bad "deleted despite absent record: $(cat "${DELETED_LOG}")"
fi

# ── Test 3: never deletes the '*' wildcard ───────────────────────────
: > "${DELETED_LOG}"
export FIXTURE=$'*\tmakerfloss.eu'
unbound_prune_host_override "*" "makerfloss.eu" >/dev/null 2>&1
if [[ ! -s "${DELETED_LOG}" ]]; then
    ok "never deletes the '*' wildcard"
else
    bad "deleted the '*' wildcard: $(cat "${DELETED_LOG}")"
fi

# ── Test 4: empty host is a no-op ────────────────────────────────────
: > "${DELETED_LOG}"
unbound_prune_host_override "" "makerfloss.eu" >/dev/null 2>&1
if [[ ! -s "${DELETED_LOG}" ]]; then
    ok "empty host is a no-op"
else
    bad "deleted on empty host: $(cat "${DELETED_LOG}")"
fi

echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
