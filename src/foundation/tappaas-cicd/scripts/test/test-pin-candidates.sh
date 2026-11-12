#!/usr/bin/env bash
#
# test-pin-candidates.sh — the daily "would moving a pin help" check: image pins
# scanned by reference against their newer tags, the nixpkgs pin from the last
# preview, drafts for what no move clears, and apply on a branch of its own.
# Offline: a fake pin list and a fake image scanner.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PC="${HERE}/../pin-candidates.py"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
command -v python3 >/dev/null && command -v jq >/dev/null && command -v git >/dev/null || { echo "python3/jq/git missing — skipped."; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pincand.XXXXXX")"; trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/cfg/sbom" "${T}/repo/src/home/karakeep"
cat > "${T}/pins.json" <<'J'
{"pins":[
 {"module":"karakeep","image":"ghcr.io/karakeep-app/karakeep","kind":"tag","pinned":"0.31.2","latest":"0.32.0","latestPatch":"0.31.4","file":"src/home/karakeep/karakeep.nix"},
 {"module":"openwebui","image":"docker.io/openwebui/open-webui","kind":"tag","pinned":"0.13.3","latest":"0.13.3","latestPatch":null},
 {"module":"vllm-amd","image":"docker.io/kyuz0/vllm","kind":"digest","pinned":"sha256:aa"}]}
J
cat > "${T}/scan" <<'P'
#!/usr/bin/env python3
import json, sys
refs = json.load(open(sys.argv[sys.argv.index("--refs") + 1]))
f = lambda *ids: {"findings": [{"id": i, "severity": "High"} for i in ids], "suppressed": [], "error": ""}
d = {"ghcr.io/karakeep-app/karakeep:0.31.2": f("CVE-1", "CVE-2", "CVE-3"),
     "ghcr.io/karakeep-app/karakeep:0.31.4": f("CVE-3"),
     "ghcr.io/karakeep-app/karakeep:0.32.0": f("CVE-9")}
json.dump({r: d.get(r, f()) for r in refs}, sys.stdout)
P
chmod +x "${T}/scan"
cat > "${T}/cfg/sbom/cve-status.json" <<'J'
{"targets":[{"id":"network","items":[
 {"id":"CVE-C1","severity":"Critical","mark":"unread","component":"network/opnsense:curl","vector":"CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:U/C:H/I:H/A:H"},
 {"id":"CVE-C2","severity":"High","mark":"unread","component":"network/opnsense:curl","vector":"CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:U/C:H/I:N/A:N"},
 {"id":"CVE-1","severity":"High","mark":"unread","component":"karakeep/deb:tiff"}]}]}
J
run() { OUT="$(python3 "${PC}" --config "${T}/cfg" --repo "${T}/repo" --pins "cat ${T}/pins.json" --image-scanner "${T}/scan --refs {file}" "$@" 2>&1)"; RC=$?; }
run
P="${T}/cfg/pin-candidates.json"
ck "the check writes its proposals" "0" "${RC}"
ck "a patch tag that clears and adds nothing is preferred over the latest" "0.31.4 CVE-1,CVE-2 0 true" \
   "$(jq -r '.proposals[] | select(.kind=="move" and .module=="karakeep") | "\(.to) \(.clears | join(",")) \(.adds | length) \(.patchLevel)"' "${P}")"
ck "a pin with nothing newer, and a digest pin, propose nothing" "1" "$(jq '[.proposals[] | select(.kind=="move")] | length' "${P}")"
ck "what no move clears becomes a draft record, with the rule that covers most" "network/opnsense:curl N R 2" \
   "$(jq -r '.proposals[] | select(.kind=="draft") | "\(.component) \(.rule.match.AV[0]) \(.rule.match.UI[0]) \(.rule.covers)"' "${P}")"
ck "…a CVE a move clears gets no draft" "" "$(jq -r '.proposals[] | select(.kind=="draft" and .component=="karakeep/deb:tiff") | .component' "${P}")"
ck "the text names the move and where it goes" "yes" "$([[ "${OUT}" == *"0.31.2 → 0.31.4 clears 2"*"patch-level"* ]] && echo yes || echo no)"
# the nixpkgs pin from a fresh preview
echo '{"from":"aaaaaaaaaaaaaaaa","to":"bbbbbbbbbbbbbbbb"}' > "${T}/cfg/train-preview.json"
echo '{"modules":{"immich":{"cves":{"fixed":[{"id":"CVE-N","severity":"Critical"}],"new":[{"id":"CVE-M","severity":"Medium"}]}}}}' > "${T}/cfg/train-preview-details.json"
run
ck "a fresh release preview gives the nixpkgs pin's move" "CVE-N 0" "$(jq -r '.proposals[] | select(.module=="nixpkgs") | "\(.clears | join(",")) \(.adds | length)"' "${P}")"
# apply: a branch of its own, the checkout untouched
git -C "${T}/repo" init -q -b main && git -C "${T}/repo" config user.email t@t && git -C "${T}/repo" config user.name t
printf 'image = "ghcr.io/karakeep-app/karakeep:0.31.2";\n' > "${T}/repo/src/home/karakeep/karakeep.nix"
echo '{"pins":[{"module":"karakeep","image":"ghcr.io/karakeep-app/karakeep","file":"src/home/karakeep/karakeep.nix","match":"karakeep:([0-9.]+)\""}]}' > "${T}/repo/src/image-pins.json"
git -C "${T}/repo" add -A && git -C "${T}/repo" commit -q -m init
run apply karakeep
ck "apply writes the move to pin/<module>-<tag>" "0 karakeep:0.31.4" "${RC} $(git -C "${T}/repo" show pin/karakeep-0.31.4:src/home/karakeep/karakeep.nix | grep -o 'karakeep:[0-9.]*')"
ck "…and the checkout did not move" "main karakeep:0.31.2" "$(git -C "${T}/repo" branch --show-current) $(grep -o 'karakeep:[0-9.]*' "${T}/repo/src/home/karakeep/karakeep.nix")"
run apply openwebui
ck "apply without a proposal refuses" "1" "${RC}"
echo
echo "── pin candidates: ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
