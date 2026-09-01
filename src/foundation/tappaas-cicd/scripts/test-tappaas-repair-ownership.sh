#!/usr/bin/env bash
#
# test-tappaas-repair-ownership.sh — hermetic tests for the ownership guard's
# repair script (#533). Runs anywhere (no root, no tappaas user required): drift
# is simulated by pointing OWNER at a user that owns none of the fixture files,
# so `find ! -user <owner>` matches everything.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${HERE}/tappaas-repair-ownership.sh"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# run <expected-rc> <label> -- <env assignments...> -- <args...>
run_case() {
    local want="$1" label="$2"; shift 2
    local -a env=() args=()
    while [[ "$1" != "--" ]]; do env+=("$1"); shift; done; shift
    args=("$@")
    local rc=0
    env "${env[@]}" "$SUT" "${args[@]}" >/tmp/tro.$$ 2>&1 || rc=$?
    if [[ "$rc" -eq "$want" ]]; then ok "$label (rc=$rc)"; else
        bad "$label (want rc=$want, got $rc)"; sed 's/^/      | /' /tmp/tro.$$
    fi
    rm -f /tmp/tro.$$
}

ME="$(id -un)"; MYGRP="$(id -gn)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/config" "$TMP/TAPPaaS"
echo '{}' > "$TMP/config/site.json"
: > "$TMP/TAPPaaS/tracked-file"

BASE=(CONFIG_DIR="$TMP/config" TAPPAAS_HOME_ROOT="$TMP" TAPPAAS_OPERATOR_GROUP="$MYGRP")

echo "tappaas-repair-ownership tests:"

# 1. --help exits 0
run_case 0 "--help prints usage" "${BASE[@]}" TAPPAAS_OPERATOR="$ME" -- --help

# 2. unknown arg exits 2
run_case 2 "unknown arg rejected" "${BASE[@]}" TAPPAAS_OPERATOR="$ME" -- --bogus

# 3. clean tree (owner == me) → --check exits 0
run_case 0 "clean tree passes --check" "${BASE[@]}" TAPPAAS_OPERATOR="$ME" -- --check

# 4. drift (owner == nobody-owns-these) → --check exits 1
run_case 1 "drift detected by --check" "${BASE[@]}" TAPPAAS_OPERATOR="nobody" -- --check

# 5. repair mode on a clean tree exits 0 without touching anything. (We do NOT
# force a real repair here: on a host where the operator has passwordless sudo
# the chown would actually run and mutate the fixture. Exercising the true
# chown-back path is a privileged live test, not a hermetic one.)
run_case 0 "repair mode on clean tree exits 0" "${BASE[@]}" TAPPAAS_OPERATOR="$ME" --

# 6. config dir outside HOME_ROOT is skipped, not chowned (bounding).
OUT="$(env CONFIG_DIR=/etc TAPPAAS_HOME_ROOT="$TMP" TAPPAAS_OPERATOR="nobody" \
    TAPPAAS_OPERATOR_GROUP="$MYGRP" "$SUT" --check 2>&1 || true)"
if grep -q "outside ${TMP}, refusing to chown" <<<"$OUT"; then
    ok "out-of-home path is bounded/skipped"
else
    bad "out-of-home path bounding"; sed 's/^/      | /' <<<"$OUT"
fi

echo "----"
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
