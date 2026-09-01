#!/usr/bin/env bash
#
# test-common-install-routines.sh — hermetic unit tests for helpers in
# common-install-routines.sh. Currently covers ensure_scripts_executable()
# (#524): it must chmod +x only files that need it, skip ones already
# executable, and never abort the caller when a chmod cannot succeed (a
# root-owned file left by an earlier sudo run) under `set -euo pipefail`.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common-install-routines.sh disable=SC1091
. "${HERE}/common-install-routines.sh" >/dev/null 2>&1

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

echo "ensure_scripts_executable tests (#524):"

# 1. chmods the non-executable, leaves the already-executable, recurses services.
d="$(mktemp -d)"; mkdir -p "$d/services/foo"
printf '#!/bin/sh\n' > "$d/a.sh";              chmod 0644 "$d/a.sh"
printf '#!/bin/sh\n' > "$d/b.sh";              chmod 0755 "$d/b.sh"
printf '#!/bin/sh\n' > "$d/services/foo/s.sh"; chmod 0644 "$d/services/foo/s.sh"
rc=0; ensure_scripts_executable "$d" || rc=$?
[[ "$rc" -eq 0 ]]                    && ok "returns 0 (no abort)"          || bad "returns 0"
[[ -x "$d/a.sh" ]]                   && ok "non-exec root .sh -> +x"       || bad "a.sh +x"
[[ -x "$d/b.sh" ]]                   && ok "already-exec .sh left +x"      || bad "b.sh +x"
[[ -x "$d/services/foo/s.sh" ]]      && ok "service .sh -> +x"             || bad "svc +x"
rm -rf "$d"

# 2. an unavoidable chmod failure warns but does NOT abort (the #524 bug).
#    Stub chmod to fail so no root/foreign-owned file is needed.
d="$(mktemp -d)"; printf '#!/bin/sh\n' > "$d/x.sh"; chmod 0644 "$d/x.sh"
chmod() { return 1; }                       # override the builtin for this test
rc=0; out="$(ensure_scripts_executable "$d" 2>&1)" || rc=$?
unset -f chmod
[[ "$rc" -eq 0 ]]                                   && ok "chmod failure does not abort" || bad "no-abort on chmod fail (rc=$rc)"
grep -q 'cannot chmod +x' <<<"$out"                && ok "chmod failure is warned"       || bad "warns on chmod fail"
rm -rf "$d"

# 3. missing / empty directory is a clean no-op.
rc=0; ensure_scripts_executable "/nonexistent/$$/nope" || rc=$?
[[ "$rc" -eq 0 ]] && ok "missing dir -> 0" || bad "missing dir -> 0"

echo "----"
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
