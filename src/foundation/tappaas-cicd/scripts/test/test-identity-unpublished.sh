#!/usr/bin/env bash
#
# test-identity-unpublished.sh — identity services on a site that publishes
# nothing (#698).
#
# An environment may legitimately have no domain: `domains` is not in the
# environment schema's required list, and `mgmt` is the standard case — its
# modules are reached at <vmname>.<zone>.internal and published nowhere.
# network:proxy has skipped on that fact since #438. The identity services did
# not: they died, which failed the whole module update of anything that
# dependsOn them and rolled it back. That is how #698 was found — `logging`
# gained identity:identity, and makerfloss's scheduled sweep rolled it back
# while hrossen (whose mgmt environment does have a domain) passed.
#
# The second claim here is the one with teeth. accessControl must skip ONLY
# when nothing is published. A module that does not hardcode proxyDomain is
# still published at <vmname>.<environment domain> by network:proxy, so if
# accessControl read only the explicit field it would see "unpublished", skip,
# and leave the module EXPOSED behind a proxy handler with forward-auth off.
# Skipping is safe exactly when there is no domain anywhere.
#
# Tabletop: fixture config dir, no VM, no Authentik. Exits 77 where the shared
# routines are not installed (a dev laptop), as the sweep expects.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDENTITY_SVC="$(cd "${HERE}/../../../identity/services" 2>/dev/null && pwd)"
[[ -n "${IDENTITY_SVC}" && -f "${IDENTITY_SVC}/identity/install-service.sh" ]] || {
    echo "identity services not found beside this suite — cannot run here."; exit 77; }
[[ -f /home/tappaas/bin/common-install-routines.sh ]] || {
    echo "common-install-routines.sh is not installed — cannot run here."; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "jq not found — cannot run here."; exit 77; }

PASS=0; FAIL=0
ok()   { echo "  ok: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
ckin() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1 (no '$2' in output)"; fi; }
cknot() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1 (unexpected '$2' in output)"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/identity-unpublished.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
mkdir -p "${TMP}/environments"

# An internal-only environment, exactly as makerfloss has it: schema-valid,
# with no `domains` object at all.
cat > "${TMP}/environments/mgmt.json" <<'EOF'
{ "name": "mgmt", "displayName": "Management", "ownerOrg": "test",
  "network": { "zone": "mgmt" } }
EOF
# A published environment, as hrossen and every app environment have it.
cat > "${TMP}/environments/pub.json" <<'EOF'
{ "name": "pub", "displayName": "Published", "ownerOrg": "test",
  "domains": { "primary": "example.test", "dnsMode": "per-service" },
  "network": { "zone": "srvHome" } }
EOF

# The module never hardcodes proxyDomain — the case that matters, because that
# is when the domain (and therefore "is it published?") comes from the
# environment. $1 = environment name, $2 = extra JSON fields.
write_module() {
    local env="$1" extra="${2:-}"
    [[ -n "${extra}" ]] || extra='{}'
    jq -n --arg env "${env}" --argjson extra "${extra}" '
        { vmname: "logging", zone0: "mgmt", environment: $env,
          kind: "vm", vmid: 9999 } + $extra' > "${TMP}/logging.json"
}

# Sets OUT and RC. Deliberately NOT `OUT="$(run_svc …)"`: command substitution
# runs the function in a subshell, where the rc it captures dies with it — and
# the rc is half of what this suite asserts.
run_svc() {  # $1 = identity|accessControl
    local svc="$1"
    CONFIG_DIR="${TMP}" timeout 45 "${IDENTITY_SVC}/${svc}/install-service.sh" logging \
        > "${TMP}/svc-out.txt" 2>&1
    RC=$?
    OUT="$(cat "${TMP}/svc-out.txt")"
}

echo "── identity:identity, environment with no domain ──"
write_module mgmt
run_svc identity
[[ "${RC}" -eq 0 ]] && ok "exits 0 instead of failing the module update" \
                    || bad "exited ${RC} (expected 0 — a fatal here rolls the module back)"
ckin "says the environment publishes no domain" "publishes no domain" "${OUT}"
ckin "says what it did instead of registering" "skipping identity registration" "${OUT}"
ckin "names the internal address the module is actually reached at" "logging.mgmt.internal" "${OUT}"
cknot "no longer blames the module's own fields" "must set vmname, zone0, proxyDomain" "${OUT}"

echo "── identity:accessControl, environment with no domain ──"
run_svc accessControl
[[ "${RC}" -eq 0 ]] && ok "exits 0 instead of failing the module update" \
                    || bad "exited ${RC} (expected 0)"
ckin "says forward-auth is skipped" "skipping forward-auth" "${OUT}"

echo "── the verifier must agree with the installer ──"
# The half that actually rolled makerfloss's logging back a second time: the
# installer skipped, then test-service.sh reported the absent OIDC application
# as drift, so `reconcile --apply` declared the module unconverged.
CONFIG_DIR="${TMP}" timeout 45 "${IDENTITY_SVC}/identity/test-service.sh" logging \
    > "${TMP}/test-out.txt" 2>&1
RC=$?; OUT="$(cat "${TMP}/test-out.txt")"
[[ "${RC}" -eq 0 ]] && ok "test-service reports no drift for an unpublished module" \
                    || bad "test-service exited ${RC} (expected 0 — drift here fails the reconcile)"
ckin "and says why there was nothing to check" "no SSO to verify" "${OUT}"
cknot "does not report a missing OIDC application" "no OIDC application" "${OUT}"

echo "── the exposure guard: a DERIVED domain still counts as published ──"
# network:proxy publishes this module at logging.example.test even though the
# module names no proxyDomain. Neither service may treat it as unpublished.
write_module pub '{"proxyPort": 3000}'
run_svc accessControl
cknot "accessControl does not skip a module the proxy publishes" "skipping forward-auth" "${OUT}"
run_svc identity
cknot "identity does not skip a module the proxy publishes" "skipping identity registration" "${OUT}"

echo "── a published module with no proxyPort is still a misconfiguration ──"
write_module pub
run_svc accessControl
[[ "${RC}" -ne 0 ]] && ok "accessControl fails when it has a domain but no upstream port" \
                    || bad "accessControl accepted a published module with no proxyPort"
ckin "and says which fact is missing" "no proxyPort" "${OUT}"

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
