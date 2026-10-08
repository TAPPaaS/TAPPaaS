#!/usr/bin/env bash
#
# test-pin-preview.sh — pin-preview.py: what the next nixpkgs pin brings to what
# runs here (#788). Offline: a fixture inventory (the last scan), fixture
# closures (the guests evaluated against the next pin) and a fake scanner.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PP="${HERE}/../pin-preview.py"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
command -v python3 >/dev/null && command -v jq >/dev/null || { echo "python3/jq missing — skipped."; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pinprev.XXXXXX")"; trap 'rm -rf "${T}"' EXIT

H=$(printf 'a%.0s' {1..32})
# Today: logging runs grafana 13.0.9, loki 3.7.7, openssl 3.5.1 (CVE-1 critical);
# coturn runs openssl 3.5.1 too. jellyfin was scanned but not evaluated.
cat > "${T}/site.cdx.json" <<EOF
{"components":[
 {"name":"logging","properties":[{"name":"tappaas:layer","value":"nix"}],"components":[
   {"name":"grafana","version":"13.0.9"},{"name":"grafana-loki","version":"3.7.7"},{"name":"openssl","version":"3.5.1"}]},
 {"name":"coturn","properties":[{"name":"tappaas:layer","value":"nix"}],"components":[{"name":"openssl","version":"3.5.1"}]},
 {"name":"jellyfin","properties":[{"name":"tappaas:layer","value":"nix"}],"components":[{"name":"jellyfin","version":"10.10.7"}]},
 {"name":"euro-office (euro-office)","properties":[{"name":"tappaas:layer","value":"image"}],"components":[]}
]}
EOF
cat > "${T}/cve-status.json" <<'EOF'
{"targets":[{"name":"logging","layer":"nix","critHighKeys":["CVE-1 openssl","CVE-OLD grafana"]},
            {"name":"coturn","layer":"nix","critHighKeys":["CVE-1 openssl"]}]}
EOF
# Next pin: grafana 14 (major), loki 3.7.9 (patch), openssl 3.5.2; gcc is a build tool.
mkdir -p "${T}/closures"
printf '/nix/store/%s-grafana-14.0.1.drv\n/nix/store/%s-grafana-loki-3.7.9.drv\n/nix/store/%s-openssl-3.5.2.drv\n/nix/store/%s-gcc-15.1.0.drv\n/nix/store/%s-etc.drv\n/nix/store/%s-openssl-3.5.2.tar.gz.drv\n/nix/store/%s-grafana-loki-3.7.9.tar.gz.drv\n' \
    "$H" "$H" "$H" "$H" "$H" "$H" "$H" > "${T}/closures/logging.txt"
printf '/nix/store/%s-openssl-3.5.2.drv\n' "$H" > "${T}/closures/coturn.txt"
# The scanner: CVE-1 still in openssl 3.5.2, CVE-2 new in grafana 14.0.1.
cat > "${T}/scanner" <<'EOF'
#!/usr/bin/env bash
f="$2"; echo "$(cat "$f")" > "${SCANNED:-/dev/null}"
echo '{"findings":[{"id":"CVE-1","severity":"Critical","pkg":"openssl","installed":"3.5.2","fixed":""},{"id":"CVE-2","severity":"High","pkg":"grafana","installed":"14.0.1","fixed":""},{"id":"CVE-3","severity":"Low","pkg":"openssl","installed":"3.5.2","fixed":""}],"error":""}'
EOF
chmod +x "${T}/scanner"
run() {  # $1 = scanner command
    OUT="$(SCANNED="${T}/scanned.json" python3 "${PP}" --inventory "${T}/site.cdx.json" --status "${T}/cve-status.json" \
        --closures "${T}/closures" --scanner "$1" --from aaaaaaaaaaaaaaaa --to bbbbbbbbbbbbbbbb --out "${T}/p.json" 2>&1)"; RC=$?
}
run "${T}/scanner --components {file}"
ck "runs" "0" "${RC}"
ck "a major is found: grafana 13 -> 14, in logging" "grafana 13.0.9 14.0.1 logging" "$(jq -r '.majors[] | "\(.pkg) \(.from) \(.to) \(.targets|join(","))"' "${T}/p.json")"
ck "a patch change is no major" "1" "$(jq '.majors | length' "${T}/p.json")"
ck "only what runs today is matched — no build tool" "false" "$(jq 'any(.[]; .name == "gcc")' "${T}/scanned.json")"
ck "…the next pin's versions are what is matched" "true" "$(jq 'any(.[]; .name == "openssl" and .version == "3.5.2")' "${T}/scanned.json")"
ck "a new critical/high CVE is introduced" "CVE-2 grafana High logging" "$(jq -r '.cves.introduced[] | "\(.key) \(.severity) \(.targets|join(","))"' "${T}/p.json")"
ck "one that stays is remaining, in both targets" "CVE-1 openssl coturn,logging" "$(jq -r '.cves.remaining[] | "\(.key) \(.targets|sort|join(","))"' "${T}/p.json")"
ck "one that goes is counted as fixed" "1" "$(jq '.cves.fixed' "${T}/p.json")"
ck "a source tarball in the closure is no version: loki stays a patch move" "grafana-loki 3.7.9" "$(jq -r '.targets.logging.changes[] | select(.pkg=="grafana-loki") | "\(.pkg) \(.to)"' "${T}/p.json")"
ck "low severity is not gated" "false" "$(jq '[.gate[] | contains("CVE-3")] | any' "${T}/p.json")"
ck "the gate: the major and the new CVE" '["cve CVE-2 grafana","major grafana 13->14"]' "$(jq -c '.gate' "${T}/p.json")"
ck "a target not evaluated is named, not silently clean" '["jellyfin"]' "$(jq -c '.notCompared' "${T}/p.json")"
ck "the summary names the major and the new CVE" "yes" "$([[ "${OUT}" == *"grafana"*"13.0.9 -> 14.0.1"* && "${OUT}" == *"NEW High"*"CVE-2 grafana"* ]] && echo yes || echo no)"
d1="$(jq -r .digest "${T}/p.json")"
run "${T}/scanner --components {file}"
ck "the same findings, the same digest" "${d1}" "$(jq -r .digest "${T}/p.json")"

printf '#!/usr/bin/env bash\necho "{\\"findings\\":[],\\"error\\":\\"grype failed: no db\\"}"; exit 1\n' > "${T}/bad"; chmod +x "${T}/bad"
run "${T}/bad --components {file}"
ck "a failed CVE match is no clean result: it is gated" "true" "$(jq '.gate | index("cve-match-failed") != null' "${T}/p.json")"
ck "…and said" "yes" "$([[ "${OUT}" == *"CVE match FAILED"* ]] && echo yes || echo no)"

printf '#!/usr/bin/env bash\necho "{\\"findings\\":[],\\"error\\":\\"\\"}"\n' > "${T}/clean"; chmod +x "${T}/clean"
# The noise a release move to nixos-unstable showed on hrossen (2026-10-08).
cat > "${T}/site.cdx.json" <<EOF
{"components":[{"name":"y","properties":[{"name":"tappaas:layer","value":"nix"}],"components":[
  {"name":"abseil-cpp","version":"20260107.1"},{"name":"less","version":"692"},{"name":"systemd","version":"260.4"},
  {"name":"polkit","version":"126"},{"name":"xgcc","version":"15.3.0"},{"name":"protobuf","version":"34.1"},
  {"name":"postgresql","version":"17.11"}]}]}
EOF
printf '/nix/store/%s-abseil-cpp-20260817.0.drv\n/nix/store/%s-less-710.drv\n/nix/store/%s-systemd-261.3.drv\n/nix/store/%s-polkit-1.pam.drv\n/nix/store/%s-polkit-127.drv\n/nix/store/%s-xgcc-16.2.0.drv\n/nix/store/%s-protobuf-33.6.drv\n/nix/store/%s-postgresql-18.6.drv\n' \
    "$H" "$H" "$H" "$H" "$H" "$H" "$H" "$H" > "${T}/closures/y.txt"
echo '{"packages":{"xgcc":"GCC runtime libraries"}}' > "${T}/ignore.json"
OUT="$(python3 "${PP}" --inventory "${T}/site.cdx.json" --status "${T}/cve-status.json" --closures "${T}/closures" \
    --scanner "${T}/clean --components {file}" --from a --to b --out "${T}/p.json" --ignore "${T}/ignore.json" 2>&1)"
ck "a real major still counts: postgresql 17 -> 18" "true" "$(jq '[.majors[].pkg] | index("postgresql") != null' "${T}/p.json")"
ck "a date version is no major (abseil 20260107 -> 20260817)" "false" "$(jq '[.majors[].pkg] | index("abseil-cpp") != null' "${T}/p.json")"
ck "a sequence version is no major (less 692 -> 710, systemd 260 -> 261)" "false" "$(jq '[.majors[].pkg] | (index("less") != null or index("systemd") != null)' "${T}/p.json")"
ck "a generated file is no version (polkit-1.pam): polkit 126 -> 127 is a sequence step" "127" "$(jq -r '.targets.y.changes[] | select(.pkg=="polkit") | .to' "${T}/p.json")"
ck "an ignored package is not gated" "false" "$(jq '[.majors[].pkg] | index("xgcc") != null' "${T}/p.json")"
ck "…and said why, with the others not gated" "GCC runtime libraries" "$(jq -r '.notGated[] | select(.pkg=="xgcc") | .why' "${T}/p.json")"
ck "a major that goes down is labelled a downgrade" "true" "$(jq '.majors[] | select(.pkg=="protobuf") | .downgrade' "${T}/p.json")"
ck "…in the summary too" "yes" "$([[ "${OUT}" == *"protobuf"*"(a DOWNGRADE)"* ]] && echo yes || echo no)"
ck "the gate holds only the real ones" '["major postgresql 17->18","major protobuf 34->33"]' "$(jq -c '.gate' "${T}/p.json")"
rm -f "${T}/closures/y.txt"

echo '{"components":[{"name":"x","properties":[{"name":"tappaas:layer","value":"nix"}],"components":[{"name":"zlib","version":"1.3.1"}]}]}' > "${T}/site.cdx.json"
printf '/nix/store/%s-zlib-1.3.1.drv\n' "$H" > "${T}/closures/x.txt"
run "${T}/clean --components {file}"
ck "nothing changes: nothing to acknowledge" "[]" "$(jq -c '.gate' "${T}/p.json")"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
