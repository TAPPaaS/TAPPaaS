#!/usr/bin/env bash
#
# live-test-template.sh — copy this for a layer-C test on hrossen
# (docs/plans/console-gui-pipeline.md §6): real changes with a reverse, under a
# test name. Setup, check, teardown; the teardown runs even on failure, and the
# leftover check ends it. Never on makerfloss.
#
set -uo pipefail

NAME="zz-live-test"
FAILED=0
ok()  { echo "  ok: $*"; }
bad() { echo "  FAIL: $*"; FAILED=1; }

before_count() { asset-manager asset list --json | jq 'length'; } # what the test must leave as it was

if pgrep -af "site-manager (test|update)" | grep -v pgrep; then
    echo "another run is on: not now"
    exit 2
fi

BEFORE="$(before_count)"

teardown() {
    asset-manager asset remove "${NAME}" >/dev/null 2>&1 || true # the reverse of setup
    [[ "$(before_count)" == "${BEFORE}" ]] && ok "nothing left behind" || bad "leftover: ${BEFORE} before, $(before_count) after"
    cmdb sweep | head -2 # expect 0 new missing
    exit "${FAILED}"
}
trap teardown EXIT

# setup
asset-manager asset add "${NAME}" --kind other || bad "setup"

# check
asset-manager asset show "${NAME}" >/dev/null && ok "the asset is there" || bad "the asset is not there"
