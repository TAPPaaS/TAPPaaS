#!/usr/bin/env bash
# test-self-prepare.sh — update-tappaas.service's prepare step (ADR-017 D3/D4).
# A stub refresh stands in for refresh-control-plane.sh: it records whether the
# pull was skipped and exits with the code the case asks for.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="${HERE}/../tappaas-self-prepare.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

d="$(mktemp -d)"; trap 'rm -rf "${d}"' EXIT
mkdir -p "${d}/config"
cat > "${d}/refresh" <<'STUB'
#!/usr/bin/env bash
echo "${TAPPAAS_NO_GIT_PULL:-0}" > "${STUB_SEEN}"
exit "${STUB_RC:-0}"
STUB
chmod +x "${d}/refresh"
export TAPPAAS_CONFIG_DIR="${d}/config" TAPPAAS_REFRESH_CMD="${d}/refresh" STUB_SEEN="${d}/seen"
run() { rm -rf "${d}/run"; RUNTIME_DIRECTORY="${d}/run" bash "${P}" >/dev/null 2>&1; echo $?; }

# refreshed, no request
ck "rc 0 → the step succeeds"      0 "$(STUB_RC=0 run)"
ck "…and hands over 'refreshed'"   refreshed "$(cat "${d}/run/control-plane" 2>/dev/null)"
ck "…with the prepared marker"     yes "$([[ -e "${d}/run/prepared" ]] && echo yes)"
ck "…and the next stage recorded"  rebuild "$(cat "${d}/config/.update-stage")"
ck "…and the pull is not skipped"  0 "$(cat "${STUB_SEEN}")"

# stale builds are not fatal (#595)
ck "rc 10 → succeeds"              0 "$(STUB_RC=10 run)"
ck "…as 'stale'"                   stale "$(cat "${d}/run/control-plane")"

# a repository that did not sync, or an unusable checkout, is fatal
ck "rc 12 → fails the unit"        1 "$(STUB_RC=12 run)"
ck "…no prepared marker"           no "$([[ -e "${d}/run/prepared" ]] && echo yes || echo no)"
ck "…stage stays 'prepare'"        prepare "$(cat "${d}/config/.update-stage")"
ck "rc 1 → fails the unit"         1 "$(STUB_RC=1 run)"

# the request: claimed once, noGitPull applied
echo '{"force": false, "noGitPull": true, "requestedBy": "lars"}' > "${d}/config/.update-request.json"
ck "a request is claimed"          0 "$(STUB_RC=0 run)"
ck "…moved into the run directory" lars "$(jq -r .requestedBy "${d}/run/request.json")"
ck "…and gone from config"         gone "$([[ -e "${d}/config/.update-request.json" ]] && echo left || echo gone)"
ck "…noGitPull skips the pull"     1 "$(cat "${STUB_SEEN}")"

# a stale request is dropped
echo '{"noGitPull": true}' > "${d}/config/.update-request.json"
touch -d '-1 hour' "${d}/config/.update-request.json"
ck "an old request is discarded"   0 "$(STUB_RC=0 run)"
ck "…not applied"                  0 "$(cat "${STUB_SEEN}")"
ck "…and removed"                  gone "$([[ -e "${d}/config/.update-request.json" ]] && echo left || echo gone)"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
