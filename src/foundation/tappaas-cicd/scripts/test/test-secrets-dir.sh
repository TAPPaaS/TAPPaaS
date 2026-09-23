#!/usr/bin/env bash
#
# test-secrets-dir.sh — writers leave /etc/secrets' mode to its owner, and the
# OIDC credentials never ride a command line (#715).
#
# /etc/secrets is shared: each module's tmpfiles rule sets its mode, and
# logging.nix makes it 0750 root:grafana so Grafana can read its own files.
# identity's OIDC delivery ran `install -d -m 700` on it — which re-modes an
# EXISTING directory — and Grafana crash-looped on its admin-password file
# (hrossen, 2026-09-23). The same call carried the client secret inside
# `sudo sh -c '…'`, and sudo logs every command line: the guest's journal held
# the secret in clear.
#
# identity's delivery block is lifted out of its install-service and run
# against stubbed ssh/sudo on a scratch directory; a grep guard keeps the
# re-moding writers from coming back.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_TREE="$(cd "${HERE}/../../../.." && pwd)"
IDS="${SRC_TREE}/foundation/identity/services/identity/install-service.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${IDS}" ]] || { echo "identity install-service.sh not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/secrets-dir.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# The delivery: from the credentials' env content to its error branch.
awk '/^ENV_CONTENT="\$\(printf/{f=1} f{print} f&&/^fi$/{exit}' "${IDS}" > "${TMP}/deliver.sh"
ck "identity's delivery block extracts and parses" "yes" \
   "$(grep -q 'OIDC_CLIENT_SECRET' "${TMP}/deliver.sh" && bash -n "${TMP}/deliver.sh" 2>/dev/null && echo yes || echo no)"

# sudo: record the argv it was given (what the guest's journal would log),
# then run it. ssh: run the remote command in a shell here, stdin passed on.
BIN="${TMP}/bin"; mkdir -p "${BIN}"
cat > "${BIN}/sudo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TMP}/sudo-argv"
exec "\$@"
EOF
chmod +x "${BIN}/sudo"

run_delivery() {  # <secrets dir> — delivers into <dir>/logging.env
    SD="$1" D="${TMP}/deliver.sh" PATH="${BIN}:${PATH}" bash -c '
        set -uo pipefail
        debug(){ :; }; warn(){ :; }; die(){ echo "DIE: $*" >&2; exit 1; }
        GN=""; CL=""
        ssh() { local a; while [[ $# -gt 1 ]]; do shift; done; bash -c "$1"; }
        UPSTREAM=logging.example.internal
        SECRETS_ENV="${SD}/logging.env"
        CLIENT_ID=cid-123 CLIENT_SECRET=s3cr3t-value DISCOVERY_URI=https://id.example.org/.well-known
        . "${D}"
    '
}

echo "── an existing directory keeps its mode ──"
SD="${TMP}/secrets"; mkdir -p "${SD}"; chmod 750 "${SD}"
printf 'KEEP=1\nOIDC_CLIENT_ID=old\n' > "${SD}/logging.env"
: > "${TMP}/sudo-argv"
run_delivery "${SD}"; rc=$?
ck "the delivery succeeds" "0" "${rc}"
ck "the directory's mode is left as its owner set it (0750)" "750" \
   "$(stat -c %a "${SD}" 2>/dev/null || stat -f %Lp "${SD}")"
ck "co-managed keys survive the merge" "KEEP=1" "$(grep '^KEEP=' "${SD}/logging.env")"
ck "the old OIDC values are replaced, not duplicated" "1" "$(grep -c '^OIDC_CLIENT_ID=' "${SD}/logging.env")"
ck "the new secret is in the file" "OIDC_CLIENT_SECRET=s3cr3t-value" "$(grep '^OIDC_CLIENT_SECRET=' "${SD}/logging.env")"
ck "the file is 0600" "600" "$(stat -c %a "${SD}/logging.env" 2>/dev/null || stat -f %Lp "${SD}/logging.env")"
ck "the secret never appears on a sudo command line" "0" "$(grep -c 's3cr3t-value' "${TMP}/sudo-argv")"

echo "── a missing directory is created 0700 ──"
SD2="${TMP}/fresh/secrets"; mkdir -p "${TMP}/fresh"
run_delivery "${SD2}" >/dev/null 2>&1
ck "created, private" "700" "$(stat -c %a "${SD2}" 2>/dev/null || stat -f %Lp "${SD2}")"

echo "── no writer re-modes an existing /etc/secrets ──"
# `install -d -m N /etc/secrets` changes an existing directory's mode, so it
# must be guarded by `[ -d … ] ||`. A plain chmod of the directory is allowed
# only in backup:filesystem, which documents why its capture user must be able
# to traverse it (0755 keeps every owner's own files reachable).
bad="$(grep -rnE 'install -d -m [0-7]+ ("?/etc/secrets|.*dirname[^)]*SECRETS)' --include='*.sh' "${SRC_TREE}" \
        | grep -v '\[ -d ' | grep -v '/scripts/test/')"
ck "every 'install -d -m' on /etc/secrets is guarded by [ -d ] ||" "" "${bad}"
[[ -n "${bad}" ]] && sed 's/^/      /' <<< "${bad}"
chm="$(grep -rnE 'chmod [0-7]+ /etc/secrets([^/]|$)' --include='*.sh' "${SRC_TREE}" \
        | grep -v '/backup/services/filesystem/install-service.sh:' | grep -v '/scripts/test/')"
ck "no script chmods /etc/secrets itself (backup:filesystem excepted)" "" "${chm}"

echo "── Grafana re-asserts its own rule on every start ──"
grep -q '"+${pkgs.systemd}/bin/systemd-tmpfiles --create --prefix=/etc/secrets"' \
    "${SRC_TREE}/foundation/logging/logging.nix" \
    && ck "logging.nix: ExecStartPre runs tmpfiles for /etc/secrets as root" "yes" "yes" \
    || ck "logging.nix: ExecStartPre runs tmpfiles for /etc/secrets as root" "yes" "no"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
