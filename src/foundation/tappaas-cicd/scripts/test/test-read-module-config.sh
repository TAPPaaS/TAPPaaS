#!/usr/bin/env bash
#
# test-read-module-config.sh — verify the Pattern A / flat reader funnel (#207).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUNDATION_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../../lib/common-install-routines.sh"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

# Override CONFIG_DIR (read_module_config reads from this var at call time).
CONFIG_DIR="${WORK}"

echo "── test-read-module-config.sh ──"

# Setup: flat-form module
cat > "${WORK}/m-flat.json" <<'EOF'
{ "vmname": "m-flat", "cores": 4, "memory": "4096", "proxyDomain": "x.test" }
EOF

# Setup: Pattern A module — same fields, grouped under config blocks
cat > "${WORK}/m-pa.json" <<'EOF'
{
  "vmname": "m-pa",
  "dependsOn": ["cluster:vm", "network:proxy"],
  "config": {
    "cluster:vm": { "cores": 4, "memory": "4096" },
    "network:proxy": { "proxyDomain": "x.test" }
  }
}
EOF

# Reader funnel: both must return the same field set normalized to flat
out_flat=$(read_module_config m-flat | jq -S 'del(.dependsOn,.vmname)')
out_pa=$(read_module_config m-pa | jq -S 'del(.dependsOn,.vmname)')
if [[ "${out_flat}" == "${out_pa}" ]]; then
    pass "flat and Pattern A inputs produce identical normalized output (excl. vmname)"
else
    fail "normalized outputs differ"
    echo "  flat: ${out_flat}"
    echo "  PA:   ${out_pa}"
fi

# Pattern A: top-level read via read_module_config returns cores at top
if [[ "$(read_module_config m-pa | jq -r '.cores')" == "4" ]]; then
    pass "Pattern A: .cores is accessible at top after normalization"
else
    fail "Pattern A: .cores not accessible at top"
fi

# Auto-loaded $JSON via the source's $1 mechanism
(
    cd "${WORK}"
    unset JSON
    # shellcheck disable=SC1091
    . "${SCRIPT_DIR}/../../lib/common-install-routines.sh" m-pa
    if [[ "$(get_config_value cores unset)" == "4" ]]; then
        pass "auto-loaded \$JSON: get_config_value reads through normalization"
    else
        fail "auto-loaded \$JSON: get_config_value failed"
    fi
)

# Missing module: clean error, returns non-zero, no partial state
if ! read_module_config nonexistent >/dev/null 2>&1; then
    pass "missing module returns non-zero with clean error"
else
    fail "missing module did not error"
fi

# jq_module_write: writes through Pattern A canonicalization
echo '{"vmname":"m-write","dependsOn":["cluster:vm"],"cores":2}' > "${WORK}/m-write.json"
export TAPPAAS_SCHEMA_FILE="${FOUNDATION_DIR}/schemas/module-fields.json"
if jq_module_write m-write '.cores = 8'; then
    # The on-disk shape must be Pattern A: cores under config.cluster:vm
    if [[ "$(jq -r '.config["cluster:vm"].cores' "${WORK}/m-write.json")" == "8" ]] \
       && [[ "$(jq -r '.cores // "null"' "${WORK}/m-write.json")" == "null" ]]; then
        pass "jq_module_write renders Pattern A and writes the update"
    else
        fail "jq_module_write wrote, but shape is wrong: $(jq -c '.' "${WORK}/m-write.json")"
    fi
else
    fail "jq_module_write returned non-zero"
fi

echo
echo "── summary: ${PASS} pass, ${FAIL} fail ──"
exit "${FAIL}"
