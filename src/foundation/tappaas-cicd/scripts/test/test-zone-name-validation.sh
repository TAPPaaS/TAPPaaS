#!/usr/bin/env bash
#
# test-zone-name-validation.sh — schema regex rejects hyphens in zone names (#237).
#
# Confirms the module-fields.json `format` pattern on zone0/zone1/trunks0/trunks1
# accepts the underscore form and rejects the legacy hyphen form. check_json
# returns non-zero on validation failure, so we capture stdout+stderr and grep
# the report.
#

set -uo pipefail
# No `set -e`: check_json returns 1 when it finds errors (normal here).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUNDATION_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common-install-routines.sh"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

mkmod() {
    local file="$1"
    cat > "$file" <<'JSON'
{
  "description": "test",
  "version": "0.1",
  "vmname": "test-mod",
  "vmid": 100,
  "node": "tappaas1",
  "cores": 1,
  "memory": "1024",
  "diskSize": "8G",
  "storage": "tanka1",
  "imageType": "clone",
  "image": "9000",
  "bridge0": "lan",
  "zone0": "srv_home",
  "trunks0": "NONE",
  "dependsOn": ["cluster:vm"],
  "provides": []
}
JSON
}

# Run check_json and return its combined output (errors expected).
cj() {
    check_json "$1" "$2" 2>&1
}

echo "── test-zone-name-validation.sh ──"

SCHEMA="${FOUNDATION_DIR}/module-fields.json"
[[ -f "${SCHEMA}" ]] || { fail "module-fields.json not found at ${SCHEMA}"; exit 1; }

# Case 1: valid underscore zone0 passes the format regex.
F1="${WORK}/case1.json"; mkmod "${F1}"
out=$(cj "${F1}" "${SCHEMA}" || true)
if echo "${out}" | grep -qE "zone0.*does not match format"; then
    fail "underscore zone0 (srv_home) was flagged"
else
    pass "underscore zone0 (srv_home) passes regex"
fi

# Case 2: hyphenated zone0 fails the regex.
F2="${WORK}/case2.json"; mkmod "${F2}"
jq '.zone0 = "srv-home"' "${F2}" > "${F2}.tmp" && mv "${F2}.tmp" "${F2}"
out=$(cj "${F2}" "${SCHEMA}" || true)
if echo "${out}" | grep -qE "zone0.*does not match format"; then
    pass "hyphenated zone0 (srv-home) rejected by regex"
else
    fail "hyphenated zone0 (srv-home) NOT rejected"
    echo "${out}" | head -5 | sed 's/^/    /'
fi

# Case 3: hyphenated zone1 fails the regex.
F3="${WORK}/case3.json"; mkmod "${F3}"
jq '.bridge1 = "lan" | .zone1 = "iot-local"' "${F3}" > "${F3}.tmp" && mv "${F3}.tmp" "${F3}"
out=$(cj "${F3}" "${SCHEMA}" || true)
if echo "${out}" | grep -qE "zone1.*does not match format"; then
    pass "hyphenated zone1 (iot-local) rejected by regex"
else
    fail "hyphenated zone1 (iot-local) NOT rejected"
fi

# Case 4: hyphenated trunks0 entry fails the regex.
F4="${WORK}/case4.json"; mkmod "${F4}"
jq '.trunks0 = "srv_home;iot-local;dmz"' "${F4}" > "${F4}.tmp" && mv "${F4}.tmp" "${F4}"
out=$(cj "${F4}" "${SCHEMA}" || true)
if echo "${out}" | grep -qE "trunks0.*does not match format"; then
    pass "trunks0 with hyphenated entry rejected"
else
    fail "trunks0 with hyphenated entry NOT rejected"
fi

# Case 5: ALL/NONE/* sentinels still pass for trunks0.
F5="${WORK}/case5.json"; mkmod "${F5}"
all_ok=1
for sentinel in "ALL" "NONE" "*"; do
    jq --arg s "${sentinel}" '.trunks0 = $s' "${F5}" > "${F5}.tmp" && mv "${F5}.tmp" "${F5}"
    out=$(cj "${F5}" "${SCHEMA}" || true)
    if echo "${out}" | grep -qE "trunks0.*does not match format"; then
        fail "trunks0 sentinel '${sentinel}' rejected"
        all_ok=0
    fi
done
[[ "${all_ok}" -eq 1 ]] && pass "trunks0 sentinels (ALL/NONE/*) all pass"

# Case 6: uppercase letters in zone0 fail (zone keys are lowercase by convention).
F6="${WORK}/case6.json"; mkmod "${F6}"
jq '.zone0 = "Srv_Home"' "${F6}" > "${F6}.tmp" && mv "${F6}.tmp" "${F6}"
out=$(cj "${F6}" "${SCHEMA}" || true)
if echo "${out}" | grep -qE "zone0.*does not match format"; then
    pass "uppercase zone0 (Srv_Home) rejected by regex"
else
    fail "uppercase zone0 (Srv_Home) NOT rejected"
fi

echo
echo "── summary: ${PASS} pass, ${FAIL} fail ──"
exit "${FAIL}"
