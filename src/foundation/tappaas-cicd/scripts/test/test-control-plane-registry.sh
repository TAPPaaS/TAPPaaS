#!/usr/bin/env bash
# test-control-plane-registry.sh — components.json is the one list of the
# control plane's standard components (ADR-035 D5), and the registry is written
# from it. Offline: a temp config dir, no site.
#
#   1. every controller/ and manager/ directory is listed, and every listed path exists
#   2. its packages are exactly flake.nix's packages
#   3. its help-json managers are the console's fallback list (ui/src/manifest.ts)
#   4. control-plane-registry.sh writes the standard entries, keeps a module's,
#      replaces stale standard ones, and --check writes nothing
#
# Exits 1 if any assertion fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
C="${CICD}/components.json"
PASS=0; FAIL=0
pass() { printf '  \xe2\x9c\x93 %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL + 1)); }
ck() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 — expected '$2', got '$3'"; fi; }

echo "[1] every component directory is listed"
listed="$(jq -r '.components[].path' "${C}" | sort)"
dirs="$(cd "${CICD}" && for d in controller/*/ manager/*/; do [[ -d "${d}" ]] && echo "${d%/}"; done | sort)"
missing="$(comm -13 <(echo "${listed}") <(echo "${dirs}") | paste -sd' ' -)"
ck "no controller/ or manager/ directory missing from components.json" "" "${missing}"
gone=""
for p in ${listed}; do [[ -d "${CICD}/${p}" ]] || gone+="${p} "; done
ck "every listed path exists" "" "${gone% }"
ck "names are unique" "0" "$(jq -r '.components[].name' "${C}" | sort | uniq -d | wc -l | tr -d ' ')"

echo "[2] packages equal flake.nix's"
flake="$(sed -n '/packages\.\${system} = {/,/};/p' "${CICD}/flake.nix" | grep -oE '^\s+[a-z][a-z0-9-]*\s*=' | tr -d ' =' | sort | paste -sd' ' -)"
pkgs="$(jq -r '.components[] | .package // empty' "${C}" | sort | paste -sd' ' -)"
ck "the packages components.json names are flake.nix's packages" "${flake}" "${pkgs}"
[[ -n "${flake}" ]] && pass "flake.nix's package list was read ($(wc -w <<<"${flake}" | tr -d ' ') packages)" || fail "could not read flake.nix's packages"

echo "[3] the console's fallback is the standard help-json managers"
ts="$(sed -n '/export const TS_MANAGERS = \[/,/\];/p' "${CICD}/ui/src/manifest.ts" | grep -oE '"[a-z-]+"' | tr -d '"' | sort | paste -sd' ' -)"
hj="$(jq -r '.components[] | select(.kind == "manager" and .manifest == "help-json") | .name' "${C}" | sort | paste -sd' ' -)"
ck "TS_MANAGERS = components.json's help-json managers" "${hj}" "${ts}"

echo "[4] the registry writer"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
REG="${T}/control-plane.json"
cat > "${REG}" <<'EOF'
{"version":1,"components":[
 {"name":"foo-controller","kind":"controller","module":"foo","source":"/x/foo/controller/foo-controller","plugsInto":["switch-manager"],"instances":["foo"]},
 {"name":"retired-manager","kind":"manager","module":"tappaas-cicd","source":"/x"}]}
EOF
out="$(CONFIG_DIR="${T}" bash "${CICD}/scripts/control-plane-registry.sh" --check)"
ck "--check prints a registry" "1" "$(jq -r .version <<<"${out}")"
ck "--check writes nothing" "retired-manager" "$(jq -r '[.components[] | select(.module == "tappaas-cicd") | .name] | join(",")' "${REG}")"
CONFIG_DIR="${T}" bash "${CICD}/scripts/control-plane-registry.sh" >/dev/null 2>&1; rc=$?
ck "writes (rc)" "0" "${rc}"
ck "every standard component is an entry" "$(jq '.components | length' "${C}")" "$(jq '[.components[] | select(.module == "tappaas-cicd")] | length' "${REG}")"
ck "a module's entry is kept as it was" "foo-controller foo" "$(jq -r '.components[] | select(.module == "foo") | "\(.name) \(.instances[0])"' "${REG}")"
ck "a standard entry no longer in components.json is gone" "0" "$(jq '[.components[] | select(.name == "retired-manager")] | length' "${REG}")"
ck "an entry carries its source directory" "${CICD}/manager/module-manager" "$(jq -r '.components[] | select(.name == "module-manager") | .source' "${REG}")"
ck "…and its manifest kind" "help-json" "$(jq -r '.components[] | select(.name == "module-manager") | .manifest' "${REG}")"
ck "…a module's controller keeps what it plugs into" "switch-manager" "$(jq -r '.components[] | select(.name == "foo-controller") | .plugsInto | join(",")' "${REG}")"
ck "…and a renamed component's old names" "switch-controller" "$(jq -r '.components[] | select(.name == "switch-manager") | .aliases | join(",")' "${REG}")"
ck "the lock file is beside it" "yes" "$([[ -e "${REG}.lock" ]] && echo yes || echo no)"
printf '{not json' > "${T}/components.json"
ck "a broken components.json is refused (rc)" "1" "$(CICD_DIR="${T}" CONFIG_DIR="${T}" bash "${CICD}/scripts/control-plane-registry.sh" >/dev/null 2>&1; echo $?)"

echo
echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
