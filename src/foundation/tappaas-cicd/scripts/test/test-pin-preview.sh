#!/usr/bin/env bash
#
# test-pin-preview.sh — pin-preview.py: the last release against "if released now"
# (#788). Offline: a fixture inventory and scan (what runs), fixture closures for
# both sides (the NixOS modules evaluated), fixture image pins for both sides, and
# fake scanners that answer by package and by image reference.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PP="${HERE}/../pin-preview.py"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
command -v python3 >/dev/null && command -v jq >/dev/null || { echo "python3/jq missing — skipped."; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pinprev.XXXXXX")"; trap 'rm -rf "${T}"' EXIT
H=$(printf 'a%.0s' {1..32})
drvs() { local f="$1"; shift; : > "${f}"; for n in "$@"; do echo "/nix/store/${H}-${n}.drv" >> "${f}"; done; }

# What runs: logging (grafana, openssl); the mothership; a Debian node; the firewall.
cat > "${T}/site.cdx.json" <<'EOF'
{"components":[
 {"name":"logging","properties":[{"name":"tappaas:layer","value":"nix"}],"components":[
   {"name":"grafana","version":"13.0.9"},{"name":"openssl","version":"3.5.1"},
   {"name":"abseil-cpp","version":"20260107.1"},{"name":"less","version":"692"},{"name":"xgcc","version":"15.3.0"},{"name":"protobuf","version":"34.1"}]},
 {"name":"tappaas-cicd (mothership)","properties":[{"name":"tappaas:layer","value":"nix"}],"components":[{"name":"openssl","version":"3.5.1"}]}
]}
EOF
cat > "${T}/cve-status.json" <<'EOF'
{"targets":[
 {"name":"logging","layer":"nix","critical":1,"high":1},
 {"name":"tappaas-cicd (mothership)","layer":"nix","critical":8,"high":57},
 {"name":"tappaas1 (node)","layer":"debian","critical":10,"high":172},
 {"name":"network (firewall)","layer":"opnsense","critical":0,"high":0}
]}
EOF
mkdir -p "${T}/base" "${T}/now"
# v2.1: logging on grafana 13; deconz did not exist.
drvs "${T}/base/logging.txt" grafana-13.0.9 openssl-3.5.1 gcc-15.1.0 abseil-cpp-20260107.1 less-692 xgcc-15.3.0 protobuf-34.1 openssl-3.5.1.tar.gz
# now: grafana 14 (a major), openssl 3.5.2; deconz is new and runs nowhere here.
drvs "${T}/now/logging.txt" grafana-14.0.1 openssl-3.5.2 gcc-16.2.0 abseil-cpp-20260817.0 less-710 xgcc-16.2.0 protobuf-33.6 polkit-1.pam
drvs "${T}/now/deconz.txt" openssl-3.5.2 cmake-4.1.0
echo '{"openwebui":"ow:0.10.2","litellm":"lit:1.85.0"}' > "${T}/base-images.json"
echo '{"openwebui":"ow:0.10.2","litellm":"lit:1.103.3"}' > "${T}/now-images.json"
echo '{"packages":{"xgcc":"GCC runtime libraries"}}' > "${T}/ignore.json"

# The scanners answer from fixed tables: by name@version, and by image reference.
cat > "${T}/nix" <<'EOF'
#!/usr/bin/env python3
import json, sys
db = {"grafana@13.0.9": [("CVE-OLD", "High")], "openssl@3.5.1": [("CVE-1", "Critical")],
      "openssl@3.5.2": [("CVE-1", "Critical"), ("CVE-LOW", "Low")], "grafana@14.0.1": [("CVE-2", "High")]}
import os
comps = json.load(open(sys.argv[sys.argv.index("--components") + 1]))
vexed = set(os.environ.get("VEXED", "").split())
fs = [{"id": i, "severity": s, "pkg": c["name"], "installed": c["version"], "fixed": ""}
      for c in comps for i, s in db.get(f"{c['name']}@{c['version']}", [])]
# A token is a CVE id (any version) or id@version (a versioned statement), and
# id:module a statement in that module's VEX file (vexModules), not templates'.
def by(f):
    out = []
    for t in vexed:
        i, _, mod = t.partition(":")
        if i == f["id"] or i == f"{f['id']}@{f['installed']}":
            out.append(mod)
    return out
json.dump({"findings": [f for f in fs if not by(f)],
           "suppressed": [dict(f, vexModules=sorted(set(by(f)))) for f in fs if by(f)], "error": ""}, sys.stdout)
EOF
cat > "${T}/img" <<'EOF'
#!/usr/bin/env python3
import json, sys
db = {"ow:0.10.2": [("CVE-W1", "Critical", "perl"), ("CVE-W2", "High", "libssl3"), ("CVE-W2", "High", "openssl")], "lit:1.85.0": [("CVE-L1", "High", "PyJWT"), ("CVE-L2", "High", "tar")],
      "lit:1.103.3": [("CVE-L2", "High", "tar")]}
refs = json.load(open(sys.argv[sys.argv.index("--refs") + 1]))
json.dump({r: {"findings": [{"id": i, "severity": s, "pkg": p, "installed": "x", "fixed": "y" if p == "openssl" else ""} for i, s, p in db.get(r, [])], "suppressed": [], "error": ""}
           for r in refs}, sys.stdout)
EOF
chmod +x "${T}/nix" "${T}/img"

run() {  # $@ = extra overrides (e.g. a different nix scanner)
    OUT="$(python3 "${PP}" --inventory "${T}/site.cdx.json" --status "${T}/cve-status.json" \
        --base-label v2.1 --base-closures "${T}/base" --base-images "${T}/base-images.json" --base-nix-scanner "${NIXSCAN:-${T}/nix} --components {file}" \
        --now-closures "${T}/now" --now-images "${T}/now-images.json" --now-nix-scanner "${NIXSCAN:-${T}/nix} --components {file}" \
        --image-scanner "${T}/img --refs {file}" --from aaaaaaaaaaaa --to bbbbbbbbbbbb --out "${T}/p.json" --ignore "${T}/ignore.json" --details "${T}/d.json" 2>&1)"; RC=$?
}
row() { jq -r --arg m "$1" '.modules[] | select(.module == $m) | "\(.now) \(.base) \(.fixed) \(.new) \(.same)"' "${T}/p.json"; }

run
ck "runs" "0" "${RC}"
ck "logging: now 2 | v2.1 2, fixed 1, new 1, same 1" "2 2 1 1 1" "$(row logging)"
ck "an image module counts like a NixOS one: litellm 1 | 2, fixed 1" "1 2 1 0 1" "$(row litellm)"
ck "an unchanged image: openwebui 2 | 2, same 2" "2 2 0 0 2" "$(row openwebui)"
ck "one CVE in two packages counts once, as in the nightly scan (CVE-W2: libssl3 + openssl)" "2" "$(jq '.modules[] | select(.module=="openwebui") | .now' "${T}/p.json")"
ck "a module new since the release: deconz, no release column" "1 null 0 1 0" "$(row deconz)"
ck "…counted though it runs nowhere, marked approximate" "true" "$(jq '.modules[] | select(.module=="deconz") | .approximate' "${T}/p.json")"
ck "…from runtime package names only — no build tool" "1" "$(jq '.modules[] | select(.module=="deconz") | .now' "${T}/p.json")"
ck "the modules total: now 6 | v2.1 6" "6 6" "$(jq -r '"\(.total.now) \(.total.base)"' "${T}/p.json")"
ck "the platform has only a now: node 182, firewall 0" "182 0" "$(jq -r '[.platform[] | select(.layer != "nix, not compared") | .now] | sort | reverse | join(" ")' "${T}/p.json")"
ck "the mothership is not dropped: now only, not compared" "65" "$(jq '.platform[] | select(.layer == "nix, not compared") | .now' "${T}/p.json")"
ck "a real major since the release: grafana 13 -> 14" "true" "$(jq '[.majors[].pkg] | index("grafana") != null' "${T}/p.json")"
ck "date and sequence versions are not majors" "false" "$(jq '[.majors[].pkg] | (index("abseil-cpp") != null or index("less") != null)' "${T}/p.json")"
ck "an ignored package is not gated" "false" "$(jq '[.majors[].pkg] | index("xgcc") != null' "${T}/p.json")"
ck "a downgrade is labelled" "true" "$(jq '.majors[] | select(.pkg=="protobuf") | .downgrade' "${T}/p.json")"
ck "low severity is never counted" "false" "$(jq '[.introduced[].key] | any(contains("CVE-LOW"))' "${T}/p.json")"
ck "the gate: majors and what is new against the release" \
   '["cve CVE-1","cve CVE-2","major grafana 13->14","major protobuf 34->33"]' "$(jq -c '.gate' "${T}/p.json")"
ck "the table: NOW first, then the release's columns" "yes" "$([[ "${OUT}" == *"MODULE"*"NOW"*"│"*"V2.1"*"FIXED"*"NEW"*"SAME"* ]] && echo yes || echo no)"
ck "…with the approximate row said" "yes" "$([[ "${OUT}" == *"deconz"*"≈ approximate"* ]] && echo yes || echo no)"
ck "…and a grand TOTAL with the platform" "yes" "$(grep -qE '^ +TOTAL +253 ' <<<"${OUT}" && echo yes || echo no)"
# ── the details file: per module, each CVE with what it is (#788) ──
D="${T}/d.json"
ck "details: logging's NEW lists the CVE, package, version and where it comes from" "CVE-2 grafana 14.0.1 High nixos" \
   "$(jq -r '.modules.logging.cves.new[] | "\(.id) \(.packages[0].pkg) \(.packages[0].version) \(.severity) \(.packages[0].from)"' "${D}")"
ck "…FIXED what the release had" "CVE-OLD grafana 13.0.9" "$(jq -r '.modules.logging.cves.fixed[] | "\(.id) \(.packages[0].pkg) \(.packages[0].version)"' "${D}")"
ck "…SAME what stays" "CVE-1 openssl" "$(jq -r '.modules.logging.cves.same[] | "\(.id) \(.packages[0].pkg)"' "${D}")"
ck "one CVE, every package it hits, with the version that fixes it" "CVE-W2 libssl3,openssl y" \
   "$(jq -r '.modules.openwebui.cves.same[] | select(.id=="CVE-W2") | "\(.id) \([.packages[].pkg] | join(",")) \([.packages[].fixed | select(. != "")] | join(","))"' "${D}")"
ck "…and the packages that change" "true" "$(jq '[.modules.logging.packages[] | select(.pkg=="grafana" and .base=="13.0.9" and .now=="14.0.1")] | length == 1' "${D}")"
ck "an image module: both references, and its CVEs marked image" "lit:1.85.0 lit:1.103.3 image" \
   "$(jq -r '.modules.litellm | "\(.image.base) \(.image.now) \(.cves.fixed[0].packages[0].from)"' "${D}")"
SHOW="$(python3 "${PP}" --show logging --details "${D}" 2>&1)"; RC=$?
ck "--show prints one module: NEW, FIXED and SAME, each CVE on its line" "yes" \
   "$([[ ${RC} -eq 0 && "${SHOW}" == *"NEW"*"CVE-2"*"FIXED"*"CVE-OLD"*"SAME"*"CVE-1"* && "${SHOW}" == *"grafana"*"13.0.9 -> 14.0.1"* ]] && echo yes || echo no)"
jq '.modules.logging.packages += [{"pkg":"perl-CGI","base":"4.59","now":null},{"pkg":"newlib","base":null,"now":"1.0"}]' "${D}" > "${T}/d2.json"
SHOW="$(python3 "${PP}" --show logging --details "${T}/d2.json" 2>&1)"
ck "packages only removed or only added are one line each" "yes" \
   "$([[ "${SHOW}" == *"no longer shipped (1): perl-CGI"* && "${SHOW}" == *"newly shipped (1): newlib"* && "${SHOW}" != *"perl-CGI    "* ]] && echo yes || echo no)"
SHOW="$(python3 "${PP}" --show nosuch --details "${D}" 2>&1)"; RC=$?
ck "an unknown module: rc 1, and the modules there are named" "1 yes" "${RC} $([[ "${SHOW}" == *"logging"* ]] && echo yes || echo no)"

# --check-scan: modules that run here, against the nightly scan's CVE ids.
jq '.targets[0].critHighKeys = ["CVE-1 openssl","CVE-2 grafana"]' "${T}/cve-status.json" > "${T}/cs.json" && cp "${T}/cve-status.json" "${T}/cs.bak" && mv "${T}/cs.json" "${T}/cve-status.json"
OUT="$(python3 "${PP}" --inventory "${T}/site.cdx.json" --status "${T}/cve-status.json" \
    --base-label v2.1 --base-closures "${T}/base" --base-images "${T}/base-images.json" --base-nix-scanner "${T}/nix --components {file}" \
    --now-closures "${T}/now" --now-images "${T}/now-images.json" --now-nix-scanner "${T}/nix --components {file}" \
    --image-scanner "${T}/img --refs {file}" --from a --to b --out "${T}/p.json" --ignore "${T}/ignore.json" --check-scan 2>&1)"
ck "--check-scan: a module that counts what the nightly scan counted agrees" "logging 2 2 0 0" \
   "$(jq -r '.scanCheck[] | "\(.module) \(.preview) \(.scan) \(.previewOnly|length) \(.scanOnly|length)"' "${T}/p.json")"
ck "…and says so" "yes" "$([[ "${OUT}" == *"1 of 1 module(s) that run here agree"* ]] && echo yes || echo no)"
jq '.targets[0].critHighKeys = ["CVE-1 openssl","CVE-9 libfoo"]' "${T}/cs.bak" > "${T}/cve-status.json"
OUT="$(python3 "${PP}" --inventory "${T}/site.cdx.json" --status "${T}/cve-status.json" \
    --base-label v2.1 --base-closures "${T}/base" --base-images "${T}/base-images.json" --base-nix-scanner "${T}/nix --components {file}" \
    --now-closures "${T}/now" --now-images "${T}/now-images.json" --now-nix-scanner "${T}/nix --components {file}" \
    --image-scanner "${T}/img --refs {file}" --from a --to b --out "${T}/p.json" --ignore "${T}/ignore.json" --check-scan 2>&1)"
ck "…and a difference is named, CVE by CVE" "yes" "$([[ "${OUT}" == *"differ: logging 2 vs 2 (preview only CVE-2, scan only CVE-9)"* ]] && echo yes || echo no)"
mv "${T}/cs.bak" "${T}/cve-status.json"

d1="$(jq -r .digest "${T}/p.json")"; run
ck "the same findings, the same digest" "${d1}" "$(jq -r .digest "${T}/p.json")"

# VEX: what a recorded statement decided is not in NOW, and is counted apart.
VEXED="CVE-1" run
ck "a VEX-decided CVE leaves NOW: logging 1 | v2.1 1" "1 1" "$(jq -r '.modules[] | select(.module=="logging") | "\(.now) \(.base)"' "${T}/p.json")"
ck "…and is counted in the VEX column, on its own" "1" "$(jq '.modules[] | select(.module=="logging") | .vex' "${T}/p.json")"
ck "…listed under VEX in the details" "CVE-1" "$(jq -r '.modules.logging.cves.vex[].id' "${T}/d.json")"
ck "…not gated: a decided CVE needs no ack" "false" "$(jq '.gate | index("cve CVE-1") != null' "${T}/p.json")"
VEXED="CVE-1:deconz" run
ck "a statement in deconz's VEX decides for deconz, not for logging" "0 1 1" \
   "$(jq -r '[(.modules[] | select(.module=="deconz") | .now, .vex), (.modules[] | select(.module=="logging") | .same)] | join(" ")' "${T}/p.json")"
VEXED="CVE-1@3.5.2" run
ck "a statement on the new version only: the release had it, now it is decided — VEX, not FIXED" "1 1 CVE-OLD" \
   "$(jq -r '.modules[] | select(.module=="logging") | "\(.fixed) \(.vex)"' "${T}/p.json") $(jq -r '[.modules.logging.cves.fixed[].id] | join(",")' "${T}/d.json")"
run

printf '#!/usr/bin/env bash\necho "{\\"findings\\":[],\\"error\\":\\"grype failed: no db\\"}"; exit 1\n' > "${T}/bad"; chmod +x "${T}/bad"
NIXSCAN="${T}/bad" run
ck "a failed match is no clean result: gated" "true" "$(jq '.gate | index("cve-match-failed") != null' "${T}/p.json")"
ck "…and said" "yes" "$([[ "${OUT}" == *"CVE match FAILED"* ]] && echo yes || echo no)"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
