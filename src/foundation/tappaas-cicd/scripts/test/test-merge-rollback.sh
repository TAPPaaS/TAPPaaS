#!/usr/bin/env bash
#
# The config and its merge baseline are restored together (#688).
#
# Step 0 advances <module>.json.orig to the release it merged. When a later
# step fails, update-module.sh restores the config — and used to leave the
# baseline advanced. The next merge then read the difference as "the operator
# removed these fields": rule 2a DROPS what the release still declares, so a
# module could never converge again. Observed on the test site 2026-09-21
# while wiring #662, where it also cost a machine its `address`.
#
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
UM="${HERE}/../../manager/module-manager/update-module.sh"
pass=0; fail=0
ok()  { echo "  ✓ $*"; pass=$((pass+1)); }
bad() { echo "  ✗ $*"; fail=$((fail+1)); }

W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT
CONFIG_DIR="${W}/config"; mkdir -p "${CONFIG_DIR}"
printf '%s' '{"kind":"machine","address":"a.b","backup":{"filesystemPaths":["/etc"]}}' > "${CONFIG_DIR}/m.json"
printf '%s' '{"kind":"machine"}'                                                        > "${CONFIG_DIR}/m.json.orig"

# The two functions under test, with the logging they expect.
info(){ :; }; debug(){ :; }; warn(){ echo "WARN: $*" >&2; }; fatal(){ echo "FATAL: $*" >&2; exit 1; }
GN=""; CL=""; BL=""
CONFIG_BACKUP=""; ORIG_BACKUP=""
eval "$(sed -n '/^backup_module_config() {/,/^}/p' "${UM}")"
eval "$(sed -n '/^restore_module_config() {/,/^}/p' "${UM}")"
declare -F backup_module_config >/dev/null || { echo "could not load the functions from ${UM}"; exit 2; }

backup_module_config m
[[ -n "${CONFIG_BACKUP}" && -f "${CONFIG_BACKUP}" ]] && ok "the config is captured before the merge" || bad "no config backup"
[[ -n "${ORIG_BACKUP}"  && -f "${ORIG_BACKUP}"  ]] && ok "…and so is its merge baseline" || bad "no baseline backup"

# Step 0: the merge rewrites both — the config gains a released field and the
# baseline advances to the release that carried it.
printf '%s' '{"kind":"machine","address":"a.b","backup":{"filesystemPaths":["/etc","/root"]}}' > "${CONFIG_DIR}/m.json"
printf '%s' '{"kind":"machine","backup":{"filesystemPaths":["/etc","/root"]}}'                 > "${CONFIG_DIR}/m.json.orig"

# A later step fails, so the update rolls the config back.
restore_module_config m >/dev/null 2>&1

_cfg="$(jq -c '.backup.filesystemPaths' "${CONFIG_DIR}/m.json")"
_org="$(jq -c '.backup.filesystemPaths // "absent"' "${CONFIG_DIR}/m.json.orig")"
[[ "${_cfg}" == '["/etc"]' ]] && ok "the config is back to its pre-update content" || bad "config is ${_cfg}"
[[ "${_org}" == '"absent"' ]] \
    && ok "the baseline went back with it, so the next merge re-adopts what this one discarded" \
    || bad "the baseline stayed advanced (${_org}) — the next merge would read the release's own fields as operator deletions"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
