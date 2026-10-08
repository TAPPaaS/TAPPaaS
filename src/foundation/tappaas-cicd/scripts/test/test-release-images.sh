#!/usr/bin/env bash
#
# test-release-images.sh — release-images.py reads the images a release shipped
# (#788): at a tag, from files that have moved since (src/apps/ -> src/ai/), with a
# value whose form changed (earlierMatch); and in the working tree.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RI="${HERE}/../release-images.py"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
command -v python3 >/dev/null && command -v git >/dev/null && command -v jq >/dev/null || { echo "python3/git/jq missing — skipped."; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/relimg.XXXXXX")"; trap 'rm -rf "${T}"' EXIT
R="${T}/r"; mkdir -p "${R}/src/apps/web" "${R}/src/foundation/idp"
git -C "${R}" init -q; git -C "${R}" config user.email t@t; git -C "${R}" config user.name t
# The release: web under src/apps/, idp pinned as `server = "1.0.0"`.
echo 'version = "0.9.0";' > "${R}/src/apps/web/web.nix"
echo 'server = "1.0.0";' > "${R}/src/foundation/idp/idp.nix"
git -C "${R}" add -A; git -C "${R}" commit -qm rel; git -C "${R}" tag v1.0
# Since: web moved to src/ai/ and bumped; idp now pins a list of lines; db is new.
mkdir -p "${R}/src/ai/web" "${R}/src/home/db"; git -C "${R}" mv src/apps/web/web.nix src/ai/web/web.nix
echo 'version = "1.2.0";' > "${R}/src/ai/web/web.nix"
echo 'lines = [ "1.0.0" "2.0.1" ];' > "${R}/src/foundation/idp/idp.nix"
echo 'digest = "sha256:abc123";' > "${R}/src/home/db/db.nix"
cat > "${R}/src/image-pins.json" <<'EOF'
{"pins":[
 {"module":"web","image":"ex/web","kind":"tag","file":"src/ai/web/web.nix","match":"version = \"([^\"]+)\";"},
 {"module":"idp","image":"ex/idp","kind":"tag","file":"src/foundation/idp/idp.nix","match":"lines = \\[[^\\]]*\"([0-9.]+)\"\\s*\\];",
  "earlierMatch":["server = \"([0-9.]+)\";"]},
 {"module":"db","image":"ex/db","kind":"digest","file":"src/home/db/db.nix","match":"digest = \"(sha256:[0-9a-f]+)\";"}
]}
EOF
git -C "${R}" add -A; git -C "${R}" commit -qm since

then="$(python3 "${RI}" --repo "${R}" --ref v1.0)"
now="$(python3 "${RI}" --repo "${R}")"
ck "a release's image is read from where its file was then (src/apps/)" "ex/web:0.9.0" "$(jq -r .web <<<"${then}")"
ck "a value whose form changed is read with earlierMatch" "ex/idp:1.0.0" "$(jq -r .idp <<<"${then}")"
ck "a module the release did not have is left out" "null" "$(jq -r .db <<<"${then}")"
ck "the working tree: the moved, bumped file" "ex/web:1.2.0" "$(jq -r .web <<<"${now}")"
ck "…the current form, its last value" "ex/idp:2.0.1" "$(jq -r .idp <<<"${now}")"
ck "…and a digest pin as image@digest" "ex/db@sha256:abc123" "$(jq -r .db <<<"${now}")"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
