#!/usr/bin/env bash
#
# test-config-readers.sh — unit tests for the site.json + environments reader
# cutover (ADR-007 S3b Phase B) in common-install-routines.sh.
#
# Exercises the central config-reader helpers against TEMP fixtures only — never
# the live config, never the cluster. Verifies:
#   - NEW sources are read when present: node helpers from site.json
#     (.hardware.nodes[].name); site-wide scalars from site.json; get_variant_config
#     from config/environments/<env>.json; tlsCertRefid from cert-refids.json.
#   - FALLBACK to configuration.json works when site.json / env files /
#     cert-refids.json are absent (the running system must not break mid-migration).
#
# Usage: test-config-readers.sh
# Prints "Results: N passed, M failed"; exits 1 on any failure.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/common-install-routines.sh"

# Source the library under test (do NOT auto-load any module JSON: no $1).
# shellcheck source=common-install-routines.sh disable=SC1091
. "${LIB}"

PASS=0
FAIL=0
ok()  { echo "  ok: $*";   PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
eq()  { if [[ "$1" == "$2" ]]; then ok "$3 ($1)"; else bad "$3 (got '$1', want '$2')"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cfg-readers.XXXXXX")"
cleanup() { [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"; return 0; }
trap cleanup EXIT INT TERM

# ── Fixture 1: NEW sources present (site.json + environments + cert-refids) ──
NEW="${WORK}/new"
mkdir -p "${NEW}/environments"
cat > "${NEW}/site.json" <<'JSON'
{
  "name": "acme",
  "displayName": "Acme Site",
  "email": "admin@acme.test",
  "version": "site-v2",
  "snapshotRetention": 9,
  "automaticReboot": false,
  "hardware": { "nodes": [
    { "name": "tappaas1", "storagePools": [] },
    { "name": "tappaas2", "storagePools": [] },
    { "name": "tappaas3", "storagePools": [] }
  ] },
  "repositories": [ { "name": "TAPPaaS", "path": "/opt/tappaas" } ]
}
JSON
cat > "${NEW}/environments/acme.json" <<'JSON'
{ "name": "acme", "displayName": "Acme Prod", "domains": { "primary": "acme.test", "dnsMode": "wildcard" }, "network": { "zone": "acme" } }
JSON
cat > "${NEW}/environments/staging.json" <<'JSON'
{ "name": "staging", "displayName": "Acme Staging", "domains": { "primary": "stg.acme.test", "dnsMode": "per-service" }, "network": { "zone": "staging" } }
JSON
cat > "${NEW}/cert-refids.json" <<'JSON'
{ "acme": "refacme01", "staging": "refstg02" }
JSON
# A configuration.json with DIFFERENT values, to prove site.json wins.
cat > "${NEW}/configuration.json" <<'JSON'
{ "tappaas": { "version": "old-v1", "email": "old@old.test", "snapshotRetention": 2, "automaticReboot": true,
    "domain": "old.test", "tlsCertRefid": "OLDREF",
    "variants": { "": { "domain": "old.test", "tlsCertRefid": "OLDREF" } },
    "repositories": [ { "name": "TAPPaaS", "path": "/old/path" } ] },
  "tappaas-nodes": [ { "hostname": "oldnode" } ] }
JSON

echo "== NEW sources present (site.json wins over configuration.json) =="
CONFIG_DIR="${NEW}"
eq "$(get_node_hostname 0)" "tappaas1" "node0 from site.json"
eq "$(get_node_hostname 2)" "tappaas3" "node2 from site.json"
eq "$(get_primary_node_fqdn)" "tappaas1.mgmt.internal" "primary fqdn"
eq "$(get_all_node_hostnames | paste -sd, -)" "tappaas1,tappaas2,tappaas3" "all nodes from site.json"
eq "$(get_default_ha_node tappaas1)" "tappaas2" "default ha node"
eq "$(snapshot_retention)" "9" "snapshotRetention from site.json"
if automatic_reboot_enabled; then bad "automaticReboot should be false (site.json)"; else ok "automaticReboot=false from site.json"; fi
eq "$(installer_email)" "admin@acme.test" "installer_email from site.json"
eq "$(get_site_value '.version' 'version')" "site-v2" "version from site.json"
eq "$(get_repo_path TAPPaaS)" "/opt/tappaas" "repo path from site.json"
eq "$(default_environment_name)" "acme" "default env name from site.json"
eq "$(cert_refid_for_env acme)" "refacme01" "refid acme from cert-refids.json"
eq "$(cert_refid_for_env staging)" "refstg02" "refid staging from cert-refids.json"
VCFG="$(get_variant_config "")"
eq "$(jq -r '.domain' <<<"$VCFG")" "acme.test" "default env domain"
eq "$(jq -r '.zone' <<<"$VCFG")" "acme" "default env zone"
eq "$(jq -r '.dnsMode' <<<"$VCFG")" "wildcard" "default env dnsMode"
eq "$(jq -r '.tlsCertRefid' <<<"$VCFG")" "refacme01" "default env refid (cert-refids.json)"
eq "$(jq -r '.description' <<<"$VCFG")" "Acme Prod" "default env description from displayName"
SCFG="$(get_variant_config staging)"
eq "$(jq -r '.domain' <<<"$SCFG")" "stg.acme.test" "named env domain"
eq "$(jq -r '.dnsMode' <<<"$SCFG")" "per-service" "named env dnsMode"
eq "$(jq -r '.tlsCertRefid' <<<"$SCFG")" "refstg02" "named env refid"

# ── Fixture 2: cert-refids.json ABSENT, env file present -> legacy refid fallback ─
NOCRF="${WORK}/nocrf"
mkdir -p "${NOCRF}/environments"
cp "${NEW}/site.json" "${NOCRF}/site.json"
cp "${NEW}/environments/acme.json" "${NOCRF}/environments/acme.json"
cat > "${NOCRF}/configuration.json" <<'JSON'
{ "tappaas": { "domain": "acme.test", "tlsCertRefid": "LEGACYREF",
    "variants": { "": { "domain": "acme.test", "tlsCertRefid": "LEGACYREF" } } } }
JSON
echo "== cert-refids.json absent -> refid falls back to configuration.json =="
CONFIG_DIR="${NOCRF}"
eq "$(cert_refid_for_env acme)" "LEGACYREF" "default-env refid falls back to configuration.json"
VCFG="$(get_variant_config "")"
eq "$(jq -r '.tlsCertRefid' <<<"$VCFG")" "LEGACYREF" "get_variant_config refid falls back"
eq "$(jq -r '.domain' <<<"$VCFG")" "acme.test" "domain still from env file"

# ── Fixture 3: site.json + environments ABSENT -> full configuration.json fallback ─
OLD="${WORK}/old"
mkdir -p "${OLD}"
cat > "${OLD}/configuration.json" <<'JSON'
{ "tappaas": { "version": "v9", "domain": "legacy.example.org", "email": "ops@legacy.org",
    "snapshotRetention": 7, "automaticReboot": true,
    "variants": { "": { "domain": "legacy.example.org", "tlsCertRefid": "deadbeef", "dnsMode": "wildcard" },
                  "bar": { "domain": "bar.example.org", "tlsCertRefid": "barref", "dnsMode": "per-service" } },
    "repositories": [ { "name": "TAPPaaS", "path": "/srv/tappaas" } ] },
  "tappaas-nodes": [ { "hostname": "nodeA" }, { "hostname": "nodeB" } ] }
JSON
echo "== site.json + environments absent -> configuration.json fallback =="
CONFIG_DIR="${OLD}"
eq "$(get_node_hostname 0)" "nodeA" "node0 from configuration.json"
eq "$(get_all_node_hostnames | paste -sd, -)" "nodeA,nodeB" "all nodes from configuration.json"
eq "$(get_default_ha_node nodeA)" "nodeB" "default ha node (fallback)"
eq "$(snapshot_retention)" "7" "snapshotRetention from configuration.json"
if automatic_reboot_enabled; then ok "automaticReboot=true from configuration.json"; else bad "automaticReboot should be true"; fi
eq "$(installer_email)" "ops@legacy.org" "installer_email from configuration.json"
eq "$(get_repo_path TAPPaaS)" "/srv/tappaas" "repo path from configuration.json"
eq "$(default_environment_name)" "legacy" "default env from domain label"
eq "$(cert_refid_for_env legacy)" "deadbeef" "default-env refid from variants[\"\"]"
VCFG="$(get_variant_config "")"
eq "$(jq -r '.domain' <<<"$VCFG")" "legacy.example.org" "default variant domain (fallback)"
eq "$(jq -r '.tlsCertRefid' <<<"$VCFG")" "deadbeef" "default variant refid (fallback)"
BCFG="$(get_variant_config bar)"
eq "$(jq -r '.domain' <<<"$BCFG")" "bar.example.org" "named variant domain (fallback)"
eq "$(jq -r '.dnsMode' <<<"$BCFG")" "per-service" "named variant dnsMode (fallback)"

# ── Fixture 4: nothing present -> safe bootstrap defaults ─────────────────────
EMPTY="${WORK}/empty"
mkdir -p "${EMPTY}"
echo "== nothing present -> bootstrap defaults =="
# CONFIG_DIR is read by the sourced helper functions, not directly here.
# shellcheck disable=SC2034
CONFIG_DIR="${EMPTY}"
eq "$(get_node_hostname 0)" "tappaas1" "node0 bootstrap default"
eq "$(get_all_node_hostnames)" "tappaas1" "all nodes bootstrap default"
eq "$(snapshot_retention)" "5" "snapshotRetention default"
if automatic_reboot_enabled; then ok "automaticReboot default enabled"; else bad "default should be enabled"; fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
