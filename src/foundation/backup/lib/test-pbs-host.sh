#!/usr/bin/env bash
#
# Unit tests for "something patches the PBS's Host" (#603) — pbs-host.sh.
# Cluster membership, module_of and adopt-module.sh are stubbed, so the test
# asserts the decision: a cluster node is the cluster module's; a registered
# machine is its instance's; an unregistered machine is adopted; a failed
# adopt is `none`, said loudly and never fatal; an unreachable cluster is
# `unknown`, and nothing is adopted on a guess.
#
# Usage: ./test-pbs-host.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info() { echo "info: $*"; }; warn() { echo "warn: $*"; }; debug() { :; }
export GN="" CL=""   # read by the sourced library

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pbshost.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export CONFIG_DIR="${TMP}/config"; mkdir -p "${CONFIG_DIR}" "${TMP}/bin"
ADOPTED="${TMP}/adopted"

MEMBER_RC=1
pbs_node_is_cluster_member() { return "${MEMBER_RC}"; }
module_of() { jq -r '.module // empty' "${CONFIG_DIR}/$1.json" 2>/dev/null; }
ADOPT_RC=0
cat > "${TMP}/bin/adopt-module.sh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "${ADOPTED}"; exit \${ADOPT_RC:-0}
SH
chmod +x "${TMP}/bin/adopt-module.sh"; export PATH="${TMP}/bin:${PATH}"

# shellcheck source=pbs-host.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-host.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
owner() { : > "${ADOPTED}"; pbs_host_owner "$@"; echo " rc=$?"; }

MEMBER_RC=0; ck "a cluster node → the cluster module"   "cluster rc=0"    "$(owner tappaas3 mgmt | tr -d '\n')"
ck "…and nothing is adopted"                         "" "$(cat "${ADOPTED}")"

MEMBER_RC=1; echo '{"module":"debianhost"}' > "${CONFIG_DIR}/dh-test1.json"
ck "a registered machine → its instance's module"    "debianhost rc=0" "$(owner dh-test1 mgmt | tr -d '\n')"
ck "…and nothing is adopted"                         "" "$(cat "${ADOPTED}")"

ck "an unregistered machine → adopted"               "adopted rc=0"    "$(owner pbsbox mgmt | tr -d '\n')"
ck "…by its mgmt name, never waiting for a key"      "pbsbox.mgmt.internal --wait 0" "$(cat "${ADOPTED}")"

export ADOPT_RC=1
ck "adopt fails → none (rc 1)"                       "none rc=1"       "$(owner pbsbox mgmt | tr -d '\n')"
out="$(pbs_host_ensure_patched pbsbox mgmt 2>&1)"
[[ "${out}" == *"NOTHING PATCHES the PBS host pbsbox"*"module adopt <ip-or-fqdn of pbsbox>"* ]] \
    && ck "…said loudly, with the command" ok ok || ck "…said loudly, with the command" ok "got: ${out}"
export ADOPT_RC=0

MEMBER_RC=2; ck "cluster unreachable → unknown (rc 2)" "unknown rc=2"  "$(owner pbsbox mgmt | tr -d '\n')"
ck "…and nothing is adopted on a guess"              "" "$(cat "${ADOPTED}")"

ck "no Host at all → none"                           "none rc=1"       "$(owner "" mgmt | tr -d '\n')"

# pbs_host_path_ensure (ADR-010 §8.4.3): a PBS Host whose module ships
# pbs-path.sh is asked to open the nodes' path; one without is left alone.
mkdir -p "${TMP}/mods/satellite" "${TMP}/mods/debianhost"
printf '#!/usr/bin/env bash\necho "$1 $2 $(pwd)" > "%s/path"\nexit ${PATH_RC:-0}\n' "${TMP}" > "${TMP}/mods/satellite/pbs-path.sh"
chmod +x "${TMP}/mods/satellite/pbs-path.sh"
get_module_dir() { jq -r '.moduleSource // empty' "${CONFIG_DIR}/$1.json"; }
echo "{\"moduleSource\":\"${TMP}/mods/satellite\"}" > "${CONFIG_DIR}/sat1.json"
echo "{\"moduleSource\":\"${TMP}/mods/debianhost\"}" > "${CONFIG_DIR}/dh2.json"
pbs_host_path_ensure sat1 >/dev/null; rc=$?
ck "a satellite Host: its pbs-path.sh opens the path, from its module dir" "sat1 open ${TMP}/mods/satellite rc=0" "$(cat "${TMP}/path" 2>/dev/null) rc=${rc}"
rm -f "${TMP}/path"
pbs_host_path_ensure dh2 >/dev/null; rc=$?
ck "a Host whose module has no pbs-path.sh: nothing to do"   "absent rc=0" "$([[ -e "${TMP}/path" ]] && echo present || echo absent) rc=${rc}"
pbs_host_path_ensure tappaas3 >/dev/null; rc=$?
ck "a cluster node (no instance config): nothing to do"      "absent rc=0" "$([[ -e "${TMP}/path" ]] && echo present || echo absent) rc=${rc}"
PATH_RC=3 pbs_host_path_ensure sat1 >/dev/null; rc=$?
ck "a failed open is passed on"                              "3" "${rc}"

echo ""
echo "pbs-host: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
