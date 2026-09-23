#!/usr/bin/env bash
#
# test-public-domain.sh — the one derivation of a module's public name (#715).
#
# There were eleven copies of "<vmname>.<environment domain>, unless proxyDomain
# says otherwise", and they disagreed. What that cost, measured on 2026-09-23:
#
#   - identity read only a top-level proxyDomain, so nextcloud — published at
#     cloud.hrossen.dk under config."network:proxy" — came out nextcloud.<domain>;
#   - identity ignored the legacy configuration.json, so on makerfloss (which has
#     one) logging, identity and network were "unpublished" while Caddy served
#     all three;
#   - the nix side saw only an explicit value: nextcloud.nix built an empty
#     trusted_domains (an HTTP 400 on the public route, on a site without an
#     explicit proxyDomain), and logging.nix never switched its SSO provider on
#     on either site, although Grafana is published on both.
#
# module_public_domain encodes the proxy's rules, because the proxy's are what
# Caddy reflects: the resolver matched all 13 published names on both sites'
# Caddyfiles. This suite pins those rules and the delivery to the nix side, and
# keeps the copies from growing back.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
# tappaas-cicd -> foundation -> src -> the repository root.
SRC_ROOT="$(cd "${CICD}/../../.." && pwd)"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

command -v jq >/dev/null 2>&1 || { echo "jq not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/public-domain.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
mkdir -p "${TMP}/environments"
echo '{"name":"site"}'                                      > "${TMP}/site.json"
echo '{"domains":{"primary":"example.org"}}'                > "${TMP}/environments/prod.json"
echo '{"domains":{"primary":"lab1.example.org"}}'           > "${TMP}/environments/lab1.json"
echo '{}'                                                   > "${TMP}/environments/mgmt.json"

export CONFIG_DIR="${TMP}"
# shellcheck source=../../lib/common-install-routines.sh disable=SC1091
set --
. "${CICD}/lib/common-install-routines.sh" >/dev/null 2>&1
declare -F module_public_domain >/dev/null || { echo "  FAIL: module_public_domain not defined"; exit 1; }

r() { module_public_domain "$@"; }

# ── the rules ───────────────────────────────────────────────────────────────
ck "derived: <vmname>.<environment domain>" \
   "logging.example.org" "$(r logging prod '{}')"
ck "an explicit proxyDomain under config.\"network:proxy\" wins (Pattern A)" \
   "cloud.example.org" "$(r nextcloud prod '{"config":{"network:proxy":{"proxyDomain":"cloud.example.org"}}}')"
ck "…and so does a top-level one (flattened)" \
   "cloud.example.org" "$(r nextcloud prod '{"proxyDomain":"cloud.example.org"}')"
ck "a Pattern-A value that differs from the derived name is not ignored" \
   "lab1.example.org" "$(r podman-lab1 lab1 '{"config":{"network:proxy":{"proxyDomain":"lab1.example.org"}}}')"
ck "an environment with no domain publishes nothing" \
   "" "$(r logging mgmt '{}')"
# The proxy skips such a module before it ever reads proxyDomain, so nothing
# is published under that name either.
ck "…even when a proxyDomain is written down" \
   "" "$(r logging mgmt '{"proxyDomain":"logging.example.org"}')"
ck "no json at all still derives" \
   "logging.example.org" "$(r logging prod)"
ck "no vmname and no explicit name gives nothing" \
   "" "$(r '' prod '{}')"

# ── the legacy fallback, which makerfloss still depends on ──────────────────
echo '{"tappaas":{"domain":"legacy.example.net"}}' > "${TMP}/configuration.json"
ck "no environment domain + a legacy configuration.json → the legacy domain" \
   "logging.legacy.example.net" "$(r logging mgmt '{}')"
ck "an environment domain still beats the legacy one" \
   "logging.example.org" "$(r logging prod '{}')"
rm -f "${TMP}/configuration.json"

# ── delivery to the nix side ────────────────────────────────────────────────
declare -F with_public_domain >/dev/null || { echo "  FAIL: with_public_domain not defined"; exit 1; }
f="${TMP}/logging.json"
echo '{"vmname":"logging","environment":"prod","dependsOn":["cluster:vm","network:proxy"]}' > "$f"
with_public_domain logging "$f"
ck "a proxied module's companion JSON gets its public name" \
   "logging.example.org" "$(jq -r '.proxyDomain // "none"' "$f")"
ck "…and stays valid JSON with nothing else changed" \
   '["cluster:vm","network:proxy"]' "$(jq -c '.dependsOn' "$f")"

f="${TMP}/nextcloud.json"
echo '{"vmname":"nextcloud","environment":"prod","dependsOn":["network:proxy"],"proxyDomain":"cloud.example.org"}' > "$f"
with_public_domain nextcloud "$f"
ck "an explicit name is kept, not overwritten by the derived one" \
   "cloud.example.org" "$(jq -r '.proxyDomain' "$f")"

f="${TMP}/unproxied.json"
echo '{"vmname":"backup","environment":"prod","dependsOn":["cluster:vm"]}' > "$f"
with_public_domain backup "$f"
ck "a module network:proxy does not publish gets no name" \
   "none" "$(jq -r '.proxyDomain // "none"' "$f")"

f="${TMP}/internal.json"
echo '{"vmname":"logging","environment":"mgmt","dependsOn":["network:proxy"]}' > "$f"
with_public_domain logging "$f"
ck "nor does one whose environment publishes nothing" \
   "none" "$(jq -r '.proxyDomain // "none"' "$f")"

# ── a name is not a published route (#715) ─────────────────────────────────
# with_public_domain also records whether network:proxy SERVES the name, from
# the one resolver (network-manager split-horizon-target). Stubbed here: 0 is
# published, 1 resolves publicly on a site with no dmz zone, 3 has no public
# record, and no resolver at all leaves the flag out.
NMBIN="${TMP}/nmbin"; mkdir -p "${NMBIN}"
printf '#!/usr/bin/env bash\n[[ "$1" == split-horizon-target ]] || exit 99\nexit "${NM_RC:-0}"\n' > "${NMBIN}/network-manager"
chmod +x "${NMBIN}/network-manager"
pubflag() {  # <rc or "none"> → the stamped .proxyPublished, "absent" when not written
    local f="${TMP}/flag.json"
    echo '{"vmname":"logging","environment":"prod","dependsOn":["network:proxy"],"proxyPublished":"stale"}' > "$f"
    if [[ "$1" == none ]]; then
        ( PATH="$(printf '%s' "${PATH}" | tr ':' '\n' | grep -v "^${NMBIN}$" | paste -sd: -)"
          hash -r; command -v network-manager >/dev/null && exit 0; with_public_domain logging "$f" )
    else
        ( PATH="${NMBIN}:${PATH}" NM_RC="$1"; export NM_RC; with_public_domain logging "$f" )
    fi
    jq -r 'if has("proxyPublished") then (.proxyPublished|tostring) else "absent" end + " " + .proxyDomain' "$f"
}
ck "served (0): named, and marked published"                 "true logging.example.org"  "$(pubflag 0)"
ck "no public record (3): named, and marked NOT published"   "false logging.example.org" "$(pubflag 3)"
ck "resolves publicly, no dmz zone (1): still published"      "true logging.example.org"  "$(pubflag 1)"
if command -v network-manager >/dev/null 2>&1; then
    echo "  (skip: a real network-manager is on PATH — cannot test its absence here)"
else
    ck "no resolver: the flag is not written (and a stale one is dropped)" "absent logging.example.org" "$(pubflag none)"
fi
grep -q 'moduleCfg.proxyPublished or true' "${SRC_ROOT}/src/foundation/logging/logging.nix" \
    && ck "logging.nix gates Grafana's published mode on it" "yes" "yes" \
    || ck "logging.nix gates Grafana's published mode on it" "yes" "no"

# ── the copies stay gone ────────────────────────────────────────────────────
# Any shell script building "<vmname>.<some domain>" for a public name outside
# the resolver is the problem coming back. The pattern is any variable naming a
# VM, a dot, any variable naming a domain: the first version of this guard
# listed the domain variables it knew, and missed ${_nc_vm}.${_nc_dom} in
# nextcloud-hpb and ${VMNAME}.${_base_domain} in litellm.
# Allowed: the fileservice fallback that fires only when nothing is published
# (${NC_PROXY:-…}, ${EO_PROXY:-…}), and INTERNAL names — the network:dns and
# cluster:vm services register <vmname>.<zone>.internal, whose domain variable
# is assigned "${ZONE}.internal" two lines up.
copies="$(cd "${SRC_ROOT}" && grep -rnE '\$\{?[A-Za-z_]*(vm|VM)[A-Za-z_]*\}?\.\$\{?[A-Za-z_]*(dom|DOM)[A-Za-z_]*\}?' \
            --include='*.sh' src 2>/dev/null \
            | grep -v '_PROXY:-' | grep -v '/test-public-domain.sh:' \
            | grep -v '^src/foundation/network/services/dns/' \
            | grep -v '^src/foundation/cluster/services/vm/update-service.sh:')"
ck "no public-name derivation outside module_public_domain" "" "${copies}"
[[ -n "${copies}" ]] && sed 's/^/      /' <<< "${copies}"

# The update path must deliver it, or the nix side is back to guessing.
ck "update-os.sh delivers the name to the companion JSON" "1" \
   "$(grep -c 'with_public_domain "${vmname}" "${_flat_tmp}"' "${CICD}/manager/health-manager/update-os.sh")"

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
