#!/usr/bin/env bash
# test-install-note.sh — what a module says once is said once (DEVELOP.md, "Output").
#
# install_note prints at [Info] while module-manager installs a module for the
# first time (install-module.sh exports TAPPAAS_FIRST_INSTALL=1) and at [Debug]
# on every update and reconcile after; install-module.sh sets the flag for the
# module's own services and install.sh, and clears it before re-wiring others.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CIR="${HERE}/../../lib/common-install-routines.sh"
IM="${HERE}/../../manager/module-manager/install-module.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "  ok: $1"; else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi; }
say() { env -u TAPPAAS_FIRST_INSTALL -u TAPPAAS_DEBUG -u TAPPAAS_SILENT "$@" bash -c '. "$1" >/dev/null 2>&1; install_note "Site: https://x.example"' _ "${CIR}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }

ck "an update prints nothing" "$(say)" ""
ck "…--debug shows it" "$(say TAPPAAS_DEBUG=1)" "[Debug] Site: https://x.example"
ck "the first install prints it at Info" "$(say TAPPAAS_FIRST_INSTALL=1)" "[Info] Site: https://x.example"
ck "…unless silent" "$(say TAPPAAS_FIRST_INSTALL=1 TAPPAAS_SILENT=1)" ""

# install-module.sh: set before the module's services and install.sh, cleared
# before the re-wiring of pre-existing dependents (their update, not an install).
set_at="$(grep -n '^ *export TAPPAAS_FIRST_INSTALL=1' "${IM}" | head -1 | cut -d: -f1)"
step5="$(grep -n 'Step 5: Call dependency service installers' "${IM}" | head -1 | cut -d: -f1)"
step6="$(grep -n 'Step 6: Run module install.sh' "${IM}" | head -1 | cut -d: -f1)"
unset_at="$(grep -n '^ *unset TAPPAAS_FIRST_INSTALL' "${IM}" | head -1 | cut -d: -f1)"
rewire="$(grep -n 'rewired_any=false' "${IM}" | head -1 | cut -d: -f1)"
ck "install-module.sh sets the flag before Step 5" "$([[ -n "${set_at}" && "${set_at}" -lt "${step5}" ]] && echo yes || echo no)" "yes"
ck "…it is still set for Step 6 (install.sh)" "$([[ -n "${unset_at}" && "${unset_at}" -gt "${step6}" ]] && echo yes || echo no)" "yes"
ck "…and cleared before dependents are re-wired" "$([[ -n "${unset_at}" && "${unset_at}" -lt "${rewire}" ]] && echo yes || echo no)" "yes"

echo "test-install-note: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
