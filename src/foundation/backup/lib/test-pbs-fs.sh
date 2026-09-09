#!/usr/bin/env bash
#
# Unit tests for the pure helpers behind backup:filesystem (ADR-012 §3.1, D17)
# — pbs-fs.sh. No cluster access: namespace/archive/authid derivation, the guest
# OS gate, the manifest shape and the declared-path reader.
#
# Usage: ./test-pbs-fs.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { :; }; debug() { :; }; warn() { :; }; error() { echo "ERR: $*" >&2; }
BOLD=""; CL=""; BL=""; GN=""; BGN=""
get_node_hostname() { echo "tappaas1"; }
CONFIG_DIR="$(mktemp -d)"

# shellcheck source=pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-job.sh"
# shellcheck source=pbs-fs.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-fs.sh"

PASS=0; FAIL=0
ck()    { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
ck_rc() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp rc $2 got $3)"; FAIL=$((FAIL+1)); fi; }

# ── namespace + authid: one isolated tree and login per module ───────
ck "namespace: fs/<module>"     "fs/nextcloud"     "$(pbs_fs_namespace nextcloud)"
ck "namespace: dashed module"   "fs/tappaas-cicd"  "$(pbs_fs_namespace tappaas-cicd)"
ck "authid: scoped per module"  "tappaas-cicd-fs@pbs" "$(pbs_fs_authid tappaas-cicd)"

# ── archive names: a flat identifier per captured path ───────────────
ck "archive name: nested path"   "home-tappaas-config" "$(pbs_fs_archive_name /home/tappaas/config)"
ck "archive name: trailing slash" "etc-secrets"        "$(pbs_fs_archive_name /etc/secrets/)"
ck "archive name: single segment" "srv"                "$(pbs_fs_archive_name /srv)"
ck "archive name: root"           "root"               "$(pbs_fs_archive_name /)"
ck "archive name: spaces folded"  "var-my-data"        "$(pbs_fs_archive_name '/var/my data')"
ck "archive name: keeps dots"     "etc-my.conf.d"      "$(pbs_fs_archive_name /etc/my.conf.d)"
ck "archive spec"  "home-tappaas-config.pxar:/home/tappaas/config" "$(pbs_fs_archive_spec /home/tappaas/config)"

# ── the guest OS gate ────────────────────────────────────────────────
for good in nixos NixOS nix; do
    pbs_fs_os_supported "${good}" && r=0 || r=1
    ck_rc "os gate: '${good}' supported" 0 "$r"
done
for bad in debian ubuntu windows l26 ""; do
    pbs_fs_os_supported "${bad}" && r=0 || r=1
    ck_rc "os gate: '${bad:-<empty>}' NOT supported (fails loudly rather than half-capturing)" 1 "$r"
done

# ── declared paths ───────────────────────────────────────────────────
printf '%s\n' '{"backup":{"filesystemPaths":["/home/tappaas/config","/etc/secrets"]}}' > "${CONFIG_DIR}/m.json"
ck "paths: read from the module config" $'/home/tappaas/config\n/etc/secrets' "$(pbs_fs_paths m)"
printf '%s\n' '{"backup":{}}' > "${CONFIG_DIR}/none.json"
ck "paths: absent → empty" "" "$(pbs_fs_paths none)"
ck "paths: no such module → empty" "" "$(pbs_fs_paths ghost)"

# ── the manifest the guest-side runner reads ─────────────────────────
PBS_FS_CONFIG_DIR="${CONFIG_DIR}"
ck "manifest path" "${CONFIG_DIR}/m.fsbackup.json" "$(pbs_fs_manifest_path m)"
pbs_fs_write_manifest m "u@pbs@host:store" "fs/m" "weekly" /home/tappaas/config /etc/secrets
M="${CONFIG_DIR}/m.fsbackup.json"
ck "manifest: valid json"    "yes"    "$(jq -e . "${M}" >/dev/null 2>&1 && echo yes || echo no)"
ck "manifest: module"        "m"      "$(jq -r .module "${M}")"
ck "manifest: repository"    "u@pbs@host:store" "$(jq -r .repository "${M}")"
ck "manifest: namespace"     "fs/m"   "$(jq -r .namespace "${M}")"
ck "manifest: schedule"      "weekly" "$(jq -r .schedule "${M}")"
ck "manifest: paths kept in order" $'/home/tappaas/config\n/etc/secrets' "$(jq -r '.paths[]' "${M}")"
# A manifest is config, not a secret store (§2.5): it must never carry one.
ck "manifest: carries no credential" "no" \
   "$(jq -e 'has("password") or has("key") or has("secret")' "${M}" >/dev/null 2>&1 && echo yes || echo no)"
# It must also not look like a module config to discovery (#544/P16).
ck "manifest: is not module-shaped" "no" \
   "$(jq -e 'has("dependsOn") or has("provides") or has("location") or .kind == "module"' "${M}" >/dev/null 2>&1 && echo yes || echo no)"

rm -rf "${CONFIG_DIR}"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
