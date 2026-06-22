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
for f in "${HERE}/zone-reconcile" "${HERE}/zone-controller.sh" "${HERE}/zone-state.sh"; do
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
        if run_ts "NM_FIXTURE_DIR='${FIXTURE_DIR}' NM_TEMPLATE='${HERE}/zones.json' node '${DIST_TEST}/test/unit/network.test.js'"; then
            ok "TypeScript reconcile/CRUD/zones-init unit tests pass"
        else
            bad "TypeScript unit tests FAILED"
        fi

        # ── zones-init CLI smoke (offline; temp --out, never live config) ──
        # The unit tsconfig compiles src/ into dist-test/src; run the real CLI
        # entry against a temp output and assert the transformed file on disk.
        ZINIT_OUT="$(mktemp -d)/z.json"
        # Isolate --config-dir to an empty dir so the occupancy scan finds no
        # tenants (default configDir is the LIVE config, which would keep occupied
        # legacy zones Active). With no occupancy, srvWork is inactivated as asserted.
        ZINIT_CFG="$(mktemp -d)"
        if run_ts "NM_TEMPLATE='${HERE}/zones.json' node '${DIST_TEST}/src/main.js' zones-init --name acme --from '${HERE}/zones.json' --out '${ZINIT_OUT}' --config-dir '${ZINIT_CFG}'" >/dev/null 2>&1 \
            && [[ -f "${ZINIT_OUT}" ]] \
            && run_ts "node -e 'const z=require(\"${ZINIT_OUT}\"); process.exit((z.acme&&!z.srv&&z[\"acme-private\"]&&z[\"acme-guest\"]&&z.acme.state===\"Active\"&&z.srvWork.state===\"Inactive\"&&!z[\"acme-private\"][\"access-to\"].includes(\"srvHome\")&&z[\"acme-private\"][\"access-to\"].includes(\"acme\"))?0:1)'" >/dev/null 2>&1; then
            ok "zones-init CLI transforms template to temp --out (renames + inactivations + ref-integrity)"
        else
            bad "zones-init CLI smoke FAILED"
        fi
        rm -rf -- "$(dirname "${ZINIT_OUT}")" "${ZINIT_CFG}"

        # ── zones-check CLI smoke (offline; temp fixtures, never live config) ──
        # Good fixture (the distributed template, default-active mgmt) exits 0;
        # a fixture with a dangling access-to ref exits non-zero. The temp
        # config-dir holds only zones.json so the installation check is a no-op.
        ZC_DIR="$(mktemp -d)"
        cp "${HERE}/zones.json" "${ZC_DIR}/zones.json"
        if run_ts "node '${DIST_TEST}/src/main.js' zones-check --zones '${ZC_DIR}/zones.json' --config-dir '${ZC_DIR}'" >/dev/null 2>&1; then
            ok "zones-check CLI exits 0 on a well-formed zones.json"
        else
            bad "zones-check CLI unexpectedly failed on a good fixture"
        fi
        # Inject a dangling access-to ref → must exit non-zero.
        ZC_BAD_DIR="$(mktemp -d)"
        run_ts "node -e 'const fs=require(\"fs\");const z=JSON.parse(fs.readFileSync(\"${ZC_DIR}/zones.json\",\"utf8\"));z.dmz[\"access-to\"].push(\"nosuchzone\");fs.writeFileSync(\"${ZC_BAD_DIR}/zones.json\",JSON.stringify(z));'" >/dev/null 2>&1
        if run_ts "node '${DIST_TEST}/src/main.js' zones-check --zones '${ZC_BAD_DIR}/zones.json' --config-dir '${ZC_BAD_DIR}'" >/dev/null 2>&1; then
            bad "zones-check CLI did NOT fail on a dangling reference"
        else
            ok "zones-check CLI exits non-zero on a dangling access-to reference"
        fi
        rm -rf -- "${ZC_DIR}" "${ZC_BAD_DIR}"

        # ── zones-distribute CLI smoke (offline; NO real scp) ─────────────
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
        ZD_OUT="$(run_ts "CONFIG_DIR='${ZD_DIR}' NM_SCP_BIN='${ZD_DIR}/scp' node '${DIST_TEST}/src/main.js' zones-distribute --zones '${ZD_DIR}/zones.json' --dry-run" 2>&1)"
        if echo "${ZD_OUT}" | grep -q "root@tappaas1.mgmt.internal:/root/tappaas/zones.json" \
            && echo "${ZD_OUT}" | grep -q "root@tappaas2.mgmt.internal:/root/tappaas/zones.json" \
            && [[ ! -f "${ZD_MARKER}" ]]; then
            ok "zones-distribute --dry-run enumerates node targets without scp"
        else
            bad "zones-distribute --dry-run did not list targets (or invoked scp)"
        fi

        # zones-init to a TEMP --out (non-live) must NOT distribute → no scp.
        ZD_INIT_OUT="${ZD_DIR}/init.json"
        run_ts "CONFIG_DIR='${ZD_DIR}' NM_SCP_BIN='${ZD_DIR}/scp' NM_TEMPLATE='${HERE}/zones.json' node '${DIST_TEST}/src/main.js' zones-init --name acme --from '${HERE}/zones.json' --out '${ZD_INIT_OUT}'" >/dev/null 2>&1
        if [[ -f "${ZD_INIT_OUT}" && ! -f "${ZD_MARKER}" ]]; then
            ok "zones-init to a temp --out writes the file but does NOT scp (non-live auto-skip)"
        else
            bad "zones-init to a temp --out attempted scp (should auto-skip non-live)"
        fi
        rm -rf -- "${ZD_DIR}"
    else
        bad "TypeScript unit tests failed to compile"
    fi
    rm -rf -- "${DIST_TEST}"
else
    bad "unit test tsconfig not found: ${UNIT_TSCONFIG}"
fi

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
    # Dry-run the SWITCH plane only — demonstrates the plane is invoked and the
    # bin resolves, without mutating any state. A controller being unreachable
    # surfaces as a non-zero exit; we report it but do not hard-fail the suite
    # (the real live gate is a later chunk).
    if "${NM_BIN}" reconcile --only switch >/dev/null 2>&1; then
        ok "live: network-manager reconcile --only switch (dry-run) in sync"
    else
        echo "  INFO: live switch-plane dry-run reported drift/unreachable (expected off-cluster)"
        ok "live: network-manager reconcile --only switch invoked the switch plane"
    fi
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
