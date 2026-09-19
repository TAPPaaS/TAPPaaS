#!/usr/bin/env bash
# test-move-module.sh — scripts/move-module.sh (#500), in throwaway git repositories.
#
# A fake TAPPaaS checkout (a copy of the tool at its real path, a catalogue, a
# committed migration) and a fake Community checkout. Asserts: a move within the
# repository is a `git mv` with its catalogue entry rewritten in place and a new
# migration + fixture test; further moves join that migration while it is
# uncommitted; a module moved twice is one move; a rename needs --rename and is
# refused while a module depends on the old name; after a commit a new migration
# starts; a move between repositories copies, removes and re-catalogues; and the
# generated fixture test passes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/.." && pwd)"                 # tappaas-cicd/scripts
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; PASS=$((PASS + 1)); else echo "  ✗ $1 (expected '$2', got '$3')"; FAIL=$((FAIL + 1)); fi; }
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
g() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}" >/dev/null 2>&1; }

# ── fixtures ─────────────────────────────────────────────────────────
R="${T}/TAPPaaS"; C="${T}/Community"
S="${R}/src/foundation/tappaas-cicd/scripts"
mkdir -p "${S}/test" "${R}/src/foundation/tappaas-cicd/migrations" "${R}/src/apps"/{foo,bar,dep,qux} "${C}/src/apps/baz"
cp "${SRC}/move-module.sh" "${S}/"; cp -R "${SRC}/move-module" "${S}/"
for m in foo bar qux; do echo '{"description":"'"${m}"'"}' > "${R}/src/apps/${m}/${m}.json"; echo x > "${R}/src/apps/${m}/install.sh"; done
echo '{"dependsOn":["bar:svc"]}' > "${R}/src/apps/dep/dep.json"
echo '{"description":"baz"}' > "${C}/src/apps/baz/baz.json"
cat > "${R}/src/module-catalog.json" <<'EOF'
{
  "applicationModules": [
    { "moduleName": "foo", "moduleJson": "src/apps/foo/foo.json", "tier": "app" },
    {
      "moduleName": "bar",
      "moduleJson": "src/apps/bar/bar.json"
    },
    { "moduleName": "qux", "moduleJson": "src/apps/qux/qux.json" }
  ]
}
EOF
echo '{"applicationModules":[{"moduleName":"baz","moduleJson":"src/apps/baz/baz.json","tier":"app"}]}' > "${C}/src/module-catalog.json"
printf '#!/usr/bin/env bash\n# 0009-x.sh — x\n' > "${R}/src/foundation/tappaas-cicd/migrations/0009-x.sh"
printf '| id | what |\n|---|---|\n| `0009-x.sh` | x | yes |\n\n## Writing one\n' > "${R}/src/foundation/tappaas-cicd/migrations/README.md"
for r in "${R}" "${C}"; do g "${r}" init -q; g "${r}" add -A; g "${r}" commit -q -m init; done
MM="${S}/move-module.sh"
MIG="${R}/src/foundation/tappaas-cicd/migrations"
table() { sed -n '/^MOVES=(/,/^)/p' "$1" | sed -n 's/^ *"\(.*\)"$/\1/p' | tr '\n' ' '; }

# ── within the repository ────────────────────────────────────────────
rc=0; "${MM}" TAPPaaS:src/apps/foo TAPPaaS:src/stacks/home/foo >/dev/null 2>&1 || rc=$?
ck "a move within the repository succeeds"            0 "${rc}"
ck "…the files moved"                                 "yes no" "$([[ -f "${R}/src/stacks/home/foo/foo.json" ]] && echo yes || echo no) $([[ -e "${R}/src/apps/foo" ]] && echo yes || echo no)"
ck "…by git mv (staged as a rename)"                  "R" "$(git -C "${R}" diff --cached -M --name-status | awk '$3 == "src/stacks/home/foo/foo.json" {print substr($1,1,1)}')"
ck "…the catalogue entry rewritten in place"          '    { "moduleName": "foo", "moduleJson": "src/stacks/home/foo/foo.json", "tier": "app" },' "$(grep 'moduleName": "foo"' "${R}/src/module-catalog.json")"
ck "…the rest of the catalogue untouched"             "2" "$(git -C "${R}" diff --numstat src/module-catalog.json | awk '{print $1+$2}')"
ck "…a new migration, the next number"                "0010-modules-moved.sh" "$(cd "${MIG}" && printf '%s' *-modules-moved.sh)"
ck "…holding the move"                                "TAPPaaS:src/apps/foo|TAPPaaS:src/stacks/home/foo " "$(table "${MIG}/0010-modules-moved.sh")"
ck "…with its fixture test"                           "yes" "$([[ -x "${S}/test/test-migration-0010-modules-moved.sh" ]] && echo yes || echo no)"
ck "…and a README row"                                "1" "$(grep -c '0010-modules-moved.sh' "${MIG}/README.md")"

"${MM}" TAPPaaS:src/apps/qux TAPPaaS:src/stacks/home/qux >/dev/null 2>&1
ck "a second move joins the uncommitted migration"    "TAPPaaS:src/apps/foo|TAPPaaS:src/stacks/home/foo TAPPaaS:src/apps/qux|TAPPaaS:src/stacks/home/qux " "$(table "${MIG}/0010-modules-moved.sh")"
"${MM}" TAPPaaS:src/stacks/home/foo TAPPaaS:src/stacks/work/foo >/dev/null 2>&1
ck "a module moved twice is one move (a site never saw the middle)" "TAPPaaS:src/apps/foo|TAPPaaS:src/stacks/work/foo TAPPaaS:src/apps/qux|TAPPaaS:src/stacks/home/qux " "$(table "${MIG}/0010-modules-moved.sh")"

# ── renames ──────────────────────────────────────────────────────────
rc=0; out="$("${MM}" TAPPaaS:src/apps/bar TAPPaaS:src/apps/bar2 2>&1)" || rc=$?
ck "a rename without --rename is refused"             "1 yes" "${rc} $(grep -q -- '--rename' <<< "${out}" && echo yes || echo no)"
rc=0; out="$("${MM}" TAPPaaS:src/apps/bar TAPPaaS:src/apps/bar2 --rename 2>&1)" || rc=$?
ck "…and refused while a module depends on the old name" "1 yes yes" "${rc} $(grep -q 'dep.json' <<< "${out}" && echo yes || echo no) $([[ -d "${R}/src/apps/bar" ]] && echo yes || echo no)"
echo '{}' > "${R}/src/apps/dep/dep.json"
rc=0; "${MM}" TAPPaaS:src/apps/bar TAPPaaS:src/apps/bar2 --rename >/dev/null 2>&1 || rc=$?
ck "with --rename and no dependant it moves"          "0 yes" "${rc} $([[ -f "${R}/src/apps/bar2/bar2.json" ]] && echo yes || echo no)"
ck "…the catalogue names it bar2 at its new path"     "bar2 src/apps/bar2/bar2.json" "$(jq -r '.applicationModules[] | select(.moduleName == "bar2") | "\(.moduleName) \(.moduleJson)"' "${R}/src/module-catalog.json")"

# ── the generated fixture test passes ────────────────────────────────
rc=0; out="$(bash "${S}/test/test-migration-0010-modules-moved.sh" 2>&1)" || rc=$?
ck "the generated fixture test passes"                0 "${rc}"
[[ "${rc}" -eq 0 ]] || printf '%s\n' "${out}" | tail -8

# ── committed: sealed ────────────────────────────────────────────────
g "${R}" add -A; g "${R}" commit -q -m moves
cp "${MIG}/0010-modules-moved.sh" "${T}/0010.before"
"${MM}" TAPPaaS:src/stacks/home/qux TAPPaaS:src/stacks/work/qux >/dev/null 2>&1
ck "after a commit the migration is sealed"           "" "$(diff "${T}/0010.before" "${MIG}/0010-modules-moved.sh")"
ck "…and the next move starts 0011"                   "TAPPaaS:src/stacks/home/qux|TAPPaaS:src/stacks/work/qux " "$(table "${MIG}/0011-modules-moved.sh" 2>/dev/null)"

# ── between repositories ─────────────────────────────────────────────
rc=0; "${MM}" Community:src/apps/baz TAPPaaS:src/apps/baz --checkout "Community=${C}" >/dev/null 2>&1 || rc=$?
ck "a move between repositories succeeds"             0 "${rc}"
ck "…copied into TAPPaaS, removed from Community"     "yes no" "$([[ -f "${R}/src/apps/baz/baz.json" ]] && echo yes || echo no) $([[ -e "${C}/src/apps/baz" ]] && echo yes || echo no)"
ck "…out of Community's catalogue"                    "0" "$(jq '.applicationModules | length' "${C}/src/module-catalog.json")"
ck "…into TAPPaaS's, same fields"                     "app src/apps/baz/baz.json" "$(jq -r '.applicationModules[] | select(.moduleName == "baz") | "\(.tier) \(.moduleJson)"' "${R}/src/module-catalog.json")"
ck "…and into the open migration"                     "yes" "$(grep -qF '"Community:src/apps/baz|TAPPaaS:src/apps/baz"' "${MIG}/0011-modules-moved.sh" && echo yes || echo no)"

rc=0; "${MM}" TAPPaaS:src/apps/nope TAPPaaS:src/apps/nope2 --rename >/dev/null 2>&1 || rc=$?
ck "a module that is not there is refused"            1 "${rc}"
rc=0; "${MM}" src/apps/foo TAPPaaS:src/x >/dev/null 2>&1 || rc=$?
ck "a path without its repository is refused"         1 "${rc}"

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
