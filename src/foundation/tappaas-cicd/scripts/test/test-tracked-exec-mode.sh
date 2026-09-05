#!/usr/bin/env bash
# test-tracked-exec-mode.sh — the TRACKED git mode of an invoked script must be
# 100755 (the other half of #565).
#
# #565 made the tracked mode authoritative: ensure_scripts_executable restores
# +x on a file committed 100755 and deliberately never widens one committed
# 100644. test.sh's deep guard proves that HEALER behaves. Nothing proved the
# tracked modes it heals from are right — and they were not: compose-fields.sh,
# gen-service-fields-doc.py and two scripts/test suites were committed 100644.
#
# That is invisible on a working checkout for two compounding reasons:
# core.fileMode=false makes git ignore the local `chmod +x` somebody once ran,
# so the drift never shows in `git status`; and the callers gate on `[ -x ]`, so
# a fresh clone does not fail — it silently SKIPS the step. compose-fields.sh is
# how config/module-fields.json is built; on a virgin install it simply would
# not run, and nothing would say so.
#
# Two sweeps, no curated list (a list is what let the gap persist — see the
# Test 9z rationale in test.sh):
#   1. every swept tabletop suite (scripts/test/test-*.sh) is tracked 100755
#   2. every repo file a shell script gates on `[ -x … ]` is tracked 100755
#
# Self-contained: git plumbing only, no cluster, no network.
# Exits 1 if any assertion fails.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
cd "${REPO_ROOT}" || { echo "cannot cd to repo root" >&2; exit 1; }

PASS=0
FAIL=0
pass() { printf '  \xe2\x9c\x93 %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL + 1)); }

# tracked_mode <path> → the mode git records (empty when untracked)
tracked_mode() { git ls-files -s -- "$1" 2>/dev/null | awk '{print $1; exit}'; }

# ── 1. swept tabletop suites must be executable ──────────────────────────────
# test.sh runs scripts/test/test-*.sh as commands and FAILS a non-executable
# one. A suite committed 100644 therefore breaks the sweep on a fresh clone.
echo "[1] swept tabletop suites are tracked 100755"
_bad=0
while IFS= read -r f; do
    [ -n "${f}" ] || continue
    if [ "$(tracked_mode "${f}")" != "100755" ]; then
        fail "${f} is tracked $(tracked_mode "${f}") — commit it 100755 (git update-index --chmod=+x)"
        _bad=$((_bad + 1))
    fi
done <<EOF
$(git ls-files 'src/foundation/tappaas-cicd/scripts/test/test-*.sh')
EOF
[ "${_bad}" -eq 0 ] && pass "every scripts/test/test-*.sh is tracked 100755"

# ── 2. anything gated on [ -x … ] must be executable ─────────────────────────
# A `-x` guard over a repo file is a silent feature switch: tracked 100644, the
# guard is false on a fresh clone and the step is skipped with no diagnostic.
# Resolve each guard by BASENAME (paths are built from ${SCRIPT_DIR}-style
# variables, so they cannot be resolved literally) and check it when the
# basename identifies exactly one tracked file.
echo "[2] repo files gated on [ -x … ] are tracked 100755"
_checked=0
_bad=0
_guards="$(git grep -hoE '\[\[? +-x +"[^"]+"' -- '*.sh' 2>/dev/null \
           | grep -oE '"[^"]+"' | tr -d '"' | sed 's#.*/##' | sort -u)"
while IFS= read -r base; do
    # Only names that look like a script file; skip ${VAR} leftovers and
    # command -v style lookups.
    case "${base}" in
        ''|*'$'*|*'*'*) continue ;;
        *.sh|*.py) ;;
        *) continue ;;
    esac
    # Exactly one tracked file with this basename, or we cannot resolve it.
    matches="$(git ls-files "*/${base}" "${base}" 2>/dev/null)"
    [ "$(printf '%s\n' "${matches}" | grep -c .)" -eq 1 ] || continue
    _checked=$((_checked + 1))
    mode="$(tracked_mode "${matches}")"
    if [ "${mode}" != "100755" ]; then
        fail "${matches} is gated on [ -x ] but tracked ${mode} — the guard is false on a fresh clone, so the step silently never runs"
        _bad=$((_bad + 1))
    fi
done <<EOF
${_guards}
EOF
if [ "${_checked}" -eq 0 ]; then
    # A sweep that resolved nothing has asserted nothing (#570).
    fail "resolved no [ -x ] guards to tracked files — the sweep matched nothing, so it proves nothing"
elif [ "${_bad}" -eq 0 ]; then
    pass "all ${_checked} resolvable [ -x ] guard target(s) are tracked 100755"
fi

echo
echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
