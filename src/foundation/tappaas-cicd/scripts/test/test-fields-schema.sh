#!/usr/bin/env bash
#
# test-fields-schema.sh — validate every field manifest against fields-schema.json (#567).
#
# Since #567 a field's DEFINITION lives with the service that owns it, spread
# across three tiers instead of one global file. That is only safe if something
# checks the shape: a typo'd key in a service manifest would otherwise be
# accepted silently and the field would simply not behave as written.
#
# fields-schema.json is that check, and it covers both halves of an entry — the
# definition (type/default/values) and the ADR-020 change semantics
# (class/apply/changeNote) — so one validator serves all three tiers:
#
#   schemas/module-fields.json           the generic fields
#   <module>/fields.json                 shared by a module's services
#   <module>/services/<svc>/fields.json  owned by one service
#
# DEEP: it walks the whole foundation tree and shells out to a JSON-Schema
# validator per file. No cluster contact; deep because of breadth, not risk.
#
# Usage: test-fields-schema.sh [--deep]
#   Without --deep (or TAPPAAS_TEST_DEEP=1) it validates the two schema-tier
#   files only, which is quick and still catches the common case.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUNDATION_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
META="${FOUNDATION_DIR}/schemas/fields-schema.json"

DEEP="${TAPPAAS_TEST_DEEP:-0}"
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && DEEP=1; done

PASS=0
FAIL=0
pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

[[ -f "${META}" ]] || { echo "fields-schema.json not found at ${META}" >&2; exit 1; }

# One validator, chosen once. python3 -m jsonschema is the reference
# implementation and is present on the mothership; the `jsonschema` CLI is the
# same library. Refuse rather than skip if neither is here: a validation test
# that silently validates nothing is the #570 failure again.
#
# The probe's stderr is CAPTURED, not discarded. This detector has twice fired
# during an `update-tappaas` run — aborting the whole update at tappaas-cicd's
# pre-update gate — while passing every time it is run by hand, and
# `2>/dev/null` meant the one thing that would identify the cause (the actual
# ImportError, or a python that failed to start at all) was thrown away each
# time. Whatever the next occurrence is, it now says so.
# Resolved by CAPABILITY, not by PATH position. `python3` off PATH is not a safe
# way to find an interpreter that has a library: update-tappaas's nix wrapper
# prepends its own bare interpreter, so this test saw "no jsonschema" on every
# update run and aborted the whole update at tappaas-cicd's pre-update gate,
# while passing every hand-run. tappaas_python_with asks each candidate whether
# it can import the module and takes the first that can (PATH still first).
if ! declare -F tappaas_python_with >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "${FOUNDATION_DIR}/tappaas-cicd/lib/common-install-routines.sh" >/dev/null 2>&1 || true
fi
if declare -F tappaas_python_with >/dev/null 2>&1; then
    PY_BIN="$(tappaas_python_with jsonschema)" && _js_rc=0 || _js_rc=1
    _js_probe="${TAPPAAS_PYTHON_WHY}"
else
    PY_BIN="$(command -v python3 || true)"
    _js_probe="$([ -n "${PY_BIN}" ] && "${PY_BIN}" -c 'import jsonschema' 2>&1)"
    _js_rc=$?
fi
if [ "${_js_rc}" -eq 0 ]; then
    validate() { # validate <schema> <instance>  → 0 valid
        "${PY_BIN}" - "$1" "$2" <<'PY'
import json, sys
from jsonschema import Draft202012Validator
schema = json.load(open(sys.argv[1]))
inst = json.load(open(sys.argv[2]))
errs = sorted(Draft202012Validator(schema).iter_errors(inst), key=lambda e: list(e.path))
for e in errs[:8]:
    where = "/".join(str(p) for p in e.path) or "(root)"
    print(f"      {where}: {e.message[:160]}")
sys.exit(1 if errs else 0)
PY
    }
else
    {
        echo "test-fields-schema.sh: no jsonschema module — cannot validate"
        echo "  probe : no candidate interpreter could 'import jsonschema'"
        echo "  error : ${_js_probe:-(no output)}"
        echo "  python: $(command -v python3 || echo 'NOT ON PATH')"
        echo "          -> $(readlink -f "$(command -v python3)" 2>/dev/null || echo '?')"
        echo "  PATH  : ${PATH}"
        # The nix python wrapper vars are inherited by every child of a
        # nix-wrapped python app (update-tappaas is one), and point at THAT
        # app's env — which does not carry jsonschema.
        echo "  NIX_PYTHONPATH=${NIX_PYTHONPATH:-(unset)}"
        echo "  NIX_PYTHONEXECUTABLE=${NIX_PYTHONEXECUTABLE:-(unset)}"
        echo "  PYTHONPATH=${PYTHONPATH:-(unset)}  PYTHONHOME=${PYTHONHOME:-(unset)}"
    } >&2
    exit 1
fi

echo "── field manifests vs fields-schema.json ──"

check_file() { # check_file <path> <label>
    local f="$1" label="$2" out
    if out="$(validate "${META}" "${f}" 2>&1)"; then
        pass "${label}"
    else
        fail "${label}"
        printf '%s\n' "${out}" | head -8
    fi
}

check_file "${FOUNDATION_DIR}/schemas/module-fields.json" "schemas/module-fields.json"
[[ -f "${FOUNDATION_DIR}/schemas/fields.json" ]] \
    && check_file "${FOUNDATION_DIR}/schemas/fields.json" "schemas/fields.json (module-level)"

if [[ "${DEEP}" != "1" ]]; then
    echo "  ⊘ per-service manifests (use --deep to validate all of them)"
else
    _n=0
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        _n=$((_n + 1))
        check_file "${f}" "${f#"${FOUNDATION_DIR}/"}"
    done < <(find "${FOUNDATION_DIR}" -path '*/services/*/fields.json' -o -path '*/fields.json' \
             | grep -vE '/schemas/fields\.json$' | sort -u)
    [[ "${_n}" -gt 0 ]] && pass "walked ${_n} manifest(s) — a new one is validated without being listed"
fi

echo
echo "── summary: ${PASS} pass, ${FAIL} fail ──"
exit "${FAIL}"
