#!/usr/bin/env bash
# identity-controller/test.sh — build the package, then run the co-located
# Python unit tests against the freshly-built nix environment (which provides
# httpx). Exit non-zero on any failure.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== building identity-controller =="
( cd "${here}" && nix-build -A default default.nix >/dev/null )

py="${here}/result/bin/python"
if [ ! -x "${py}" ]; then
    echo "[Error] python not found in build result: ${py}" >&2
    exit 1
fi

echo "== unit tests (python -m unittest) =="
PYTHONPATH="${here}/src" "${py}" -m unittest discover -s "${here}/src/test" -v
