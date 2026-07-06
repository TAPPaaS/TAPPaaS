#!/usr/bin/env bash
# node-provisioner/test.sh — build the package (nix), smoke the CLI
# (--help), then run the co-located OFFLINE Python unit tests (stdlib
# unittest over the pure logic: registration CRUD, answer matching,
# answer.toml rendering, one-shot consumption). No firewall, no PVE ISO,
# no systemd needed. Exit non-zero on any failure.
set -euo pipefail

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
