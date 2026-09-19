#!/usr/bin/env bash
#
# test.sh — tests for network-manager (ADR-007 P4 / ADR-008).
#
# Two tiers (fast/deep per tappaas-cicd/README.md):
#   FAST (default, offline) — no cluster, no controllers:
#     A. legacy bash entry scripts parse (bash -n)
#     B. TypeScript: tsc --noEmit clean (src), unit tests compile + pass
#        (FakePlaneClient + temp zones.json fixture): zone CRUD, 4-plane
#        reconcile order/flags, the switch-plane-on-add #372/#373 fix, per-plane
#        rc aggregation, dry-run mutates nothing.
#   DEEP (TAPPAAS_TEST_DEEP=1) — a live reconcile dry-run against the real
#     planes; SKIPS gracefully if network-manager isn't built or the planes are
#     unreachable. It does NOT provision VMs or mutate zones (the live gate is a
#     later chunk).
#
# Prints "Results: N passed, M failed"; exits 1 on any failure.
#
set -uo pipefail

# Accept --deep as well as TAPPAAS_TEST_DEEP=1. Every gate below reads the
# variable, so exporting it here is all a flag needs to do — and exporting (not
# just setting) is what carries it into any suite this one dispatches. Without
# this, `test.sh --deep` silently ran the fast path.
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && export TAPPAAS_TEST_DEEP=1; done


HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
ok()  { echo "  ok: $*";   PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

run_ts() {
    # Prefer a tsc/node already on PATH, else nix-shell.
    if command -v tsc >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
        bash -c "$1"
    elif command -v nix-shell >/dev/null 2>&1; then
        nix-shell -p typescript nodejs_22 --run "$1"
    else
        return 127
    fi
}

# ── A. legacy bash entry scripts parse ────────────────────────────────
echo "== network-manager: legacy bash entry scripts parse =="
for f in "${HERE}/zone-reconcile"; do
    b="$(basename "${f}")"
    if bash -n "${f}" 2>/dev/null; then ok "${b} parses"; else bad "${b} parse error"; fi
done

# ── B. TypeScript: type-check src + run offline unit tests ────────────
echo ""
echo "== network-manager: TypeScript unit tests (offline; FakePlaneClient) =="

UNIT_TSCONFIG="${HERE}/test/unit/tsconfig.json"
DIST_TEST="${HERE}/dist-test"
FIXTURE_DIR="${HERE}/test/fixtures"

if [[ -f "${UNIT_TSCONFIG}" ]]; then
    rm -rf -- "${DIST_TEST}"
    if run_ts "tsc --noEmit -p '${HERE}/tsconfig.json'" >/dev/null 2>&1; then
        ok "tsc --noEmit clean (src)"
    else
        bad "tsc --noEmit reported type errors (src)"
    fi
    if run_ts "tsc -p '${UNIT_TSCONFIG}'" >/dev/null 2>&1; then
        ok "TypeScript unit tests compile"
        if run_ts "NM_FIXTURE_DIR='${FIXTURE_DIR}' NM_TEMPLATE='${HERE}/zones.json' node '${DIST_TEST}/manager/network-manager/test/unit/network.test.js'"; then
            ok "TypeScript reconcile/CRUD/init unit tests pass"
        else
            bad "TypeScript unit tests FAILED"
        fi

        # ── init CLI smoke (offline; temp --out, never live config) ──
        # The unit tsconfig compiles src/ into dist-test/manager/network-manager/src
        # (rootDir is the tappaas-cicd root, shared lib/ts included); run the real CLI
        # entry against a temp output and assert the transformed file on disk.
        ZINIT_OUT="$(mktemp -d)/z.json"
        # Isolate --config-dir to an empty dir so the occupancy scan finds no tenants
        # (the default configDir is the LIVE config).
        ZINIT_CFG="$(mktemp -d)"
        # ADR-014 D7: `init core` emits exactly the core set — renamed srv -> acme
        # (Active), home/guest kept, dmz Mandatory — and ships NO IoT or test zones
        # and none of the retired srv* zones. home's service edge is DERIVED from
        # `serves`, so the authored access-to must NOT list acme.
        if run_ts "NM_TEMPLATE='${HERE}/zones.json' node '${DIST_TEST}/manager/network-manager/src/main.js' init core --name acme --from '${HERE}/zones.json' --out '${ZINIT_OUT}' --config-dir '${ZINIT_CFG}'" >/dev/null 2>&1 \
            && [[ -f "${ZINIT_OUT}" ]] \
            && run_ts "node -e 'const z=require(\"${ZINIT_OUT}\"); const gone=[\"srv\",\"srvHome\",\"srvWork\",\"srvCust\",\"srvDev\",\"srvTest\",\"work\",\"iot\",\"test\",\"testAllowA\",\"testAllowB\",\"testPinhole\",\"iotLocal\",\"iotCloud\",\"iotCams\",\"iotUntrust\"]; const ok = z.acme&&z.home&&z.guest&&z.dmz&&z.mgmt&&z.acme.state===\"Active\"&&z.home.serves===\"acme\"&&!z.home[\"access-to\"].includes(\"acme\")&&gone.every(k=>!(k in z))&&!(\"_profiles\" in z); process.exit(ok?0:1)'" >/dev/null 2>&1; then
            ok "init core CLI: exact core set, srv->acme Active, serves-bound home, no iot/test/legacy zones"
        else
            bad "init CLI smoke FAILED"
        fi

        # ── init iot composes on top (offline) ──
        if run_ts "NM_TEMPLATE='${HERE}/zones.json' node '${DIST_TEST}/manager/network-manager/src/main.js' init iot --name acme --from '${HERE}/zones.json' --out '${ZINIT_OUT}' --config-dir '${ZINIT_CFG}'" >/dev/null 2>&1 \
            && run_ts "node -e 'const z=require(\"${ZINIT_OUT}\"); const ok = z.iotLocal&&z.iotCloud&&z.iotCams&&z.iotUntrust&&z.acme&&z.home&&z.iotUntrust.state===\"Active\"&&z.acme[\"access-to\"].includes(\"iotLocal\")&&z.acme[\"access-to\"].includes(\"iotCloud\")&&z.mgmt[\"access-to\"].includes(\"iotCams\")&&z.iotCams.isolated===true; process.exit(ok?0:1)'" >/dev/null 2>&1; then
            ok "init iot CLI: composes onto core, adds the 4 IoT zones + the grants they need"
        else
            bad "init iot compose FAILED"
        fi
        # Design A: init also seeds zones.rename.json + zones.json.orig
        # beside a custom --out, all in the renamed namespace (current==orig==rename).
        # Design A, re-cut for D7: the merge SOURCE/baseline are the FULL renamed
        # template (every zone the release ships, whichever profiles are installed)
        # — so rename == orig, and the live zones.json is the installed SUBSET.
        # If the source were profile-scoped, a field fix to an uninstalled zone
        # could never be adopted later.
        ZINIT_DIR="$(dirname "${ZINIT_OUT}")"
        if [[ -f "${ZINIT_DIR}/zones.rename.json" && -f "${ZINIT_DIR}/zones.json.orig" ]] \
            && run_ts "node -e 'const fs=require(\"fs\");const r=fs.readFileSync(\"${ZINIT_DIR}/zones.rename.json\",\"utf8\");const o=fs.readFileSync(\"${ZINIT_DIR}/zones.json.orig\",\"utf8\");const rj=JSON.parse(r);const cur=JSON.parse(fs.readFileSync(\"${ZINIT_OUT}\",\"utf8\"));const curZones=Object.keys(cur).filter(k=>!k.startsWith(\"_\"));process.exit((r===o&&rj.acme&&!rj.srv&&curZones.every(k=>k in rj))?0:1)'" >/dev/null 2>&1; then
            ok "init seeds zones.rename.json == zones.json.orig (full renamed template; live doc is a subset)"
        else
            bad "init 3-file seeding (Design A) FAILED"
        fi
        rm -rf -- "${ZINIT_DIR}" "${ZINIT_CFG}"

        # ── merge CLI smoke (offline; Design A; never live config) ──
        # On a fresh renamed install (current==orig==rename), a merge must NOT
        # re-introduce srv (home/guest are kept site-local role zones, #425) and
        # must produce no duplicate vlantags.
        ZM_DIR="$(mktemp -d)"
        printf '{ "name": "acme" }\n' > "${ZM_DIR}/site.json"
        run_ts "NM_TEMPLATE='${HERE}/zones.json' node '${DIST_TEST}/manager/network-manager/src/main.js' init --name acme --from '${HERE}/zones.json' --out '${ZM_DIR}/zones.json' --config-dir '${ZM_DIR}'" >/dev/null 2>&1
        if run_ts "NM_TEMPLATE='${HERE}/zones.json' node '${DIST_TEST}/manager/network-manager/src/main.js' merge --config-dir '${ZM_DIR}' --template '${HERE}/zones.json'" >/dev/null 2>&1 \
            && run_ts "node -e 'const z=require(\"${ZM_DIR}/zones.json\");const dup=Object.entries(z).filter(([k,v])=>v&&typeof v===\"object\"&&!Array.isArray(v)&&typeof v.vlantag===\"number\"&&v.vlantag>0).reduce((m,[k,v])=>{m[v.vlantag]=(m[v.vlantag]||0)+1;return m;},{});const hasDup=Object.values(dup).some(n=>n>1);process.exit((!z.srv&&z.home&&z.guest&&z.acme&&!hasDup)?0:1)'" >/dev/null 2>&1; then
            ok "merge CLI: fresh renamed install does NOT re-add srv; keeps home/guest; no duplicate vlantags"
        else
            bad "merge CLI smoke FAILED (re-added a renamed-away zone or created a duplicate vlantag)"
        fi
        rm -rf -- "${ZM_DIR}"

        # ── zones-check CLI smoke (offline; temp fixtures, never live config) ──
        # Good fixture (the distributed template, default-active mgmt) exits 0;
        # a fixture with a dangling access-to ref exits non-zero. The temp
        # config-dir holds only zones.json so the installation check is a no-op.
        # The raw template is NOT a valid live config: `srv` is pre-rename and its
        # `serves` placeholders name an environment that only exists after init.
        # Build a real one — init core, plus the environment its zones are bound to.
        ZC_DIR="$(mktemp -d)"
        mkdir -p "${ZC_DIR}/environments"
        printf '{"name":"acme","displayName":"Acme","ownerOrg":"o","network":{"zone":"acme"}}\n' \
            > "${ZC_DIR}/environments/acme.json"
        run_ts "NM_TEMPLATE='${HERE}/zones.json' node '${DIST_TEST}/manager/network-manager/src/main.js' init core --name acme --from '${HERE}/zones.json' --out '${ZC_DIR}/zones.json' --config-dir '${ZC_DIR}'" >/dev/null 2>&1
        if run_ts "node '${DIST_TEST}/manager/network-manager/src/main.js' zones-check --zones '${ZC_DIR}/zones.json' --config-dir '${ZC_DIR}'" >/dev/null 2>&1; then
            ok "zones-check CLI exits 0 on a well-formed zones.json"
        else
            bad "zones-check CLI unexpectedly failed on a good fixture"
        fi
        # Inject a dangling access-to ref → must exit non-zero.
        ZC_BAD_DIR="$(mktemp -d)"
        run_ts "node -e 'const fs=require(\"fs\");const z=JSON.parse(fs.readFileSync(\"${ZC_DIR}/zones.json\",\"utf8\"));z.dmz[\"access-to\"].push(\"nosuchzone\");fs.writeFileSync(\"${ZC_BAD_DIR}/zones.json\",JSON.stringify(z));'" >/dev/null 2>&1
        if run_ts "node '${DIST_TEST}/manager/network-manager/src/main.js' zones-check --zones '${ZC_BAD_DIR}/zones.json' --config-dir '${ZC_BAD_DIR}'" >/dev/null 2>&1; then
            bad "zones-check CLI did NOT fail on a dangling reference"
        else
            ok "zones-check CLI exits non-zero on a dangling access-to reference"
        fi
        rm -rf -- "${ZC_DIR}" "${ZC_BAD_DIR}"

        # ── distribute CLI smoke (offline; NO real scp) ─────────────
        # --dry-run lists the configured node targets from a fixture
        # configuration.json without scp'ing. A sentinel scp bin proves no
        # scp runs (its marker file must stay absent).
        ZD_DIR="$(mktemp -d)"
        cp "${HERE}/zones.json" "${ZD_DIR}/zones.json"
        cat > "${ZD_DIR}/configuration.json" <<'JSON'
{ "tappaas-nodes": [ { "hostname": "tappaas1" }, { "hostname": "tappaas2" } ] }
JSON
        ZD_MARKER="${ZD_DIR}/scp-was-run"
        printf '#!/usr/bin/env bash\ntouch %q\nexit 0\n' "${ZD_MARKER}" > "${ZD_DIR}/scp"
        chmod +x "${ZD_DIR}/scp"
        ZD_OUT="$(run_ts "CONFIG_DIR='${ZD_DIR}' NM_SCP_BIN='${ZD_DIR}/scp' node '${DIST_TEST}/manager/network-manager/src/main.js' distribute --zones '${ZD_DIR}/zones.json' --dry-run" 2>&1)"
        if echo "${ZD_OUT}" | grep -q "root@tappaas1.mgmt.internal:/root/tappaas/zones.json" \
            && echo "${ZD_OUT}" | grep -q "root@tappaas2.mgmt.internal:/root/tappaas/zones.json" \
            && [[ ! -f "${ZD_MARKER}" ]]; then
            ok "distribute --dry-run enumerates node targets without scp"
        else
            bad "distribute --dry-run did not list targets (or invoked scp)"
        fi

        # init to a TEMP --out (non-live) must NOT distribute → no scp.
        ZD_INIT_OUT="${ZD_DIR}/init.json"
        run_ts "CONFIG_DIR='${ZD_DIR}' NM_SCP_BIN='${ZD_DIR}/scp' NM_TEMPLATE='${HERE}/zones.json' node '${DIST_TEST}/manager/network-manager/src/main.js' init --name acme --from '${HERE}/zones.json' --out '${ZD_INIT_OUT}'" >/dev/null 2>&1
        if [[ -f "${ZD_INIT_OUT}" && ! -f "${ZD_MARKER}" ]]; then
            ok "init to a temp --out writes the file but does NOT scp (non-live auto-skip)"
        else
            bad "init to a temp --out attempted scp (should auto-skip non-live)"
        fi
        rm -rf -- "${ZD_DIR}"

        # `network-manager wgvpn <sub> …` hands the whole argument list to the
        # admin VPN tool, past this CLI's own option gate (ADR-010 §8.4.6): a
        # fake bin records what it received and its exit code comes back.
        WG_DIR="$(mktemp -d)"
        printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s/args"\nexit 7\n' "${WG_DIR}" > "${WG_DIR}/wgvpn"
        chmod +x "${WG_DIR}/wgvpn"
        rc=0
        run_ts "NM_WGVPN_BIN='${WG_DIR}/wgvpn' node '${DIST_TEST}/manager/network-manager/src/main.js' wgvpn add-peer --name laptop --pubkey K=" >/dev/null 2>&1 || rc=$?
        if [[ "${rc}" -eq 7 && "$(cat "${WG_DIR}/args" 2>/dev/null)" == "add-peer --name laptop --pubkey K=" ]]; then
            ok "wgvpn: hands its sub-verb and options to the admin VPN tool, and returns its exit code"
        else
            bad "wgvpn: rc=${rc} args='$(cat "${WG_DIR}/args" 2>/dev/null)'"
        fi
        rm -rf -- "${WG_DIR}"
    else
        bad "TypeScript unit tests failed to compile"
    fi
    rm -rf -- "${DIST_TEST}"
else
    bad "unit test tsconfig not found: ${UNIT_TSCONFIG}"
fi

# ── B2. Plane controller bins resolve on PATH (FAST; no cluster needed) ──
# network-manager reconcile shells out to these exact bins (planes.ts PLANE_BIN).
# A rename/stale-symlink that leaves one unresolvable (e.g. switch-controller
# dangling to an old firewall/scripts build) makes that plane ENOENT at runtime —
# invisible to the FakePlaneClient unit tests above. Assert each resolves AND is
# not a dangling symlink, so the mismatch fails here instead of in production.
echo ""
echo "== network-manager: plane controller bins resolve (fast) =="
for bin in zone-manager proxmox-controller switch-controller ap-controller; do
    p="$(command -v "${bin}" 2>/dev/null || true)"
    if [[ -z "${p}" ]]; then
        bad "plane bin '${bin}' NOT on PATH (network-manager reconcile would ENOENT this plane)"
    elif [[ ! -e "$(readlink -f "${p}" 2>/dev/null)" ]]; then
        bad "plane bin '${bin}' is a DANGLING symlink ($(readlink "${p}" 2>/dev/null))"
    else
        ok "plane bin '${bin}' resolves"
    fi
done

# ── B3. wgvpn — the admin VPN tool (offline; OPNsense API stubbed) ────
# Moved here from satellite-manager's `admin` verb (ADR-010 §8.4.6).
echo ""
echo "== network-manager: wgvpn (admin VPN, offline) =="
WG="${HERE}/wgvpn/wgvpn.sh"; WGLIB="${HERE}/wgvpn/wgvpn-lib.sh"
wgtmp="$(mktemp -d)"
bash -n "${WG}" && bash -n "${WGLIB}" && ok "wgvpn.sh and wgvpn-lib.sh parse" || bad "wgvpn scripts do not parse"

rc=0; out="$(TAPPAAS_CONFIG_DIR="${wgtmp}" "${WG}" --help 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q "add-peer" <<< "${out}" && grep -q -- "--endpoint" <<< "${out}"; then
    ok "wgvpn --help prints usage (incl. add-peer --endpoint)"
else
    bad "wgvpn --help rc=${rc}"
fi

# the client stanza (server pubkey + API mocked → offline)
out="$( . "${WGLIB}" >/dev/null 2>&1
        av_server_pubkey() { echo "FAKEKEY="; }
        _ow_api() { :; }
        av_client_config "10.255.1.7/32" "203.0.113.5:51821" "PRIVKEY" )"
if grep -q 'Endpoint            = 203.0.113.5:51821' <<< "${out}" \
   && grep -q 'PublicKey           = FAKEKEY=' <<< "${out}" \
   && grep -q 'AllowedIPs          = 10.0.0.0/24' <<< "${out}" \
   && grep -q 'MTU        = 1340' <<< "${out}"; then
    ok "av_client_config renders a valid client stanza"
else
    bad "av_client_config format"
fi

# endpoint discovery: a satellite relaying admin-vpn — an instance of the
# satellite module (config/<instance>.json) or a legacy satellite-<name>.json —
# else a placeholder. A non-satellite with the role, or a satellite without it,
# is not a relay.
EPDIR="${wgtmp}/epcfg"; mkdir -p "${EPDIR}"
disc() { ( . "${WGLIB}" >/dev/null 2>&1; av_discover_endpoint "${EPDIR}" ); }
ep_none="$(disc)"
printf '%s' '{"roles":["reverse-proxy"],"moduleSource":"/x/src/foundation/satellite","address":"9.9.9.9"}' > "${EPDIR}/satellite.json"
printf '%s' '{"roles":["admin-vpn"],"moduleSource":"/x/src/foundation/debianhost","address":"8.8.8.8"}' > "${EPDIR}/dh1.json"
ep_norole="$(disc)"
printf '%s' '{"roles":["reverse-proxy","admin-vpn"],"moduleSource":"/x/src/foundation/satellite","address":"1.2.3.4"}' > "${EPDIR}/hel1.json"
ep_found="$(disc)"
rm -f "${EPDIR}/hel1.json"
printf '%s' '{"name":"sat2","roles":["admin-vpn"],"host":{"publicIp":"5.6.7.8"}}' > "${EPDIR}/satellite-sat2.json"
ep_legacy="$(disc)"
if [[ "${ep_none}" == "<satellite-or-cluster-public-ip>:51821" \
   && "${ep_norole}" == "<satellite-or-cluster-public-ip>:51821" \
   && "${ep_found}" == "1.2.3.4:51821" && "${ep_legacy}" == "5.6.7.8:51821" ]]; then
    ok "av_discover_endpoint: an admin-vpn satellite's address (instance or legacy), else placeholder"
else
    bad "av_discover_endpoint (none='${ep_none}' norole='${ep_norole}' found='${ep_found}' legacy='${ep_legacy}')"
fi

# the WAN :51821 rule goes through the opnsense-controller CLI, not raw REST
WAN_OUT="${wgtmp}/wan_rule_args.txt"; : > "${WAN_OUT}"
fakebin="${wgtmp}/fakebin"; mkdir -p "${fakebin}"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "${WAN_OUT}" > "${fakebin}/opnsense-firewall"
chmod +x "${fakebin}/opnsense-firewall"
(
    . "${WGLIB}" >/dev/null 2>&1
    av_fw_cli() { printf '%s' "${fakebin}/opnsense-firewall"; }
    _ow_api() { printf 'RAW-REST-CALLED\n' >> "${WAN_OUT}"; }
    av_ensure_wan_rule >/dev/null 2>&1
)
if grep -q 'create-rule' "${WAN_OUT}" && grep -q -- '--interface wan' "${WAN_OUT}" \
   && grep -q -- '--protocol udp' "${WAN_OUT}" && grep -q -- '--destination wanip' "${WAN_OUT}" \
   && grep -q -- '--destination-port 51821' "${WAN_OUT}" && ! grep -q 'RAW-REST-CALLED' "${WAN_OUT}"; then
    ok "av_ensure_wan_rule creates the WAN :51821 rule via the opnsense-controller CLI"
else
    bad "av_ensure_wan_rule controller invocation"
fi

# av_setup verifies the live rule set and enables WireGuard before binding a
# rule to the `wireguard` group interface (a live cluster once reported "ready"
# with admin->mgmt missing).
_av_setup_probe() {  # <mgmt-rule-present:0|1> <wan-rule-present:0|1> <order-file>
    local mgmt="$1" wan="$2" order="$3"
    (
        . "${WGLIB}" >/dev/null 2>&1
        av_ensure_server()    { echo "uuid-1"; }
        av_server_pubkey()    { echo "PUBKEY="; }
        av_enable_wg()        { printf 'enable\n' >> "${order}"; echo enabled; }
        av_ensure_mgmt_rule() { printf 'mgmt\n'   >> "${order}"; echo ok; }
        av_ensure_wan_rule()  { printf 'wan\n'    >> "${order}"; echo ok; }
        av_apply()            { printf 'apply\n'  >> "${order}"; echo applied; }
        av_rule_uuid()        { [[ "${mgmt}" == 1 ]] && echo "r-uuid" || true; }
        av_wan_rule_uuid()    { [[ "${wan}"  == 1 ]] && echo "w-uuid" || true; }
        av_setup
    )
}
ORDER="${wgtmp}/order_a"; : > "${ORDER}"
rc=0; out="$(_av_setup_probe 0 1 "${ORDER}" 2>&1)" || rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q "setup incomplete" <<< "${out}" && grep -q "admin->mgmt" <<< "${out}" \
   && grep -q "network-manager wgvpn setup" <<< "${out}" && ! grep -q "admin-vpn ready" <<< "${out}"; then
    ok "av_setup fails loudly, naming the fix, when the admin->mgmt rule is absent"
else
    bad "av_setup should fail when admin->mgmt is missing (rc=${rc})"
fi
ORDER="${wgtmp}/order_b"; : > "${ORDER}"
rc=0; out="$(_av_setup_probe 1 1 "${ORDER}" 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q "admin-vpn ready" <<< "${out}"; then
    ok "av_setup succeeds when both rules are present"
else
    bad "av_setup should succeed when both rules exist (rc=${rc})"
fi
if [[ "$(grep -n -m1 '^enable$' "${ORDER}" | cut -d: -f1)" -lt "$(grep -n -m1 '^mgmt$' "${ORDER}" | cut -d: -f1)" ]]; then
    ok "av_setup enables WireGuard before creating the admin->mgmt rule"
else
    bad "av_setup must enable WireGuard before the mgmt rule (order: $(tr '\n' ',' < "${ORDER}"))"
fi
APPLY_OUT="${wgtmp}/apply"; : > "${APPLY_OUT}"
(
    . "${WGLIB}" >/dev/null 2>&1
    av_enable_wg() { printf 'enable\n' >> "${APPLY_OUT}"; }
    _ow_api() { printf '%s\n' "$*" >> "${APPLY_OUT}"; }
    av_apply >/dev/null 2>&1
)
if grep -q '^enable$' "${APPLY_OUT}" && grep -q 'filter/apply' "${APPLY_OUT}"; then
    ok "av_apply enables WireGuard and applies filter changes"
else
    bad "av_apply behaviour changed"
fi

# #644: --help in any position runs nothing; an option a sub-verb lacks is refused.
rc=0; out="$(TAPPAAS_CONFIG_DIR="${wgtmp}" "${WG}" remove-peer laptop --help 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q 'remove-peer' <<< "${out}"; then ok "wgvpn remove-peer <n> --help prints usage, runs nothing"; else bad "wgvpn remove-peer --help rc=${rc}"; fi
rc=0; out="$(TAPPAAS_CONFIG_DIR="${wgtmp}" "${WG}" add-peer --name n --pubkey k --force 2>&1)" || rc=$?
if [[ "${rc}" -eq 1 ]] && grep -q 'unknown option' <<< "${out}"; then ok "wgvpn add-peer --force is refused"; else bad "wgvpn add-peer --force rc=${rc}"; fi
rm -rf -- "${wgtmp}"

# ── C. DEEP: live reconcile dry-run (non-mutating) ────────────────────
echo ""
echo "== network-manager: live reconcile dry-run (deep) =="
NM_BIN="${NETWORK_MANAGER_BIN:-network-manager}"
if [[ "${TAPPAAS_TEST_DEEP:-0}" != "1" ]]; then
    echo "  SKIP: deep tier (fast mode — set TAPPAAS_TEST_DEEP=1 to run a live reconcile dry-run)"
elif ! command -v "${NM_BIN}" >/dev/null 2>&1; then
    echo "  SKIP: network-manager not on PATH (run install.sh first)"
elif [[ ! -f "${TAPPAAS_CONFIG:-/home/tappaas/config}/zones.json" ]]; then
    echo "  SKIP: no live zones.json to reconcile"
else
    # Dry-run the SWITCH plane only — non-mutating. Distinguish the outcomes:
    #   in-sync (rc 0) / drift (rc 2)         → the plane ran → OK
    #   bin not on PATH / spawn error / other → hard FAIL (this is the very gap
    #                                           that hid the switch-controller
    #                                           rename: a "not on PATH" error must
    #                                           NOT be swallowed as "invoked").
    # Pin CONFIG_DIR to the live config so this exercises the real switch state
    # (earlier sections may have exported a fixture CONFIG_DIR; without this the
    # reconcile would run against an empty dir and vacuously report "in sync").
    out="$(CONFIG_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}" "${NM_BIN}" reconcile --only switch 2>&1)"; rc=$?
    if [[ ${rc} -eq 0 ]]; then
        # rc 0 = no failure (dry-run drift is reported, not a failure) → the plane
        # ran and its bin resolved, which is what this gate checks.
        ok "live: network-manager reconcile --only switch ran the switch plane (dry-run, no failure)"
    elif grep -qiE "not on PATH|failed to spawn|ENOENT|did not run" <<<"${out}"; then
        bad "live: switch plane bin did not run — ${out##*$'\n'}"
    elif [[ ${rc} -eq 2 ]]; then
        echo "  INFO: live switch-plane dry-run reported drift (expected when the switch needs reconcile)"
        ok "live: network-manager reconcile --only switch ran the switch plane (drift reported)"
    else
        bad "live: network-manager reconcile --only switch failed (rc=${rc}) — ${out##*$'\n'}"
    fi
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
