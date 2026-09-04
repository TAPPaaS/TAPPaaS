#!/usr/bin/env bash
# node-provisioner/test.sh — build the package (nix), smoke the CLI
# (--help), then run the co-located OFFLINE Python unit tests (stdlib
# unittest over the pure logic: registration CRUD, answer matching,
# answer.toml rendering, one-shot consumption). No firewall, no PVE ISO,
# no systemd needed. Exit non-zero on any failure.
set -euo pipefail

# Accept --deep as well as TAPPAAS_TEST_DEEP=1. Every gate below reads the
# variable, so exporting it here is all a flag needs to do — and exporting (not
# just setting) is what carries it into any suite this one dispatches. Without
# this, `test.sh --deep` silently ran the fast path.
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && export TAPPAAS_TEST_DEEP=1; done


here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v nix-build >/dev/null 2>&1; then
    echo "== building node-provisioner (nix) =="
    ( cd "${here}" && nix-build -A default default.nix >/dev/null )

    py="${here}/result/bin/python"
    if [ ! -x "${py}" ]; then
        echo "[Error] python not found in build result: ${py}" >&2
        exit 1
    fi

    echo "== CLI smoke test (node-provisioner --help) =="
    "${here}/result/bin/node-provisioner" --help >/dev/null
else
    # Dev fallback (no nix on the box): stdlib-only package, plain python3
    # ≥3.10 suffices.
    echo "[Warning] nix-build not found — falling back to system python3" >&2
    py="$(command -v python3)"

    echo "== CLI smoke test (python -m node_provisioner.cli --help) =="
    PYTHONPATH="${here}/src" "${py}" -m node_provisioner.cli --help >/dev/null
fi

echo "== unit tests (python -m unittest) =="
PYTHONPATH="${here}/src" "${py}" -m unittest discover -s "${here}/src/test" -v

# ── DEEP: register → serve → answer → one-shot consume (localhost E2E) ──
# Exercises the real HTTP layer end-to-end with no PXE client: a pending
# registration must answer exactly once for its MAC and 404 afterwards.
# Self-contained: temp config dir, high port, server killed on exit.
if [ "${TAPPAAS_TEST_DEEP:-0}" = "1" ]; then
    echo "== DEEP: answer-server E2E (localhost) =="
    _np_bin="$(command -v node-provisioner || true)"
    if [ -n "${_np_bin}" ]; then
        _np_tmp="$(mktemp -d)"
        _np_port=18090
        _np_rc=0
        (
            set -e
            export TAPPAAS_CONFIG="${_np_tmp}/config"
            export TAPPAAS_NODE_SECRETS="${_np_tmp}/secrets"
            # serve refuses to start without staged PXE assets — stub the dir
            # (the E2E exercises the ANSWER path, not the netboot assets).
            export TAPPAAS_PXE_DIR="${_np_tmp}/pxe"
            mkdir -p "${TAPPAAS_CONFIG}" "${TAPPAAS_PXE_DIR}"
            printf '#!ipxe\n' > "${TAPPAAS_PXE_DIR}/boot.ipxe"
            # serve renders answers against site.json — seed a minimal one.
            printf '{"name":"zztest","hardware":{"nodes":[]},"repositories":[]}' > "${TAPPAAS_CONFIG}/site.json"
            "${_np_bin}" register zztest-node --mac de:ad:be:ef:99:01 --pool 'tanka1=single:nvme0n1'
            "${_np_bin}" serve --port "${_np_port}" >"${_np_tmp}/serve.log" 2>&1 &
            _srv=$!
            trap 'kill "${_srv}" 2>/dev/null || true' EXIT
            # Wait for the port (up to 10s) instead of a blind sleep.
            for _i in $(seq 1 20); do
                curl -s -o /dev/null "http://127.0.0.1:${_np_port}/" && break
                kill -0 "${_srv}" 2>/dev/null || { echo "[Error] serve died at startup:"; cat "${_np_tmp}/serve.log"; exit 1; } >&2
                sleep 0.5
            done
            _payload='{"network_interfaces":[{"mac":"de:ad:be:ef:99:01"}],"dmi":{"system":{"serial":"ZZTEST"}}}'
            _code="$(curl -s -o "${_np_tmp}/answer.toml" -w '%{http_code}' -X POST -d "${_payload}" "http://127.0.0.1:${_np_port}/answer")"
            [ "${_code}" = "200" ] || { echo "[Error] answer POST returned ${_code}" >&2; exit 1; }
            grep -q 'zztest-node' "${_np_tmp}/answer.toml" || { echo "[Error] answer.toml lacks the node fqdn" >&2; exit 1; }
            echo "  ok: matched MAC → 200 + answer.toml with node identity"
            # TAPPaaS disk standard: installer targets the BOOT disk only,
            # ext4/LVM; declared pools are post-join (cf. tappaas1).
            grep -q 'filesystem = "ext4"' "${_np_tmp}/answer.toml" || { echo "[Error] answer.toml is not ext4 on the boot disk" >&2; exit 1; }
            grep -q 'disk-list = \["sda"\]' "${_np_tmp}/answer.toml" || { echo "[Error] answer.toml disk-list is not the default boot disk" >&2; exit 1; }
            grep -q 'tanka1' "${_np_tmp}/answer.toml" || { echo "[Error] answer.toml lost the post-join pool note" >&2; exit 1; }
            echo "  ok: disk-setup is ext4 on boot disk, pools deferred to post-join"
            _code2="$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "${_payload}" "http://127.0.0.1:${_np_port}/answer")"
            [ "${_code2}" = "404" ] || { echo "[Error] second POST returned ${_code2} (expected 404 — one-shot broken)" >&2; exit 1; }
            echo "  ok: registration consumed (second request 404)"
        ) || { _np_rc=1; echo "--- serve.log ---" >&2; cat "${_np_tmp}/serve.log" >&2 2>/dev/null || true; }
        rm -rf "${_np_tmp}"
        [ "${_np_rc}" = "0" ] || exit 1
    else
        echo "  SKIP: node-provisioner not installed"
    fi
fi
