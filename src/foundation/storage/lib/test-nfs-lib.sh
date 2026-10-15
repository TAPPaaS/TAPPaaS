#!/usr/bin/env bash
#
# Unit tests for the share model behind storage:nfs (ADR-029 v0.9) — nfs-lib.sh,
# nfs-guest.sh, nfs-converge.sh and the node's nfs-node.sh. No server, no guest:
# share references, config/shares.json lookups, the sharenfs renderer, share and
# mount checks (pending, the two-key check, subdir), the firewall path, the wan
# refusal, the client list, server kinds and alias targets, and the guest
# rendering — including the automount-aware probe. storage-manager's unit suite
# (lib/ts/src/nfs-shares.ts) pins the same rules.
#
# Usage: ./test-nfs-lib.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFS_CONFIG_DIR="$(mktemp -d)"
trap 'rm -rf "${NFS_CONFIG_DIR}"' EXIT

# shellcheck source=nfs-lib.sh disable=SC1091
. "${SCRIPT_DIR}/nfs-lib.sh"
# shellcheck source=nfs-guest.sh disable=SC1091
. "${SCRIPT_DIR}/nfs-guest.sh"
# shellcheck source=nfs-converge.sh disable=SC1091
. "${SCRIPT_DIR}/nfs-converge.sh"
info() { :; }; debug() { :; }; warn() { :; }; error() { :; }; GN=""; CL=""; BOLD=""; BL=""

PASS=0; FAIL=0
ck()    { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
ck_rc() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp rc $2 got $3)"; FAIL=$((FAIL+1)); fi; }
has()   { if grep -q -- "$2" <<< "$3"; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 ('$2' not in: $3)"; FAIL=$((FAIL+1)); fi; }

# ── share references (D2, v0.8) ───────────────────────────────────────
ck "ref: a share name"         "named media"                    "$(nfs_parse_share_ref media)"
ck "ref: literal"              "literal nas.lan /volume1/video" "$(nfs_parse_share_ref nas.lan:/volume1/video)"
ck "ref: literal by IP"        "literal 10.2.0.9 /x"            "$(nfs_parse_share_ref 10.2.0.9:/x)"
nfs_parse_share_ref tappaas1:media 2>/dev/null; ck_rc "ref: the withdrawn <instance>:<name> form refused" 1 $?
nfs_parse_share_ref Media 2>/dev/null;          ck_rc "ref: bad name refused" 1 $?
ck "alias" "nfs-media.mgmt.internal" "$(nfs_share_alias media)"

# ── sharenfs (D4a) ────────────────────────────────────────────────────
ck "sharenfs: nobody granted is off, never on" "off" "$(nfs_render_sharenfs 64000 64000 "" "")"
ck "sharenfs: rw + ro clients" \
   "rw=@10.2.0.5/32,ro=@10.2.0.6/32:@10.2.0.7/32,sec=sys,root_squash,all_squash,anonuid=64000,anongid=64000,no_subtree_check" \
   "$(nfs_render_sharenfs 64000 64000 "10.2.0.5" "10.2.0.6 10.2.0.7")"
s="$(nfs_render_sharenfs 64001 64001 "10.2.0.5" "")"
has "sharenfs: root_squash is explicit (libshare defaults to no_root_squash)" "root_squash" "${s}"
if grep -q "no_root_squash" <<< "${s}"; then ck "sharenfs: never no_root_squash" "absent" "present"; else ck "sharenfs: never no_root_squash" "absent" "absent"; fi
ck "dataset path" "tankb1/tappaas-nfs/media" "$(nfs_dataset tankb1 media)"

# ── share declarations (D4, D2a) ──────────────────────────────────────
ok_share='{"name":"media","server":"tappaas1","pool":"tankb1","quota":"4T","backup":{"enabled":true},"grants":{"jellyfin":"rw"}}'
nfs_check_export "${ok_share}" managed >/dev/null; ck_rc "share: a complete managed share passes" 0 $?
out="$(nfs_check_export '{"name":"media","server":"t","pool":"tankb1"}' managed)"; ck_rc "share: backup.enabled missing refused" 1 $?
has "share: says backup.enabled has no default" "no default" "${out}"
out="$(nfs_check_export '{"name":"media","pool":"tankb1","backup":{"enabled":false}}' managed)"; has "share: server required" "server is required" "${out}"
out="$(nfs_check_export '{"name":"media","server":"t","backup":{"enabled":false}}' managed)"; has "share: pool required on managed" "pool is required" "${out}"
out="$(nfs_check_export '{"name":"media","server":"t","pool":"tankb1","path":"/x","backup":{"enabled":false}}' managed)"; has "share: path refused on managed" "path is for a registered" "${out}"
out="$(nfs_check_export '{"name":"media","server":"t","pool":"tankb1","backup":{"enabled":false},"owner":{"uid":1000,"gid":1000}}' managed)"; has "share: owner outside range refused" "owner must be" "${out}"
out="$(nfs_check_export '{"name":"media","server":"t","pool":"tankb1","backup":{"enabled":false},"properties":{"mountpoint":"/x"}}' managed)"; has "share: unknown property refused" "property mountpoint" "${out}"
out="$(nfs_check_export '{"name":"media","server":"t","pool":"tankb1","backup":{"enabled":false},"grants":{"a":"admin"}}' managed)"; has "share: bad access refused" "is admin" "${out}"
out="$(nfs_check_export '{"name":"media","server":"t","pool":"tankb1","backup":{"enabled":false},"grants":[{"consumer":"a"}]}' managed)"; has "share: v0.8 grant list refused — a map now" "grants must be a map" "${out}"
nfs_check_export '{"name":"video","server":"nas1","path":"/volume1/video","version":"4.1","grants":{"jellyfin":"ro"}}' unmanaged >/dev/null; ck_rc "share: a registered server descriptor passes" 0 $?
out="$(nfs_check_export '{"name":"video","server":"n","path":"/v","pool":"x","backup":{"enabled":true}}' unmanaged)"; has "share: pool refused on unmanaged" "pool is not allowed" "${out}"
out="$(nfs_check_export '{"name":"video","server":"n","path":"/v","version":"3"}' unmanaged)"; has "share: v3 without pinned ports refused" "v3Ports" "${out}"

# ── fixtures: shares.json, two nodes, a NAS, consumers ────────────────
cat > "${NFS_CONFIG_DIR}/shares.json" <<'EOF'
{"nfs":{"shares":{
  "media":{"server":"tappaas1","pool":"tankb1","backup":{"enabled":true},"owner":{"uid":64000,"gid":64000},
           "grants":{"jellyfin":"rw","viewer":"ro","gone":"rw","idle":"rw"}},
  "photos":{"server":"tappaas2","pool":"tankb1","backup":{"enabled":false},"owner":{"uid":64002,"gid":64002}},
  "video":{"server":"nas1","path":"/volume1/video","version":"4.1","grants":{"jellyfin":"ro"}},
  "outside":{"server":"edge","path":"/x","grants":{"jellyfin":"ro"}}}}}
EOF
mkdir -p "${NFS_CONFIG_DIR}/mod/pvehost/storage"
printf '#!/bin/sh\n' > "${NFS_CONFIG_DIR}/mod/pvehost/storage/nfs-server.sh"; chmod +x "${NFS_CONFIG_DIR}/mod/pvehost/storage/nfs-server.sh"
echo "{\"kind\":\"machine\",\"management\":\"managed\",\"zone0\":\"mgmt\",\"address\":\"tappaas1.mgmt.internal\",\"moduleSource\":\"${NFS_CONFIG_DIR}/mod/pvehost\"}" > "${NFS_CONFIG_DIR}/tappaas1.json"
echo '{"kind":"machine","management":"managed","zone0":"mgmt","address":"tappaas2.mgmt.internal","moduleSource":"/nowhere/debianhost"}' > "${NFS_CONFIG_DIR}/tappaas2.json"
echo '{"kind":"machine","management":"unmanaged","zone0":"home","address":"10.3.10.50"}' > "${NFS_CONFIG_DIR}/nas1.json"
echo '{"kind":"machine","management":"unmanaged","zone0":"wan"}' > "${NFS_CONFIG_DIR}/edge.json"
echo '{"zone0":"srvHome","vmname":"jellyfin","dependsOn":["storage:nfs","network:rules"],"config":{"storage:nfs":{"mounts":[{"path":"/media","share":"media","subdir":"jellyfin","access":"rw"}]}}}' > "${NFS_CONFIG_DIR}/jellyfin.json"
echo '{"zone0":"srvHome","dependsOn":["storage:nfs"]}' > "${NFS_CONFIG_DIR}/viewer.json"
echo '{"zone0":"mgmt","dependsOn":["storage:nfs"],"config":{"storage:nfs":{"mounts":[]}}}' > "${NFS_CONFIG_DIR}/idle.json"
m() { nfs_check_mount "$1" "$2"; }

# ── finding a share in shares.json (D2, D4) ───────────────────────────
ck "find: a node's share"      "tappaas1" "$(nfs_find_share media)"
ck "find: a NAS's share"       "nas1"     "$(nfs_find_share video)"
nfs_find_share nope >/dev/null 2>&1; ck_rc "find: an undeclared share → rc 1 (pending)" 1 $?
ck "exports: the shares declared for one server" "media" "$(nfs_exports tappaas1 | jq -r .name)"
ck "grant lookup" "rw" "$(nfs_grant_for media jellyfin)"
ck "grant lookup: none" "" "$(nfs_grant_for media stranger)"
ck "export path: a node's uniform mountpoint" "/tappaas-nfs/media" "$(nfs_export_path tappaas1 "$(nfs_export tappaas1 media)")"
ck "export path: a NAS's own path"            "/volume1/video"     "$(nfs_export_path nas1 "$(nfs_export nas1 video)")"
mv "${NFS_CONFIG_DIR}/shares.json" "${NFS_CONFIG_DIR}/shares.json.off"
nfs_find_share media >/dev/null 2>&1; ck_rc "find: no shares.json — every share pending" 1 $?
mv "${NFS_CONFIG_DIR}/shares.json.off" "${NFS_CONFIG_DIR}/shares.json"

# ── server kinds and alias targets (D19, D2b) ─────────────────────────
ck "kind: a node whose module ships the hook" "hook" "$(nfs_server_kind tappaas1)"
ck "kind: a managed machine without a hook"   "nohook" "$(nfs_server_kind tappaas2)"
ck "kind: a registered server"                 "unmanaged" "$(nfs_server_kind nas1)"
ck "kind: no such instance"                    "missing" "$(nfs_server_kind ghost)"
ck "alias target: a node's FQDN address"       "tappaas1 mgmt.internal" "$(nfs_alias_target tappaas1)"
ck "alias target: an IP-addressed NAS by its instance name" "nas1 home.internal" "$(nfs_alias_target nas1)"
ck "consumers of a share: granted, deployed, mounting" "jellyfin" "$(nfs_share_consumers media)"
# A grant tells the consumer it added, not every consumer already served (#832).
_svc_dir="$(mktemp -d)"; mkdir -p "${_svc_dir}/lib" "${_svc_dir}/services/nfs"
printf '#!/bin/sh\necho "$1"\n' > "${_svc_dir}/services/nfs/update-service.sh"; chmod +x "${_svc_dir}/services/nfs/update-service.sh"
_saved_dir="${NFS_CONVERGE_DIR}"; NFS_CONVERGE_DIR="${_svc_dir}/lib"
has "notify: every mounting consumer"          "jellyfin" "$(nfs_notify media 2>&1)"
ck  "notify-only: a consumer not named is left alone" "" "$(nfs_notify media someone-else 2>/dev/null | grep -v 'share media')"
has "notify-only: the named consumer runs"     "jellyfin" "$(nfs_notify media jellyfin 2>&1)"
NFS_CONVERGE_DIR="${_saved_dir}"; rm -rf "${_svc_dir}"

# ── mounts: pending, the two-key check, subdir (D3, D11, D15) ─────────
m jellyfin '{"path":"/media","share":"media","subdir":"jellyfin","access":"rw"}' >/dev/null; ck_rc "mount: granted rw passes" 0 $?
out="$(m jellyfin '{"path":"/srv/x","share":"nope"}')";   ck_rc "mount: an undeclared share is pending, not refused" 0 $?
ck "status: pending"   "pending"            "$(nfs_mount_status '{"share":"nope"}')"
ck "status: available" "available tappaas1" "$(nfs_mount_status '{"share":"media"}')"
ck "status: literal"   "literal"            "$(nfs_mount_status '{"share":"10.2.0.9:/x"}')"
out="$(m viewer '{"path":"/srv/m","share":"media","access":"rw"}')"; has "mount: rw against an ro grant refused" "grants viewer only ro" "${out}"
out="$(m stranger '{"path":"/srv/m","share":"media"}')";   ck_rc "mount: an existing share without a grant is an error" 1 $?
has "mount: prints the verb to run" "storage-manager nfs grant media stranger" "${out}"
out="$(m jellyfin '{"path":"/srv/x","share":"tappaas1:/tappaas-nfs/media"}')"; has "mount: a literal on a module instance refused" "name its share" "${out}"
out="$(m jellyfin '{"path":"/m","share":"media","subdir":"../etc"}')";  has "subdir: .. refused" "subdir" "${out}"
out="$(m jellyfin '{"path":"/m","share":"media","stopUnits":"jellyfin.service"}')"; has "stopUnits: must be a list" "stopUnits" "${out}"
out="$(m jellyfin '{"path":"/etc","share":"media","access":"rw"}')";   has "mount: /etc refused" "not a directory a share may cover" "${out}"

# ── the firewall path (D5 layer 2) and the wan refusal (D2a) ──────────
out="$(m viewer '{"path":"/m","share":"media"}')"; has "path: cross-zone without network:rules refused" "must depend on network:rules" "${out}"
m idle '{"path":"/m","share":"media"}' >/dev/null; ck_rc "path: same zone needs no rule" 0 $?
m viewer '{"path":"/m","share":"nope"}' >/dev/null; ck_rc "path: a pending mount needs no rule" 0 $?
out="$(m jellyfin '{"path":"/f","share":"8.8.8.8:/x"}')"; has "wan: a public literal IP refused" "public address" "${out}"
out="$(m jellyfin '{"path":"/f","share":"outside"}')";    has "wan: a share on a wan-zone server refused" "wan zone" "${out}"
nfs_is_public_ipv4 100.64.1.1; ck_rc "wan: CGNAT (the overlay) is not public" 1 $?

# ── the client list follows the consumers (D16) — the node's code ─────
. "${SCRIPT_DIR}/../../pvehost/lib/nfs-node.sh"
nfs_consumer_address() { case "$1" in jellyfin) echo 10.2.0.116 ;; viewer) echo 10.2.0.117 ;; idle) echo 10.0.0.50 ;; esac; }
e="$(nfs_export tappaas1 media)"
ck "clients: only granted, deployed, mounting consumers" "jellyfin rw 10.2.0.116" "$(nfs_node_clients "${e}")"
ck "clients: a deleted consumer (no config) contributes nothing" "" "$(nfs_node_clients "${e}" | grep gone)"
ck "clients: a granted consumer that does not mount contributes nothing" "" "$(nfs_node_clients "${e}" | grep idle)"
ck "clients: the consumer being deleted is left out" "" "$(NFS_EXCLUDE_CONSUMERS=jellyfin nfs_node_clients "${e}")"
has "share: the expected sharenfs" "rw=@10.2.0.116/32" "$(nfs_node_expected_share "${e}")"
ck "share: nobody mounting → off" "off" "$(NFS_EXCLUDE_CONSUMERS=jellyfin nfs_node_expected_share "${e}")"

# ── the guest side (D2b, D3, D10, D14, D15) ───────────────────────────
r1="$(nfs_resolve_mount '{"path":"/media","share":"media","subdir":"jellyfin","access":"rw"}')"
ck "resolve: a node's share → alias + uniform path + subdir" \
   "/media	nfs-media.mgmt.internal:/tappaas-nfs/media/jellyfin	4.2	rw	false	available" "${r1}"
r2="$(nfs_resolve_mount '{"path":"/srv/v","share":"video","required":true}')"
ck "resolve: a NAS's share → alias + its own path + its version" \
   "/srv/v	nfs-video.mgmt.internal:/volume1/video	4.1	ro	true	available" "${r2}"
r3="$(nfs_resolve_mount '{"path":"/srv/f","share":"files.example:/exports/shared"}')"
ck "resolve: unmodelled → the literal" "/srv/f	files.example:/exports/shared	4.2	ro	false	literal" "${r3}"
r4="$(nfs_resolve_mount '{"path":"/srv/p","share":"nope"}')"
ck "resolve: pending → no source" "/srv/p	-	-	ro	false	pending" "${r4}"
ck "options: not required → nofail + automount" "vers=4.2,rw,hard,_netdev,noatime,nofail,x-systemd.automount,x-systemd.mount-timeout=30" "$(nfs_mount_options 4.2 rw false)"
ck "options: required → no nofail" "vers=4.2,ro,hard,_netdev,noatime" "$(nfs_mount_options 4.2 ro true)"
ck "options: runtime (migration) → kernel subset" "vers=4.2,rw,hard,noatime" "$(nfs_runtime_options 4.2 rw)"
nix="$(nfs_render_nixos "${r1}"$'\n'"${r2}"$'\n'"${r4}")"
has "nixos: device through the alias" 'device = "nfs-media.mgmt.internal:/tappaas-nfs/media/jellyfin";' "${nix}"
has "nixos: nfs support always" 'boot.supportedFilesystems = \[ "nfs" \];' "${nix}"
has "nixos: rsync for a later migration" "pkgs.rsync" "${nix}"
if grep -q '"/srv/p"' <<< "${nix}"; then ck "nixos: a pending mount has no entry" "absent" "present"; else ck "nixos: a pending mount has no entry" "absent" "absent"; fi
only_pending="$(nfs_render_nixos "${r4}")"
has "nixos: all pending still carries NFS support" 'boot.supportedFilesystems' "${only_pending}"
if command -v nix-instantiate >/dev/null 2>&1; then
    printf '%s\n' "${nix}" > "${NFS_CONFIG_DIR}/frag.nix"
    nix-instantiate --parse "${NFS_CONFIG_DIR}/frag.nix" >/dev/null 2>&1; ck_rc "nixos: the fragment parses" 0 $?
fi
fst="$(nfs_render_fstab "${r1}"$'\n'"${r4}")"
has "fstab: marked block" "BEGIN storage:nfs" "${fst}"
has "fstab: line through the alias" "nfs-media.mgmt.internal:/tappaas-nfs/media/jellyfin /media nfs vers=4.2,rw,hard" "${fst}"
ms="$(nfs_migrate_script /media nfs-media.mgmt.internal:/tappaas-nfs/media/jellyfin vers=4.2,rw,hard,noatime "jellyfin.service" "" "")"
bash -n <<< "${ms}"; ck_rc "migrate: the guest script parses" 0 $?
has "migrate: never preserves ownership (writes are squashed)" "rsync -rlptH --no-owner --no-group" "${ms}"
has "migrate: second pass deletes what the app removed meanwhile" "rsync -rlptH --no-owner --no-group --delete" "${ms}"
has "migrate: an occupied share is not merged" "not merged" "${ms}"
has "migrate: the open-files guard" "open-files guard" "${ms}"
has "migrate: an interrupted migration resumes" "resuming an earlier" "${ms}"
has "migrate: the marker is never deleted by pass 2" "rsync -rlptH --no-owner --no-group --delete --exclude=/.tappaas-nfs-migrating" "${ms}"
has "migrate: the local copy is kept aside" '.pre-nfs' "${ms}"
ms2="$(nfs_migrate_script /m src opts "" "docker stop app" "docker start app")"
has "migrate: stopCommand runs" "docker stop app" "${ms2}"
has "migrate: startCommand runs" "docker start app" "${ms2}"
bash -n <<< "${ms2}"; ck_rc "migrate: the script with commands parses" 0 $?
probe="$(nfs_guest_probe_script /media)"
bash -n <<< "${probe}"; ck_rc "probe: the guest script parses" 0 $?
has "probe: recognises an automount first" "findmnt -n -t autofs --mountpoint" "${probe}"
has "probe: reports what the guest's mount list declares" "findmnt -n -s -o SOURCE" "${probe}"
has "probe: an automount is never local data (v0.9 bug 3)" 'l=no; \[ "\$a" = no \]' "${probe}"
echo '{"rebootOk":true}' > "${NFS_CONFIG_DIR}/ok.json"; echo '{}' > "${NFS_CONFIG_DIR}/no.json"
nfs_consent ok; ck_rc "consent: rebootOk" 0 $?
nfs_consent no; ck_rc "consent: none without rebootOk or --allow-disruption" 1 $?
TAPPAAS_ALLOW_DISRUPTION=1 nfs_consent no; ck_rc "consent: --allow-disruption" 0 $?

# ── the sweep drops share aliases of undeclared shares (D2b) ──────────
DNS_LOG="${NFS_CONFIG_DIR}/dns.log"; : > "${DNS_LOG}"
dns-manager() { echo "$*" >> "${DNS_LOG}"; }
NFS_ALIAS_CACHE=$'nfs-media.mgmt.internal tappaas1.mgmt.internal\nnfs-old.mgmt.internal tappaas2.mgmt.internal\nnfs.mgmt.internal x\nwiki.mgmt.internal tappaas1.mgmt.internal'
nfs_drop_orphan_aliases; ck_rc "orphan aliases: the sweep succeeds" 0 $?
has "orphan aliases: an undeclared share's alias goes" "alias delete nfs-old.mgmt.internal" "$(cat "${DNS_LOG}")"
ck "orphan aliases: declared shares and other names stay" "1" "$(grep -c "alias delete" "${DNS_LOG}")"
cp "${NFS_CONFIG_DIR}/shares.json" "${NFS_CONFIG_DIR}/shares.json.keep"; echo '{broken' > "${NFS_CONFIG_DIR}/shares.json"; : > "${DNS_LOG}"
NFS_ALIAS_CACHE=$'nfs-media.mgmt.internal tappaas1.mgmt.internal'
nfs_drop_orphan_aliases; ck_rc "orphan aliases: an unreadable shares.json refuses" 1 $?
ck "orphan aliases: …and removes nothing" "0" "$(grep -c "alias delete" "${DNS_LOG}")"
mv "${NFS_CONFIG_DIR}/shares.json.keep" "${NFS_CONFIG_DIR}/shares.json"; unset -f dns-manager

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
