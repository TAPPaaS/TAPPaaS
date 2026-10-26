#!/usr/bin/env bash
#
# The config and its merge baseline are restored together (#688), and the
# copies they are restored from live exactly as long as the run: removed on
# every exit, kept only when a restore from them failed.
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
# The backups land under TMPDIR, so this suite's go with ${W} rather than
# piling up in /tmp (94 of them did, on the test site, before this).
export TMPDIR="${W}"
CONFIG_DIR="${W}/config"; mkdir -p "${CONFIG_DIR}"
printf '%s' '{"kind":"machine","address":"a.b","backup":{"filesystemPaths":["/etc"]}}' > "${CONFIG_DIR}/m.json"
printf '%s' '{"kind":"machine"}'                                                        > "${CONFIG_DIR}/m.json.orig"

# The two functions under test, with the logging they expect.
info(){ :; }; debug(){ :; }; warn(){ echo "WARN: $*" >&2; }; fatal(){ echo "FATAL: $*" >&2; exit 1; }
GN=""; CL=""; BL=""
CONFIG_BACKUP=""; ORIG_BACKUP=""; KEEP_CONFIG_BACKUP=0; PRE_TEST_LOG=""; CONFIG_BACKUP_WHAT="pre-update"
eval "$(sed -n '/^backup_module_config() {/,/^}/p' "${UM}")"
eval "$(sed -n '/^restore_module_config() {/,/^}/p' "${UM}")"
eval "$(sed -n '/^cleanup_update_files() {/,/^}/p' "${UM}")"
declare -F backup_module_config >/dev/null || { echo "could not load the functions from ${UM}"; exit 2; }
declare -F cleanup_update_files >/dev/null || { echo "could not load cleanup_update_files from ${UM}"; exit 2; }

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

# ── the copies live as long as the run ───────────────────────────────
[[ "${CONFIG_BACKUP}" == "${W}/"* && "${ORIG_BACKUP}" == "${W}/"* ]] \
    && ok "the copies go under TMPDIR, not a fixed /tmp" || bad "copies at ${CONFIG_BACKUP} / ${ORIG_BACKUP}"
_cb="${CONFIG_BACKUP}"; _ob="${ORIG_BACKUP}"
cleanup_update_files
[[ ! -e "${_cb}" && ! -e "${_ob}" ]] \
    && ok "on exit after a restore that worked, both copies are removed" || bad "copies survived the run: $(ls "${W}" | grep tappaas- | tr '\n' ' ')"

# A run that never restores (the update succeeded) leaves nothing either.
backup_module_config m; _cb="${CONFIG_BACKUP}"; _ob="${ORIG_BACKUP}"
cleanup_update_files
[[ ! -e "${_cb}" && ! -e "${_ob}" ]] && ok "a successful update leaves no copy behind" || bad "a successful update left its copies"

# A restore that FAILS keeps them: they are the operator's only pre-update copy.
backup_module_config m; _cb="${CONFIG_BACKUP}"
chmod 0500 "${CONFIG_DIR}"; chmod 0400 "${CONFIG_DIR}/m.json"
_msg="$( (restore_module_config m) 2>&1 )"
( KEEP_CONFIG_BACKUP=0; restore_module_config m >/dev/null 2>&1; cleanup_update_files )
chmod 0700 "${CONFIG_DIR}"; chmod 0600 "${CONFIG_DIR}/m.json"
if [[ ${EUID} -eq 0 ]]; then
    echo "  ⊘ running as root: a failed restore cannot be staged with file modes (skipped)"
else
    [[ -e "${_cb}" ]] && ok "a restore that failed keeps the copy" || bad "the only pre-update copy was deleted after a failed restore"
    [[ "${_msg}" == *"${_cb}"*"kept"* ]] && ok "…and the error says where it is" || bad "failure message: ${_msg}"
fi
rm -f "${_cb}" "${ORIG_BACKUP}"

# ── a rolled-back `modify --set` leaves no --set behind ──────────────
# modify writes the field before it runs the update, and hands over its copy
# from before that write. Seen on makerfloss: `--set node=tappaas2` stayed in
# logging.json after the update rolled back.
printf '%s' '{"kind":"machine","node":"tappaas1"}' > "${W}/pre.json"
printf '%s' '{"kind":"machine"}'                   > "${W}/pre.json.orig"
printf '%s' '{"kind":"machine","node":"tappaas2"}' > "${CONFIG_DIR}/m.json"
TAPPAAS_PRE_MODIFY_CONFIG="${W}/pre.json" TAPPAAS_PRE_MODIFY_ORIG="${W}/pre.json.orig" backup_module_config m
restore_module_config m >/dev/null 2>&1
[[ "$(jq -r .node "${CONFIG_DIR}/m.json")" == tappaas1 ]] \
    && ok "a rolled-back modify restores the config from before its --set" || bad "node is $(jq -r .node "${CONFIG_DIR}/m.json") after the rollback"
[[ "${CONFIG_BACKUP_WHAT}" == pre-modify ]] && ok "…and says so" || bad "restore calls it ${CONFIG_BACKUP_WHAT}"
cleanup_update_files; CONFIG_BACKUP_WHAT="pre-update"

# The real script wires it: one EXIT trap, and it is this function.
[[ "$(grep -c '^trap ' "${UM}")" == 1 ]] && grep -q '^trap cleanup_update_files EXIT$' "${UM}" \
    && ok "update-module.sh runs cleanup_update_files on every exit" || bad "update-module.sh does not trap cleanup_update_files on EXIT"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
