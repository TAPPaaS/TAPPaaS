#!/usr/bin/env bash
# test-gen-stack-readme.sh — each stack's README lists its members and its INSTALL.md
# its modules in install order (#421).
#
# On a throwaway repository: the order follows dependsOn and integratesWith (#501)
# inside the stack, a dependency outside it is named with its stack, a cycle is
# flagged rather than guessed, the README lists members with their status,
# --check reports a stale or missing document without writing, a planned stack
# (no module yet) needs no INSTALL.md, and only the generated blocks are ever
# rewritten. Then the real tree: every stack document is current.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="${HERE}/../gen-stack-readme.py"
command -v python3 >/dev/null 2>&1 || { echo "python3 not found — cannot run here."; exit 77; }

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/stackreadme.XXXXXX")"
trap 'rm -rf "${T}"' EXIT

mod() {  # $1 stack, $2 name, $3 dependsOn JSON, [$4 integratesWith JSON]
    mkdir -p "${T}/src/$1/$2"
    printf '{"description":"the %s module","status":"Testing","stack":"%s","dependsOn":%s,"integratesWith":%s}\n' "$2" "$1" "$3" "${4:-[]}" > "${T}/src/$1/$2/$2.json"
}
mod foundation identity '[]'
mod collaboration files '["identity:identity","cluster:vm"]'
mod collaboration calls '["files:fileservice","relay:turn"]'
mod collaboration relay '["files:fileservice"]'
mod collaboration aaa '["files:fileservice"]' '["relay:turn"]'
mod home loopa '["loopb:x"]'
mod home loopb '["loopa:x"]'
python3 - "${T}" <<'PY'
import json, os, sys
t = sys.argv[1]
mods = [("identity","foundation"),("files","collaboration"),("calls","collaboration"),("relay","collaboration"),("aaa","collaboration"),("loopa","home"),("loopb","home")]
json.dump({"modules":[{"moduleName":n,"moduleJson":"src/%s/%s/%s.json"%(s,n,n),"stack":s} for n,s in mods]}, open(os.path.join(t,"src","module-catalog.json"),"w"))
PY
mkdir -p "${T}/src/devops"   # a planned stack: a README, no module, no INSTALL.md
for f in collaboration/README.md collaboration/INSTALL.md home/README.md home/INSTALL.md devops/README.md; do
    printf '# %s\n\nHand-written intro.\n\n<!-- BEGIN GENERATED MODULES -- x -->\n<!-- END GENERATED MODULES -->\n\nHand-written tail.\n' "$f" > "${T}/src/${f}"
done
# The generator matches its own BEGIN line exactly; put that line in.
B="$(grep -m1 '^BEGIN = ' "${GEN}" | sed 's/^BEGIN = "//; s/"$//')"
for f in collaboration/README.md collaboration/INSTALL.md home/README.md home/INSTALL.md devops/README.md; do
    python3 - "${T}/src/${f}" "${B}" <<'PY'
import sys; p, b = sys.argv[1], sys.argv[2]
s = open(p).read().replace("<!-- BEGIN GENERATED MODULES -- x -->", b); open(p, "w").write(s)
PY
done

python3 "${GEN}" --check --repo "${T}" >/dev/null 2>&1; rc=$?
ck "--check reports a README that is not yet generated"  1 "${rc}"
ck "…and writes nothing"                                 no "$(grep -q '| 1 |' "${T}/src/collaboration/INSTALL.md" && echo yes || echo no)"
python3 "${GEN}" --repo "${T}" >/dev/null 2>&1
C="${T}/src/collaboration/INSTALL.md"
R="${T}/src/collaboration/README.md"
order="$(grep -E '^\| [0-9]' "${C}" | sed -E 's/^\| ([0-9]+)[^|]*\| \[([a-z]+)\].*/\2/' | paste -sd, -)"
ck "install order follows dependsOn and integratesWith"  "files,relay,aaa,calls" "${order}"
ck "an integration is listed as such"                    yes "$(grep -E '^\| 3 ' "${C}" | grep -c '| `relay:turn` |' >/dev/null && echo yes || echo no)"
ck "an outside dependency is named with its stack"       yes "$(grep -q '`identity:identity` (foundation)' "${C}" && echo yes || echo no)"
ck "an inside dependency is listed as such"              yes "$(grep -E '^\| 4 ' "${C}" | grep -c '`files:fileservice`, `relay:turn` | — |' >/dev/null && echo yes || echo no)"
ck "the install order links each module's INSTALL.md"    yes "$(grep -q '\[files\](files/INSTALL.md)' "${C}" && echo yes || echo no)"
ck "the README lists every member with its status"       4 "$(grep -cE '^\| \[[a-z]+\]\([a-z]+/README.md\) \| the [a-z]+ module \| Testing \|' "${R}")"
ck "the README points at INSTALL.md"                     yes "$(grep -q '(INSTALL.md)' "${R}" && echo yes || echo no)"
ck "a planned stack's README says it has no module"      yes "$(grep -q 'No module in this stack yet.' "${T}/src/devops/README.md" && echo yes || echo no)"
ck "the hand-written parts are kept"                     "yes yes yes yes" "$(for f in "${C}" "${R}"; do grep -q 'Hand-written intro.' "$f" && echo -n 'yes ' || echo -n 'no '; grep -q 'Hand-written tail.' "$f" && echo -n 'yes ' || echo -n 'no '; done | sed 's/ $//')"
ck "a dependency cycle is flagged, not guessed"          2 "$(grep -c '⚠ cycle' "${T}/src/home/INSTALL.md")"
python3 "${GEN}" --check --repo "${T}" >/dev/null 2>&1; rc=$?
ck "--check is clean once generated"                     0 "${rc}"
before="$(cat "${C}")"; python3 "${GEN}" --repo "${T}" >/dev/null 2>&1
ck "a second run changes nothing"                        "${before}" "$(cat "${C}")"
sed -i.bak 's/"the files module"/"the renamed files module"/' "${T}/src/collaboration/files/files.json" && rm -f "${T}/src/collaboration/files/files.json.bak"
python3 "${GEN}" --check --repo "${T}" >/dev/null 2>&1; rc=$?
ck "--check catches a module whose JSON changed"         1 "${rc}"
python3 "${GEN}" --repo "${T}" >/dev/null 2>&1
rm "${T}/src/home/INSTALL.md"
out="$(python3 "${GEN}" --check --repo "${T}" 2>&1)"; rc=$?
ck "a stack with modules but no INSTALL.md fails"        1 "${rc}"
ck "…naming it"                                          yes "$([[ "${out}" == *"src/home/INSTALL.md"* ]] && echo yes || echo no)"
ck "…and not the planned stack"                          no "$([[ "${out}" == *"src/devops/"* ]] && echo yes || echo no)"
rm "${T}/src/home/README.md"
out="$(python3 "${GEN}" --check --repo "${T}" 2>&1)"; rc=$?
ck "a stack directory without a README fails the check"  1 "${rc}"
ck "…naming it"                                          yes "$([[ "${out}" == *"src/home/README.md"* ]] && echo yes || echo no)"

echo "── the real tree ──"
python3 "${GEN}" --check >/dev/null 2>&1; rc=$?
ck "every stack document in this tree is current"          0 "${rc}"

echo
echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
