#!/usr/bin/env bash
#
# test-variant-public.sh — environment architecture end-to-end test (ADR-007).
#
# Self-contained: creates an environment WITH a dedicated zone, installs the
# test provider in BOTH the default environment and the named environment
# (coexistence), installs a consumer in the environment whose dependency must
# resolve to the environment provider, validates Caddy + split-horizon for the
# environment domain, then tears it ALL down (VMs, zone, firewall trunks,
# environment file). The legacy ADR-005 variant registry is retired — the
# "variant" naming below is just the environment name.
#
# Trunk handling uses the SAME safe mechanism as firewall/update.sh
# (vmnet_resolve_trunks "ALL" -> qm set --net0, preserving MAC/queues) — NOT the
# broken legacy --deep logic (see ISSUES/deep-test-trunk-and-nixbuild.md).
#
# Gate (skips unless met): public DNS for <provider>.<variant-domain> resolves to
# a public IP (you set up *.test3.tapaas.org -> your WAN). Variant uses
# dnsMode=per-service, so Caddy issues the cert via HTTP-01 (no acme-setup needed)
# and firewall:proxy registers the per-service Unbound split-horizon override.
#
# Usage: ./test-variant-public.sh [--no-cleanup]
#

# `<cmd> && pass || fail` is used throughout; pass()/fail() always return 0, so
# the SC2015 "not if-then-else" caveat cannot misfire here.
# shellcheck disable=SC2015
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly FIX="${SCRIPT_DIR}/test-fixtures"

# shellcheck source=../tappaas-cicd/lib/common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../cluster/lib/vm-net.sh disable=SC1091
. /home/tappaas/TAPPaaS/src/foundation/cluster/lib/vm-net.sh

readonly VARIANT="tv"
readonly VARIANT_DOMAIN="test3.tapaas.org"
readonly PROVIDER="test-var-prov"
readonly CONSUMER="test-var-cons"
readonly PROV_MARKER="tappaas-var-prov-ok"
readonly ZONES_JSON="${CONFIG_DIR}/zones.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
readonly ENV_FILE="${CONFIG_DIR}/environments/${VARIANT}.json"

NO_CLEANUP=0
[[ "${1:-}" == "--no-cleanup" ]] && NO_CLEANUP=1

PASS=0
FAIL=0
pass() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }

is_public_ip() {
    local ip="$1"
    [[ -n "${ip}" ]] || return 1
    case "${ip}" in 10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;; esac
    return 0
}

curl_marker() {
    local fqdn="$1" ip="$2" label="$3"
    for _ in 1 2 3 4 5 6 7 8; do
        if curl -fsS --max-time 12 --resolve "${fqdn}:443:${ip}" "https://${fqdn}/" 2>/dev/null | grep -q "${PROV_MARKER}"; then
            pass "${label}: https://${fqdn} via ${ip} returned the marker"
            return 0
        fi
        sleep 12
    done
    fail "${label}: no marker from https://${fqdn} via ${ip} after retries"
}

# Sync the firewall VM's Proxmox net0 trunks to ALL active zones (current
# zones.json) — the SAFE update.sh mechanism: preserves MAC/queues/tag, only
# rewrites trunks. Called after the variant zone is (de)activated.
sync_fw_trunks() {
    local fw_vmid fw_bridge primary fw_node desired live_net0 mac trunks tag queues opts
    fw_vmid=$(jq -r '.vmid // empty' "${FIREWALL_JSON}")
    fw_bridge=$(jq -r '.bridge0 // "lan"' "${FIREWALL_JSON}")
    primary=$(get_primary_node_fqdn 2>/dev/null || echo "tappaas1.mgmt.internal")
    fw_node=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@"${primary}" \
        "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
         | jq -r --arg v \"${fw_vmid}\" '.[] | select(.vmid==(\$v|tonumber)) | .node'" 2>/dev/null | head -1)
    desired=$(vmnet_resolve_trunks "ALL" "${ZONES_JSON}")
    if [[ -z "${fw_node}" || -z "${fw_vmid}" || -z "${desired}" ]]; then
        warn "  trunk-sync: could not resolve firewall vmid/node/trunks — skipping"
        return 1
    fi
    live_net0=$(ssh -o BatchMode=yes root@"${fw_node}.mgmt.internal" "qm config ${fw_vmid}" 2>/dev/null \
        | awk -F': ' '/^net0:/ {print $2; exit}')
    mac=$(vmnet_parse "${live_net0}" mac)
    trunks=$(vmnet_parse "${live_net0}" trunks)
    tag=$(vmnet_parse "${live_net0}" tag)
    queues=$(vmnet_parse "${live_net0}" queues)
    [[ -n "${mac}" ]] || { warn "  trunk-sync: no MAC — skipping"; return 1; }
    if [[ "${trunks}" == "${desired}" ]]; then
        info "  trunk-sync: net0 already in sync (${desired})"
        return 0
    fi
    opts=$(vmnet_build_netopts "${fw_bridge}" "${mac}" "${tag}" "${desired}" "${queues}")
    if ssh -o BatchMode=yes root@"${fw_node}.mgmt.internal" "qm set ${fw_vmid} --net0 '${opts}'" >/dev/null 2>&1; then
        info "  trunk-sync: net0 trunks ${trunks:-none} -> ${desired}"
        return 0
    fi
    warn "  trunk-sync: qm set --net0 failed"
    return 1
}

cleanup() {
    local rc=$?
    [[ "${NO_CLEANUP}" -eq 1 ]] && { warn "Skipping cleanup (--no-cleanup)."; return "${rc}"; }
    echo ""
    info "${BOLD}─── Variant test teardown ───${CL}"
    for m in "${CONSUMER}-${VARIANT}" "${PROVIDER}-${VARIANT}" "${PROVIDER}"; do
        [[ -f "${CONFIG_DIR}/${m}.json" ]] && /home/tappaas/bin/delete-module.sh "${m}" --force >/dev/null 2>&1 \
            && info "  deleted ${m}" || true
    done
    # Remove leftover per-service Unbound override (delete-service handles the
    # normal path; this catches a mid-failure).
    unbound-manager --no-ssl-verify delete "${PROVIDER}" "${VARIANT_DOMAIN}" >/dev/null 2>&1 || true
    # Remove the environment file and its dedicated zone, then restore firewall trunks.
    rm -f "${ENV_FILE}" 2>/dev/null && info "  removed environment ${VARIANT}" || true
    /home/tappaas/bin/zone-controller delete "${VARIANT}" --apply >/dev/null 2>&1 \
        && info "  removed environment zone '${VARIANT}' + reconciled OPNsense" || true
    sync_fw_trunks || true
    return "${rc}"
}

info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
info "${BOLD}║  Variant E2E test: ${BL}${VARIANT}${CL} (${VARIANT_DOMAIN})"
info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

# ── Gate (before creating anything) ──────────────────────────────────
PROXY_FQDN="${PROVIDER}.${VARIANT_DOMAIN}"
PUBLIC_IP="$(dig +short @1.1.1.1 A "${PROXY_FQDN}" 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)"
if ! is_public_ip "${PUBLIC_IP}"; then
    warn "SKIP: public DNS for ${PROXY_FQDN} did not resolve to a public IP (got '${PUBLIC_IP:-none}')."
    warn "      Set up *.${VARIANT_DOMAIN} -> your WAN IP, then re-run."
    exit 0
fi
DMZ_GW="$(dmz_gateway_ip 2>/dev/null || echo '')"
info "  Variant FQDN: ${BL}${PROXY_FQDN}${CL}   public IP: ${BL}${PUBLIC_IP}${CL}   DMZ gw: ${BL}${DMZ_GW:-?}${CL}"

trap cleanup EXIT

# ── Step 1: create dedicated zone + author the environment file ──────
info "${BOLD}Step 1: zone-controller add ${VARIANT} + author environment ${VARIANT}${CL}"
if /home/tappaas/bin/zone-controller add "${VARIANT}" --from-zone srvWork --variant "${VARIANT}"; then
    pass "environment zone '${VARIANT}' created"
else
    fail "zone-controller add ${VARIANT} failed"
    exit 1
fi
# Author the environment file (domains.primary + per-service dnsMode + zone). The
# legacy variant registry is retired — environments are the source of truth.
mkdir -p "$(dirname "${ENV_FILE}")"
ENV_OWNER="$(jq -r '.owner // empty' "${CONFIG_DIR}/site.json" 2>/dev/null)"
[[ -n "${ENV_OWNER}" ]] || ENV_OWNER="$(ls "${CONFIG_DIR}/people/organizations"/*.json 2>/dev/null | head -1 | xargs -r basename | sed 's/\.json$//')"
if jq -n --arg n "${VARIANT}" --arg owner "${ENV_OWNER}" --arg d "${VARIANT_DOMAIN}" --arg z "${VARIANT}" '
        { name: $n, displayName: $n, ownerOrg: $owner,
          domains: { primary: $d, dnsMode: "per-service" },
          network: { zone: $z } }' > "${ENV_FILE}"; then
    pass "environment ${VARIANT} authored (${VARIANT_DOMAIN}, dnsMode per-service, zone ${VARIANT})"
else
    fail "could not author environment file ${ENV_FILE}"
    exit 1
fi
ZTAG="$(jq -r --arg z "${VARIANT}" '.[$z].vlantag // empty' "${ZONES_JSON}")"
ZSTATE="$(jq -r --arg z "${VARIANT}" '.[$z].state // empty' "${ZONES_JSON}")"
if [[ "${ZSTATE}" == "Active" && -n "${ZTAG}" ]]; then
    pass "variant zone '${VARIANT}' Active with VLAN ${ZTAG}"
else
    fail "variant zone '${VARIANT}' not Active (state=${ZSTATE} vlan=${ZTAG})"
fi

# ── Step 2: sync firewall trunks so the variant VLAN passes (DHCP) ───
info "${BOLD}Step 2: sync firewall net0 trunks (include VLAN ${ZTAG})${CL}"
sync_fw_trunks && pass "firewall trunks include the variant VLAN" || fail "trunk sync failed"

# ── Step 3+4: provider in default variant AND in the variant (coexist) ─
info "${BOLD}Step 3: install ${PROVIDER} (default variant)${CL}"
( cd "${FIX}/${PROVIDER}" && /home/tappaas/bin/install-module.sh "${PROVIDER}" ) \
    && pass "installed ${PROVIDER} (base)" || fail "install ${PROVIDER} (base) failed"

info "${BOLD}Step 4: install ${PROVIDER} --environment ${VARIANT}${CL}"
( cd "${FIX}/${PROVIDER}" && /home/tappaas/bin/install-module.sh "${PROVIDER}" --environment "${VARIANT}" ) \
    && pass "installed ${PROVIDER}-${VARIANT} (environment)" || fail "install ${PROVIDER}-${VARIANT} failed"

# Coexistence assertions
base_cfg="${CONFIG_DIR}/${PROVIDER}.json"
var_cfg="${CONFIG_DIR}/${PROVIDER}-${VARIANT}.json"
if [[ -f "${base_cfg}" && -f "${var_cfg}" ]]; then
    bvid="$(jq -r '.vmid' "${base_cfg}")"; vvid="$(jq -r '.vmid' "${var_cfg}")"
    bzone="$(jq -r '.zone0' "${base_cfg}")"; vzone="$(jq -r '.zone0' "${var_cfg}")"
    [[ "${bvid}" != "${vvid}" ]] && pass "coexist: distinct vmids (base ${bvid}, variant ${vvid})" || fail "coexist: same vmid"
    [[ "${vzone}" == "${VARIANT}" && "${bzone}" == "srvWork" ]] \
        && pass "coexist: base in ${bzone}, variant in ${vzone}" || fail "coexist: zones base=${bzone} variant=${vzone}"
    if vm_exists_on_cluster "${bvid}" "$(jq -r '.node//"tappaas1"' "${base_cfg}").mgmt.internal" >/dev/null 2>&1 \
       && vm_exists_on_cluster "${vvid}" "$(jq -r '.node//"tappaas1"' "${var_cfg}").mgmt.internal" >/dev/null 2>&1; then
        pass "coexist: both provider VMs exist on the cluster"
    else
        fail "coexist: one of the provider VMs is missing"
    fi
else
    fail "coexist: base and/or variant provider config missing"
fi

# Dependency resolution is variant-preferring (deterministic).
resolved="$(resolve_provider_module "${PROVIDER}" "${VARIANT}")"
[[ "${resolved}" == "${PROVIDER}-${VARIANT}" ]] \
    && pass "dep resolution: ${PROVIDER} + ${VARIANT} -> ${resolved} (variant)" \
    || fail "dep resolution: got '${resolved}', expected ${PROVIDER}-${VARIANT}"

# ── Step 5: consumer in the environment — dep must resolve to the env provider ─
info "${BOLD}Step 5: install ${CONSUMER} --environment ${VARIANT} (dep -> ${PROVIDER}-${VARIANT})${CL}"
if ( cd "${FIX}" && /home/tappaas/bin/install-module.sh "${CONSUMER}" --environment "${VARIANT}" ); then
    pass "installed ${CONSUMER}-${VARIANT} (environment dependency resolved + provisioned)"
    cons_cfg="${CONFIG_DIR}/${CONSUMER}-${VARIANT}.json"
    [[ "$(jq -r '.environment' "${cons_cfg}" 2>/dev/null)" == "${VARIANT}" ]] \
        && pass "consumer config records environment=${VARIANT}" || fail "consumer environment field wrong"
else
    fail "install ${CONSUMER}-${VARIANT} failed (variant dependency did not resolve/provision)"
fi

# ── Step 6: Caddy external + split-horizon for the variant domain ────
info "${BOLD}Step 6: Caddy public + split-horizon for ${PROXY_FQDN}${CL}"
curl_marker "${PROXY_FQDN}" "${PUBLIC_IP}" "external"
INTERNAL_IP="$(getent hosts "${PROXY_FQDN}" 2>/dev/null | awk '{print $1}' | head -1)"
[[ -n "${DMZ_GW}" && "${INTERNAL_IP}" == "${DMZ_GW}" ]] \
    && pass "split-horizon: ${PROXY_FQDN} -> ${DMZ_GW} (Unbound per-service override)" \
    || fail "split-horizon: ${PROXY_FQDN} is '${INTERNAL_IP:-none}', expected ${DMZ_GW:-?}"
curl_marker "${PROXY_FQDN}" "${DMZ_GW:-${INTERNAL_IP}}" "internal"

# ── Summary ──────────────────────────────────────────────────────────
info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
[[ "${FAIL}" -eq 0 ]]
