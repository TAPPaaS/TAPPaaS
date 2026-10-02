#!/usr/bin/env bash
# test-ssh-key-only.sh — key-only SSH on machines, without a machine (#19, #756).
#
#   1. ssh-key-only.sh against a stub sshd/systemctl: apply writes the drop-in and
#      reloads once; a second apply changes nothing; a configuration `sshd -t`
#      rejects is rolled back; an sshd_config that overrides the drop-in is
#      reported, not assumed; check reads what sshd enforces; remove deletes only
#      the drop-in TAPPaaS wrote.
#   2. debianhost: sshKeyOnly is true when absent, false only when it says false;
#      converge applies or removes accordingly.
#   3. copy-update-json.sh: a boolean override lands as a JSON boolean (it was the
#      string "false"), and a non-boolean is refused.
#
# The live half — a real Debian machine adopted, hardened, opened again — is in
# docs/design/debianhost-test-plan.md, phase 3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
FOUNDATION="$(cd "${CICD}/.." && pwd)"
KO="${CICD}/scripts/ssh-key-only.sh"
command -v jq >/dev/null 2>&1 || { echo "jq not found — cannot run here."; exit 77; }

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
has() { [[ "$2" == *"$1"* ]] && echo yes || echo no; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/kossh.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# ── stubs: sshd and systemctl ─────────────────────────────────────────
# sshd -T reports key-only exactly when the drop-in holds the three settings —
# unless FAKE_OVERRIDE=1, which plays an sshd_config line that wins over it.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/sshd" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -t) exit "${FAKE_SSHD_T_RC:-0}" ;;
  -T)
    if [[ "${FAKE_OVERRIDE:-0}" != 1 && -f "${SSH_KEY_ONLY_DROPIN}" ]] && grep -q '^PasswordAuthentication no' "${SSH_KEY_ONLY_DROPIN}"; then
        printf 'permitrootlogin without-password\npasswordauthentication no\nkbdinteractiveauthentication no\n'
    else
        printf 'permitrootlogin without-password\npasswordauthentication yes\nkbdinteractiveauthentication no\n'
    fi ;;
esac
STUB
cat > "${TMP}/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_SYSTEMCTL_LOG}"
STUB
chmod +x "${TMP}/bin/sshd" "${TMP}/bin/systemctl"

export SSH_KEY_ONLY_DROPIN="${TMP}/etc/ssh/sshd_config.d/10-tappaas-hardening.conf"
export FAKE_SYSTEMCTL_LOG="${TMP}/systemctl.log"
ko() { PATH="${TMP}/bin:${PATH}" bash "${KO}" "$@" 2>&1; }
reloads() { [[ -f "${FAKE_SYSTEMCTL_LOG}" ]] || { echo 0; return; }; grep -c '^reload' "${FAKE_SYSTEMCTL_LOG}"; true; }

echo "── 1. ssh-key-only.sh ──"
out="$(ko apply)"; rc=$?
ck "apply succeeds"                               0 "${rc}"
ck "…writes the drop-in"                          yes "$([[ -f "${SSH_KEY_ONLY_DROPIN}" ]] && echo yes || echo no)"
ck "…with the three settings"                     3 "$(grep -c -E '^(PermitRootLogin prohibit-password|PasswordAuthentication no|KbdInteractiveAuthentication no)$' "${SSH_KEY_ONLY_DROPIN}")"
ck "…marked as TAPPaaS's"                         yes "$(head -1 "${SSH_KEY_ONLY_DROPIN}" | grep -q '^# Managed by TAPPaaS' && echo yes || echo no)"
ck "…and reloads sshd once"                       1 "$(reloads)"
out="$(ko apply)"; rc=$?
ck "a second apply succeeds"                      0 "${rc}"
ck "…changes nothing"                             yes "$(has "already key-only" "${out}")"
ck "…and does not reload"                         1 "$(reloads)"
out="$(ko check)"; rc=$?
ck "check: key-only is reported"                  0 "${rc}"

: > "${FAKE_SYSTEMCTL_LOG}"; rm -f "${SSH_KEY_ONLY_DROPIN}"
out="$(FAKE_SSHD_T_RC=1 ko apply)"; rc=$?
ck "a configuration sshd -t rejects fails"        1 "${rc}"
ck "…rolls back to no drop-in"                    no "$([[ -f "${SSH_KEY_ONLY_DROPIN}" ]] && echo yes || echo no)"
ck "…and never reloads"                           0 "$(reloads)"
echo "PasswordAuthentication yes" > "${SSH_KEY_ONLY_DROPIN}"
FAKE_SSHD_T_RC=1 ko apply >/dev/null
ck "a rejected change restores the previous file" "PasswordAuthentication yes" "$(cat "${SSH_KEY_ONLY_DROPIN}")"

rm -f "${SSH_KEY_ONLY_DROPIN}"
out="$(FAKE_OVERRIDE=1 ko apply)"; rc=$?
ck "an sshd_config that overrides the drop-in fails" 1 "${rc}"
ck "…and names the setting"                       yes "$(has "passwordauthentication is 'yes'" "${out}")"
out="$(FAKE_OVERRIDE=1 ko check)"; rc=$?
ck "check fails when passwords are accepted"      1 "${rc}"

ko apply >/dev/null
: > "${FAKE_SYSTEMCTL_LOG}"
out="$(ko remove)"; rc=$?
ck "remove succeeds"                              0 "${rc}"
ck "…deletes the drop-in"                         no "$([[ -f "${SSH_KEY_ONLY_DROPIN}" ]] && echo yes || echo no)"
ck "…reloads"                                     1 "$(reloads)"
ck "…and says what the machine's own setting is"  yes "$(has "now 'yes'" "${out}")"
out="$(ko remove)"; rc=$?
ck "remove with nothing to remove is fine"        0 "${rc}"
echo "PasswordAuthentication no  # the owner's own" > "${SSH_KEY_ONLY_DROPIN}"
out="$(ko remove)"; rc=$?
ck "a drop-in TAPPaaS did not write is refused"   1 "${rc}"
ck "…and left exactly as it was"                  "PasswordAuthentication no  # the owner's own" "$(cat "${SSH_KEY_ONLY_DROPIN}")"
out="$(ko sideways)"; rc=$?
ck "an unknown mode is a usage error"             2 "${rc}"
out="$(env -u SSH_KEY_ONLY_DROPIN bash "${KO}" check 2>&1)"; rc=$?
if [[ ${EUID} -ne 0 ]]; then ck "without root it refuses"  1 "${rc}"; fi

echo "── 2. debianhost decides from sshKeyOnly ──"
dh() {   # $1 = the config JSON; then a command run with the lib loaded
    local json="$1"; shift
    ( info() { echo "$*"; }; error() { echo "$*" >&2; }; GN=""; CL=
      JSON="${json}"
      get_config_value() { jq -r --arg k "$1" --arg d "${2-}" 'if has($k) then .[$k] | tostring else $d end' <<<"${JSON}"; }
      . "${FOUNDATION}/debianhost/lib/debianhost-lib.sh"
      dh_key_only() { echo "MODE=$1"; echo "sshd: ok"; }
      INSTANCE=t; "$@" )
}
ck "no field → key-only wanted"                   yes "$(dh '{}' dh_key_only_wanted && echo yes || echo no)"
ck "true → wanted"                                yes "$(dh '{"sshKeyOnly":true}' dh_key_only_wanted && echo yes || echo no)"
ck "false → not wanted"                           no "$(dh '{"sshKeyOnly":false}' dh_key_only_wanted && echo yes || echo no)"
ck "converge applies when wanted"                 yes "$(has "key-only SSH" "$(dh '{}' dh_key_only_converge 2>&1)")"
ck "converge removes when false"                  yes "$(has "sshKeyOnly is false" "$(dh '{"sshKeyOnly":false}' dh_key_only_converge 2>&1)")"
ck "the script the lib feeds exists"              yes "$( . "${FOUNDATION}/debianhost/lib/debianhost-lib.sh"; [[ -f "${DH_KEY_ONLY_SCRIPT}" ]] && echo yes || echo no )"

echo "── 3. copy-update-json.sh types a boolean override ──"
CUJ="${CICD}/manager/module-manager/copy-update-json.sh"
mkdir -p "${TMP}/mod" "${TMP}/cfg"
echo '{"description":"m","kind":"machine"}' > "${TMP}/mod/m.json"
echo '{"fields":{"description":{"type":"string"},"kind":{"type":"string"},"sshKeyOnly":{"type":"boolean"},"moduleSource":{"type":"string"}}}' > "${TMP}/schema.json"
cuj() { ( cd "${TMP}/mod" && CONFIG_DIR="${TMP}/cfg" SCHEMA_FILE="${TMP}/schema.json" bash "${CUJ}" m "$@" ) >/dev/null 2>&1; }
cuj --sshKeyOnly false
ck "--sshKeyOnly false lands as JSON false"       boolean "$(jq -r '.sshKeyOnly | type' "${TMP}/cfg/m.json" 2>/dev/null)"
ck "…with the value false"                        false "$(jq -r '.sshKeyOnly' "${TMP}/cfg/m.json" 2>/dev/null)"
rm -f "${TMP}/cfg/m.json"*
cuj --sshKeyOnly maybe; rc=$?
ck "a boolean field refuses 'maybe'"              1 "$([[ ${rc} -ne 0 ]] && echo 1 || echo 0)"

echo
echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
