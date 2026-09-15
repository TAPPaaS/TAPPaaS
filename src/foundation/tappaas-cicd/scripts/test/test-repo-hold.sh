#!/usr/bin/env bash
# test-repo-hold.sh — the pull hold reader and its use by the refresh (#653).
# Self-contained: a temp config dir, no git, no cluster.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=../../lib/repo-hold.sh
. "${CICD}/lib/repo-hold.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

d="$(mktemp -d)"; trap 'rm -rf "${d}"' EXIT
mkdir -p "${d}/.repo-hold"
printf '{"repository":"TAPPaaS","reason":"unpushed G0.3","by":"lars","since":"x","until":"2030-01-01T00:00:00Z","untilEpoch":1893456000}\n' \
    > "${d}/.repo-hold/TAPPaaS.json"

ck "active before its end" "active 2030-01-01T00:00:00Z lars: unpushed G0.3" "$(repo_hold_state TAPPaaS "${d}" 1893455999)"
ck "expired at its end"    "expired 2030-01-01T00:00:00Z"                    "$(repo_hold_state TAPPaaS "${d}" 1893456000)"
ck "no marker, no hold"    "none" "$(repo_hold_state other "${d}" 0)"
echo 'not json' > "${d}/.repo-hold/broken.json"
ck "an unreadable marker is no hold" "none" "$(repo_hold_state broken "${d}" 0)"
repo_hold_clear TAPPaaS "${d}"
ck "clear removes the marker" "none" "$(repo_hold_state TAPPaaS "${d}" 0)"

# The refresh asks before it pulls: the hold check sits ahead of the checkout
# reconcile inside the per-repository loop.
R="${CICD}/scripts/refresh-control-plane.sh"
n_hold="$(grep -n 'repo_hold_state "\$REPO_NAME"' "${R}" | head -1 | cut -d: -f1)"
n_sync="$(grep -n 'reconcile_repo_checkout "\$REPO_PATH"' "${R}" | head -1 | cut -d: -f1)"
if [[ -n "${n_hold}" && -n "${n_sync}" && "${n_hold}" -lt "${n_sync}" ]]; then
    ck "refresh-control-plane.sh checks the hold before it pulls" ok ok
else
    ck "refresh-control-plane.sh checks the hold before it pulls" ok "missing (hold at '${n_hold}', sync at '${n_sync}')"
fi

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
