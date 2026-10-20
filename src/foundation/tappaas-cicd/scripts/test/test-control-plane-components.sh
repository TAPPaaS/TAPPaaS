#!/usr/bin/env bash
#
# Offline tests for lib/control-plane-components.sh — a module's own controllers
# and managers (ADR-035 D3, D5, D7): register, two copies of one module, the
# refusals, a failed install, the trust warning, unregister and relink.
#
# Usage: ./test-control-plane-components.sh — exit 0 all passed, 1 otherwise.

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CICD="$(dirname "$(dirname "${HERE}")")"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; PASS=$((PASS + 1)); else echo "  ✗ $1 (expected '$2', got '$3')"; FAIL=$((FAIL + 1)); fi; }
has() { grep -qF -- "$2" <<<"$1" && echo yes || echo no; }

T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "${T}"' EXIT
export CONFIG_DIR="${T}/config" TAPPAAS_BIN="${T}/bin" TAPPAAS_GCROOTS="${T}/gcroots"
mkdir -p "${CONFIG_DIR}/sbom" "${TAPPAAS_BIN}" "${TAPPAAS_GCROOTS}"
REG="${CONFIG_DIR}/control-plane.json"
cat > "${REG}" <<'EOF'
{"version":1,"components":[
 {"name":"switch-manager","kind":"manager","module":"tappaas-cicd","source":"/x/switch-manager","aliases":["switch-controller"]},
 {"name":"ap-manager","kind":"manager","module":"tappaas-cicd","source":"/x/ap-manager"}]}
EOF
echo "{\"repositories\":[{\"name\":\"Community\",\"path\":\"${T}/Community\"}]}" > "${CONFIG_DIR}/site.json"
echo '{"repositories":[{"name":"Community","status":"unsigned-unstable"}]}' > "${CONFIG_DIR}/sbom/signatures.json"

# A module with one controller whose install.sh links it (as unifi-os has).
mkmod() { # mkmod <dir> <module> <controller> [install-rc]
    local d="$1/$2" c="$3"
    mkdir -p "${d}/controller/${c}"
    printf '{"version":"1.2.0","controllers":[{"name":"%s","path":"controller/%s","plugsInto":["switch-manager","ap-manager"]}]}\n' "${c}" "${c}" > "${d}/$2.json"
    printf '#!/usr/bin/env bash\necho run >> "%s/installs"\nln -sfn "%s/%s" "${TAPPAAS_BIN}/%s"\nexit %s\n' \
        "${d}" "${d}/controller/${c}" "${c}" "${c}" "${4:-0}" > "${d}/controller/${c}/install.sh"
    printf '#!/usr/bin/env bash\necho {}\n' > "${d}/controller/${c}/${c}"
    echo '{"contracts":["switch/1"]}' > "${d}/controller/${c}/contract.json"
    chmod +x "${d}/controller/${c}/install.sh" "${d}/controller/${c}/${c}"
}
run() { ( . "${CICD}/lib/control-plane-components.sh"; "$@" ) 2>&1; }
rc_of() { ( . "${CICD}/lib/control-plane-components.sh"; "$@" ) >/dev/null 2>&1; echo $?; }
entry() { jq -c --arg n "$1" '.components[] | select(.name == $n)' "${REG}"; }

echo "test-control-plane-components:"
M="${T}/Community/src/u/network"; mkmod "${M}" unifi-os unifi-controller

echo "[1] register"
out="$(run cpc_register "${M}/unifi-os" unifi-os unifi-os)"; rc=$?
ck "registers (rc)" "0" "${rc}"
ck "its install.sh ran and linked it" "${M}/unifi-os/controller/unifi-controller/unifi-controller" "$(readlink "${TAPPAAS_BIN}/unifi-controller")"
e="$(entry unifi-controller)"
ck "…the entry: module, kind, source" "unifi-os controller ${M}/unifi-os/controller/unifi-controller" "$(jq -r '"\(.module) \(.kind) \(.source)"' <<<"${e}")"
ck "…what it plugs into, its contract, the version" "switch-manager,ap-manager switch/1 1.2.0" "$(jq -r '"\(.plugsInto | join(",")) \(.contracts | join(",")) \(.version)"' <<<"${e}")"
ck "…the repository, not verified" "Community false" "$(jq -r '"\(.repository) \(.verified)"' <<<"${e}")"
ck "…the instance" '["unifi-os"]' "$(jq -c .instances <<<"${e}")"
ck "the standard entries are kept" "2" "$(jq '[.components[] | select(.module == "tappaas-cicd")] | length' "${REG}")"
ck "unverified + foundation manager: warned (D7)" "yes" "$(has "${out}" "whose release is not verified, and plugs into the foundation's switch-manager, ap-manager")"
ck "the registry is readable by all" "644" "$(stat -c %a "${REG}" 2>/dev/null || stat -f %Lp "${REG}")"

echo "[2] two copies of one module"
run cpc_register "${M}/unifi-os" unifi-os unifi-os-lab >/dev/null; rc=$?
ck "the second instance registers (rc)" "0" "${rc}"
ck "…one entry, both instances" '[1,["unifi-os","unifi-os-lab"]]' "$(jq -c '[.components[] | select(.name == "unifi-controller")] | [length, .[0].instances]' "${REG}")"
ck "…its install ran again, to the same result" "2" "$(wc -l < "${M}/unifi-os/installs" | tr -d ' ')"
run cpc_register "${M}/unifi-os" unifi-os unifi-os >/dev/null
ck "an update of an instance does not add it twice" '["unifi-os","unifi-os-lab"]' "$(entry unifi-controller | jq -c .instances)"

echo "[3] refusals (D3, D5)"
O="${T}/Community/src/other"; mkmod "${O}" unifi-alt unifi-controller
before="$(md5sum < "${REG}" 2>/dev/null || md5 -q "${REG}")"
out="$(run cpc_register "${O}/unifi-alt" unifi-alt unifi-alt)"; rc=$?
ck "another module bringing the same controller is refused (rc)" "1" "${rc}"
ck "…naming the module that owns it" "yes" "$(has "${out}" "registered by module 'unifi-os'")"
ck "…the registry unchanged" "${before}" "$(md5sum < "${REG}" 2>/dev/null || md5 -q "${REG}")"
ck "…the link still the owner's" "${M}/unifi-os/controller/unifi-controller/unifi-controller" "$(readlink "${TAPPAAS_BIN}/unifi-controller")"
mkmod "${O}" sneaky switch-controller
out="$(run cpc_register "${O}/sneaky" sneaky sneaky)"; rc=$?
ck "a standard component's name (an alias too) is refused (rc)" "1" "${rc}"
ck "…saying so" "yes" "$(has "${out}" "is a standard component of tappaas-cicd")"
mkmod "${O}" shadow shadow-controller; : > "${TAPPAAS_BIN}/shadow-controller"
out="$(run cpc_register "${O}/shadow" shadow shadow)"; rc=$?
ck "a ~/bin name nobody registered is not shadowed (rc)" "1" "${rc}"
ck "…the file left alone" "yes" "$([[ -f "${TAPPAAS_BIN}/shadow-controller" && ! -L "${TAPPAAS_BIN}/shadow-controller" ]] && echo yes || echo no)"
rm -f "${TAPPAAS_BIN}/shadow-controller"
mkmod "${O}" broken broken-controller 1
out="$(run cpc_register "${O}/broken" broken broken)"; rc=$?
ck "a failed install.sh fails the registration (rc)" "1" "${rc}"
ck "…and takes back the link it made" "no" "$([[ -e "${TAPPAAS_BIN}/broken-controller" ]] && echo yes || echo no)"
ck "…no entry" "" "$(entry broken-controller)"
mkdir -p "${O}/none"; echo '{"version":"1"}' > "${O}/none/none.json"
ck "a module that brings none: nothing to do (rc)" "0" "$(rc_of cpc_register "${O}/none" none none)"

echo "[4] verified (D7)"
echo '{"repositories":[{"name":"Community","status":"verified"}]}' > "${CONFIG_DIR}/sbom/signatures.json"
out="$(run cpc_register "${M}/unifi-os" unifi-os unifi-os)"
ck "a verified repository: no warning" "no" "$(has "${out}" "not verified")"
ck "…recorded as verified" "true" "$(entry unifi-controller | jq -r .verified)"

echo "[5] relink (refresh)"
rm -f "${TAPPAAS_BIN}/unifi-controller"
mkdir -p "${T}/Community/src/gone/controller/old-controller"; : > "${T}/Community/src/gone/controller/old-controller/old-controller"
ln -s "${T}/Community/src/gone/controller/old-controller/old-controller" "${TAPPAAS_BIN}/old-controller"
ln -s /usr/bin/env "${TAPPAAS_BIN}/operators-own"
out="$(run cpc_relink)"; rc=$?
ck "relinks (rc)" "0" "${rc}"
ck "a registered component's missing link is back" "yes" "$([[ -L "${TAPPAAS_BIN}/unifi-controller" ]] && echo yes || echo no)"
ck "a module component's link nobody registers goes" "no" "$([[ -e "${TAPPAAS_BIN}/old-controller" ]] && echo yes || echo no)"
ck "an operator's own link stays" "yes" "$([[ -L "${TAPPAAS_BIN}/operators-own" ]] && echo yes || echo no)"

echo "[6] unregister"
: > "${TAPPAAS_GCROOTS}/unifi-controller"
run cpc_unregister unifi-os-lab >/dev/null; rc=$?
ck "one instance leaves (rc)" "0" "${rc}"
ck "…the entry stays for the other" '["unifi-os"]' "$(entry unifi-controller | jq -c .instances)"
ck "…and so does the link" "yes" "$([[ -L "${TAPPAAS_BIN}/unifi-controller" ]] && echo yes || echo no)"
out="$(run cpc_unregister unifi-os)"
ck "the last instance: the entry goes" "" "$(entry unifi-controller)"
ck "…the link goes" "no" "$([[ -e "${TAPPAAS_BIN}/unifi-controller" || -L "${TAPPAAS_BIN}/unifi-controller" ]] && echo yes || echo no)"
ck "…the GC root goes" "no" "$([[ -e "${TAPPAAS_GCROOTS}/unifi-controller" ]] && echo yes || echo no)"
ck "…the standard entries stay" "2" "$(jq '[.components[] | select(.module == "tappaas-cicd")] | length' "${REG}")"
ck "an instance with nothing registered: nothing to do (rc)" "0" "$(rc_of cpc_unregister nosuch)"

echo ""
echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
