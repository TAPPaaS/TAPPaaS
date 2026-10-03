#!/usr/bin/env bash
#
# test-image-pins.sh — the container image pin report (#750), offline: a fixture
# repository with back-dated commits, and a fixed list of upstream tags.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PINS="${HERE}/../image-pins.py"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
command -v python3 >/dev/null && command -v git >/dev/null || { echo "python3/git missing — skipped"; exit 77; }
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
R="${T}/repo"; mkdir -p "${R}/src/m"
git -C "${R}" init -q; git -C "${R}" config user.email t@t; git -C "${R}" config user.name t
commit() { GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" git -C "${R}" commit -qam "$2"; }

cat > "${R}/src/m/old.nix" <<'N'
{ versions = { app = "1.2.0"; }; image = "docker.io/acme/app:${versions.app}"; }
N
cat > "${R}/src/m/walk.nix" <<'N'
{ lines = [ "2025.2.3" "2025.4.4"
            "2026.8.3" ]; }
N
cat > "${R}/src/m/dig.nix" <<'N'
{ image = "docker.io/acme/dig@sha256:0123456789abcdef"; }
N
cat > "${R}/src/m/extra.sh" <<'N'
    image: other/thing:1.0
N
cat > "${R}/src/image-pins.json" <<'N'
{ "pins": [
  { "module": "old",  "image": "docker.io/acme/app", "kind": "tag", "file": "src/m/old.nix",
    "match": "app = \"([^\"]+)\";" },
  { "module": "walk", "image": "ghcr.io/acme/walk", "kind": "tag", "file": "src/m/walk.nix",
    "match": "lines = \\[[^\\]]*\"([0-9.]+)\"\\s*\\];", "tagPattern": "^[0-9]{4}\\.[0-9]+\\.[0-9]+$" },
  { "module": "dig",  "image": "acme/dig", "kind": "digest", "file": "src/m/dig.nix",
    "match": "@(sha256:[0-9a-f]+)" },
  { "module": "gone", "image": "acme/gone", "kind": "tag", "file": "src/m/missing.nix", "match": "x" }
] }
N
git -C "${R}" add -A; commit "2026-01-01T12:00:00" "pins"
# walk.nix moves recently: its last line changes today
sed -i.bak 's/"2026.8.3"/"2026.8.4"/' "${R}/src/m/walk.nix" && rm -f "${R}/src/m/walk.nix.bak"; commit "$(date -u +%Y-%m-%dT%H:%M:%S)" "walk"

cat > "${T}/tags.json" <<'N'
{ "docker.io/acme/app": ["1.2.0", "1.3.0", "1.10.1", "latest", "1.10.1-rc1", "main-abc"],
  "ghcr.io/acme/walk":  ["2026.8.3", "2026.8.4", "2026.11.1", "sha-1234"] }
N
J="$(python3 "${PINS}" --repo "${R}" --json --tags-file "${T}/tags.json")"
get() { python3 -c "import json,sys; r=json.loads(sys.argv[1]); p=[x for x in r['pins'] if x['module']==sys.argv[2]][0]; print(p.get(sys.argv[3]))" "${J}" "$1" "$2"; }

ck "an old pin with newer upstream tags is STALE"                    "stale"  "$(get old status)"
ck "…newest tag by version, not by name (1.10.1 > 1.3.0), rc ignored" "1.10.1" "$(get old latest)"
ck "…and how many are newer"                                          "2"      "$(get old newer)"
ck "a list's LAST element is the pin"                                 "2026.8.4" "$(get walk pinned)"
ck "a recent pin with a newer upstream is behind, not stale"          "behind" "$(get walk status)"
ck "a digest is reported by age only"                                 "digest" "$(get dig status)"
ck "a pin the file no longer holds is unreadable, not dropped"        "unreadable" "$(get gone status)"
ck "age comes from when the line last changed"                        "0"      "$(get walk ageDays)"
ck "an image in the tree but not in the list is reported" "other/thing" \
   "$(python3 -c "import json,sys; print(','.join(u['image'] for u in json.loads(sys.argv[1])['unlisted']))" "${J}")"
ck "the stale count" "1" "$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['stale'])" "${J}")"
OUT="$(python3 "${PINS}" --repo "${R}" --offline)"
[[ "${OUT}" == *"upstream not checked"* && "${OUT}" == *"by digest"* ]] && ck "offline: age and listing, upstream not asked" y y || ck "offline report" y n
python3 "${PINS}" --repo "${T}/nowhere" --json >/dev/null 2>&1; ck "no list: exit 2" 2 $?

echo "── image pins: ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
