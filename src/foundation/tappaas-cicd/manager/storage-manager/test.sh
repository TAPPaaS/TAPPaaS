#!/usr/bin/env bash
# test.sh — storage-manager offline test suite (ADR-029 v0.9).
#
# Compiles the TS sources + unit tests, runs the unit suite (the verbs and the shared
# share model), then drives the compiled CLI against a temp config dir: a fake node
# whose module "ships" a hook, a fake storage module whose nfs-converge.sh records
# what it is asked to converge — never the live config, a node or the firewall.
# The end-to-end suite against a real node is the storage module's
# (src/foundation/storage/test.sh --deep).
set -uo pipefail
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && export TAPPAAS_TEST_DEEP=1; done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()   { echo "  ok: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1" >&2; fail=$((fail + 1)); }

for f in "${HERE}"/*.sh; do bash -n "$f" && ok "$(basename "$f") parses" || bad "$(basename "$f") syntax"; done

run_ts() {
    if command -v tsc >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then bash -c "$1"
    elif command -v nix-shell >/dev/null 2>&1; then nix-shell -p typescript nodejs_22 --run "$1"
    else return 127; fi
}
DIST="${HERE}/dist-test"
rm -rf -- "${DIST}"
run_ts "tsc --noEmit -p '${HERE}/tsconfig.json'" >/dev/null 2>&1 && ok "tsc --noEmit clean (src)" || bad "tsc --noEmit reported type errors (src)"
if run_ts "tsc -p '${HERE}/test/unit/tsconfig.json'" >/dev/null 2>&1; then ok "sources + unit tests compile"
else bad "unit tests do not compile"; echo "storage-manager test: ${pass} passed, ${fail} failed"; exit 1; fi
for unit in $(cd "${HERE}/test/unit" && ls *.test.ts | sed 's/\.test\.ts$//'); do
    run_ts "node '${DIST}/manager/storage-manager/test/unit/${unit}.test.js'" >/dev/null 2>&1 \
        && ok "unit: ${unit}" || bad "unit: ${unit} (rerun: node ${DIST}/manager/storage-manager/test/unit/${unit}.test.js)"
done

# ── the CLI against a fixture config ─────────────────────────────────
FIX="$(mktemp -d "${TMPDIR:-/tmp}/sm-fix.XXXXXX")"
trap 'rm -rf "${FIX}" "${DIST}"' EXIT
mkdir -p "${FIX}/cfg" "${FIX}/pvehost/storage" "${FIX}/storage/lib"
printf '#!/bin/sh\nexit 0\n' > "${FIX}/pvehost/storage/nfs-server.sh"
printf '#!/bin/sh\necho "converge $*" >> "%s/converge.log"\n' "${FIX}" > "${FIX}/storage/lib/nfs-converge.sh"
chmod +x "${FIX}/pvehost/storage/nfs-server.sh" "${FIX}/storage/lib/nfs-converge.sh"
cat > "${FIX}/cfg/tappaas1.json" <<JSON
{"kind":"machine","management":"managed","zone0":"mgmt","address":"tappaas1.mgmt.internal","moduleSource":"${FIX}/pvehost"}
JSON
cat > "${FIX}/cfg/storage.json" <<JSON
{"kind":"application","provides":["nfs"],"moduleSource":"${FIX}/storage"}
JSON
cat > "${FIX}/cfg/jellyfin.json" <<'JSON'
{"vmname":"jellyfin","zone0":"srvHome","dependsOn":["cluster:vm","network:rules","storage:nfs"],
 "config":{"storage:nfs":{"mounts":[{"path":"/media","share":"media","access":"rw"}]}}}
JSON
# Both spellings: TS reads TAPPAAS_CONFIG first, and an inherited one would
# point this suite at the live config.
SM() { CONFIG_DIR="${FIX}/cfg" TAPPAAS_CONFIG="${FIX}/cfg" run_ts "node '${DIST}/manager/storage-manager/src/main.js' $*"; }
last() { tail -1 "${FIX}/converge.log" 2>/dev/null; }

SM nfs share add media --server tappaas1 --pool tankb1 --quota 4T --backup true --check >/dev/null 2>&1
[[ ! -f "${FIX}/cfg/shares.json" ]] && ok "add --check writes nothing" || bad "add --check wrote shares.json"
SM nfs share add media --server tappaas1 --pool tankb1 --quota 4T --backup true --prop recordsize=1M >/dev/null 2>&1 \
    && ok "add: a managed share" || bad "add: a managed share"
[[ "$(jq -r '.nfs.shares.media.owner.uid' "${FIX}/cfg/shares.json")" == "64000" ]] && ok "add: owner allocated into shares.json" || bad "add: owner allocated"
[[ "$(last)" == "converge share media --notify" ]] && ok "add: converges the share and notifies" || bad "add: converge call ($(last))"
SM nfs share add media --server tappaas1 --pool tankb1 --backup true >/dev/null 2>&1 && bad "add: a duplicate name refused" || ok "add: a duplicate name refused"
SM nfs share add bad --server tappaas1 --pool tankb1 >/dev/null 2>&1 && bad "add: --backup required" || ok "add: --backup required"
SM nfs grant media jellyfin rw >/dev/null 2>&1 && ok "grant" || bad "grant"
[[ "$(jq -r '.nfs.shares.media.grants.jellyfin' "${FIX}/cfg/shares.json")" == "rw" ]] && ok "grant: recorded" || bad "grant: recorded"
SM nfs revoke media jellyfin >/dev/null 2>&1 && bad "revoke: refused while jellyfin mounts media" || ok "revoke: refused while jellyfin mounts media"
SM nfs share delete media >/dev/null 2>&1 && bad "delete: refused while mounted" || ok "delete: refused while mounted"
SM nfs share modify media --set quota=8T >/dev/null 2>&1 && ok "modify: quota" || bad "modify: quota"
[[ "$(jq -r '.nfs.shares.media.quota' "${FIX}/cfg/shares.json")" == "8T" ]] && ok "modify: recorded" || bad "modify: recorded"
SM nfs share modify media --set pool=tankc1 >/dev/null 2>&1 && bad "modify: pool refused" || ok "modify: pool refused"
SM validate >/dev/null 2>&1 && ok "validate: the result is valid" || bad "validate"
SM nfs show >/dev/null 2>&1 && ok "show" || bad "show"
[[ "$(SM nfs show media --json 2>/dev/null | jq -r '.media.server')" == "tappaas1" ]] && ok "show --json" || bad "show --json"
jq '.config["storage:nfs"].mounts = []' "${FIX}/cfg/jellyfin.json" > "${FIX}/t" && mv "${FIX}/t" "${FIX}/cfg/jellyfin.json"
SM nfs revoke media jellyfin >/dev/null 2>&1 && ok "revoke: once the mount is gone" || bad "revoke: once the mount is gone"
SM nfs share delete media >/dev/null 2>&1 && ok "delete: once nothing mounts it" || bad "delete"
[[ "$(last)" == "converge drop media tappaas1" ]] && ok "delete: drops the alias and reconverges the server" || bad "delete: converge call ($(last))"
SM nfs share purge media --server tappaas1 >/dev/null 2>&1 && bad "purge: needs --yes" || ok "purge: needs --yes"
SM nfs share purge media --server tappaas1 --yes >/dev/null 2>&1 && ok "purge: an orphan" || bad "purge"
[[ "$(last)" == "converge purge media tappaas1" ]] && ok "purge: asks the server's hook" || bad "purge: converge call ($(last))"
echo '{"kind":"machine","management":"managed","moduleSource":"/nowhere"}' > "${FIX}/cfg/debhost.json"
SM nfs share add x --server debhost --pool p --backup false >/dev/null 2>&1 && bad "add: a server without a hook refused" || ok "add: a server without a hook refused"
echo '{"kind":"machine","management":"unmanaged","zone0":"home","address":"10.3.10.50"}' > "${FIX}/cfg/nas1.json"
SM nfs share add video --server nas1 --path /volume1/video --version 4.1 >/dev/null 2>&1 && ok "add: a registered server's share" || bad "add: a registered server's share"
SM nfs share add old --server nas1 --path /v --version 3 >/dev/null 2>&1 && bad "add: NFSv3 without pinned ports refused" || ok "add: NFSv3 without pinned ports refused"

rm -rf -- "${DIST}"
echo ""
echo "storage-manager test: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
