#!/usr/bin/env bash
#
# Unit tests for the pure helpers behind pvehost:nfs (ADR-029 v0.8) — nfs-lib.sh and
# nfs-guest.sh. No node, no guest: share references, finding a share's server, the
# sharenfs renderer, export and mount checks (pending, the two-key check, subdir),
# the firewall path, the wan refusal, the client list, owner allocation, and the
# guest rendering. module-manager/test/unit/nfs.test.ts pins the same rules.
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

# ── export declarations (D4, D2a) ─────────────────────────────────────
ok_export='{"name":"media","pool":"tankb1","quota":"4T","backup":{"enabled":true},"grants":[{"consumer":"jellyfin","access":"rw"}]}'
nfs_check_export "${ok_export}" managed >/dev/null; ck_rc "export: a complete managed export passes" 0 $?
out="$(nfs_check_export '{"name":"media","pool":"tankb1"}' managed)"; ck_rc "export: backup.enabled missing refused" 1 $?
has "export: says backup.enabled has no default" "no default" "${out}"
out="$(nfs_check_export '{"name":"media","backup":{"enabled":false}}' managed)"; has "export: pool required on managed" "pool is required" "${out}"
out="$(nfs_check_export '{"name":"media","pool":"tankb1","path":"/x","backup":{"enabled":false}}' managed)"; has "export: path refused on managed" "path is for a registered" "${out}"
out="$(nfs_check_export '{"name":"media","pool":"tankb1","backup":{"enabled":false},"owner":{"uid":1000,"gid":1000}}' managed)"; has "export: owner outside range refused" "owner must be" "${out}"
out="$(nfs_check_export '{"name":"media","pool":"tankb1","backup":{"enabled":false},"properties":{"mountpoint":"/x"}}' managed)"; has "export: unknown property refused" "property mountpoint" "${out}"
out="$(nfs_check_export '{"name":"media","pool":"tankb1","backup":{"enabled":false},"grants":[{"consumer":"a"},{"consumer":"a","access":"rw"}]}' managed)"; has "export: duplicate grant refused" "granted twice" "${out}"
out="$(nfs_check_export '{"name":"media","pool":"tankb1","backup":{"enabled":false},"grants":[{"consumer":"a","access":"admin"}]}' managed)"; has "export: bad access refused" "access admin" "${out}"
out="$(nfs_check_export '{"name":"Media","pool":"tankb1","backup":{"enabled":false}}' managed)"; has "export: bad name refused" "name must match" "${out}"
nfs_check_export '{"name":"video","path":"/volume1/video","version":"4.1","grants":[{"consumer":"jellyfin"}]}' unmanaged >/dev/null; ck_rc "export: a registered server descriptor passes" 0 $?
out="$(nfs_check_export '{"name":"video","path":"/v","pool":"x","backup":{"enabled":true}}' unmanaged)"; has "export: pool refused on unmanaged" "pool is not allowed" "${out}"
has "export: backup refused on unmanaged" "backup is not allowed" "${out}"
out="$(nfs_check_export '{"name":"video"}' unmanaged)"; has "export: path required on unmanaged" "path (absolute) is required" "${out}"
out="$(nfs_check_export '{"name":"video","path":"/v","version":"3"}' unmanaged)"; has "export: v3 without pinned ports refused" "v3Ports" "${out}"
nfs_check_export '{"name":"video","path":"/v","version":"3","v3Ports":{"mountd":892,"nlockmgr":32803,"statd":662}}' unmanaged >/dev/null; ck_rc "export: v3 with pinned ports passes" 0 $?

# ── fixtures: two nodes, a NAS, consumers ─────────────────────────────
cat > "${NFS_CONFIG_DIR}/tappaas1.json" <<'EOF'
{"kind":"machine","management":"managed","zone0":"mgmt","address":"tappaas1.mgmt.internal","nfs":{"exports":[
  {"name":"media","pool":"tankb1","backup":{"enabled":true},"owner":{"uid":64000,"gid":64000},
   "grants":[{"consumer":"jellyfin","access":"rw"},{"consumer":"viewer","access":"ro"},{"consumer":"gone","access":"rw"},{"consumer":"idle","access":"rw"}]}]}}
EOF
cat > "${NFS_CONFIG_DIR}/tappaas2.json" <<'EOF'
{"kind":"machine","management":"managed","zone0":"mgmt","address":"tappaas2.mgmt.internal","nfs":{"exports":[
  {"name":"photos","pool":"tankb1","backup":{"enabled":false},"owner":{"uid":64002,"gid":64002}}]}}
EOF
cat > "${NFS_CONFIG_DIR}/nas1.json" <<'EOF'
{"kind":"machine","management":"unmanaged","zone0":"home","address":"nas1.home.internal","nfs":{"exports":[
  {"name":"video","path":"/volume1/video","version":"4.1","grants":[{"consumer":"jellyfin","access":"ro"}]}]}}
EOF
echo '{"zone0":"srvHome","vmname":"jellyfin","dependsOn":["pvehost:nfs","network:rules"],"config":{"pvehost:nfs":{"mounts":[{"path":"/media","share":"media","subdir":"jellyfin","access":"rw"}]}}}' > "${NFS_CONFIG_DIR}/jellyfin.json"
echo '{"zone0":"srvHome","dependsOn":["pvehost:nfs"]}' > "${NFS_CONFIG_DIR}/viewer.json"
echo '{"zone0":"mgmt","dependsOn":["pvehost:nfs"],"config":{"pvehost:nfs":{"mounts":[]}}}' > "${NFS_CONFIG_DIR}/idle.json"
m() { nfs_check_mount "$1" "$2"; }

# ── finding a share (D2, D2b) ─────────────────────────────────────────
ck "find: a node's share"      "tappaas1" "$(nfs_find_share media)"
ck "find: a NAS's share"       "nas1"     "$(nfs_find_share video)"
nfs_find_share nope >/dev/null 2>&1; ck_rc "find: an undeclared share → rc 1 (pending)" 1 $?
cp "${NFS_CONFIG_DIR}/tappaas2.json" "${NFS_CONFIG_DIR}/dup.json"
nfs_find_share photos >/dev/null 2>&1; ck_rc "find: a share declared twice → rc 2" 2 $?
has "unique: the second server is named" "also declared by dup" "$(nfs_check_unique tappaas2)"
rm -f "${NFS_CONFIG_DIR}/dup.json"
nfs_check_unique tappaas2 >/dev/null; ck_rc "unique: a Site-unique name passes" 0 $?
ck "export path: a node's uniform mountpoint" "/tappaas-nfs/media" "$(nfs_export_path tappaas1 "$(nfs_export tappaas1 media)")"
ck "export path: a NAS's own path"            "/volume1/video"     "$(nfs_export_path nas1 "$(nfs_export nas1 video)")"

# ── mounts: pending, the two-key check, subdir (D3, D11, D15) ─────────
m jellyfin '{"path":"/media","share":"media","subdir":"jellyfin","access":"rw"}' >/dev/null; ck_rc "mount: granted rw passes" 0 $?
out="$(m jellyfin '{"path":"/srv/x","share":"nope"}')";   ck_rc "mount: an undeclared share is pending, not refused" 0 $?
ck "mount: pending prints nothing" "" "${out}"
ck "status: pending"   "pending"           "$(nfs_mount_status '{"share":"nope"}')"
ck "status: available" "available tappaas1" "$(nfs_mount_status '{"share":"media"}')"
ck "status: literal"   "literal"           "$(nfs_mount_status '{"share":"10.2.0.9:/x"}')"
out="$(m viewer '{"path":"/srv/m","share":"media","access":"rw"}')"; ck_rc "mount: rw against an ro grant refused" 1 $?
has "mount: names the grant" "grants viewer only ro" "${out}"
out="$(m stranger '{"path":"/srv/m","share":"media"}')";   ck_rc "mount: an existing share without a grant is an error (v0.8)" 1 $?
has "mount: prints the grant to add" '"consumer": "stranger"' "${out}"
out="$(m jellyfin '{"path":"/srv/x","share":"tappaas1:/tappaas-nfs/media"}')"; has "mount: a literal on a module instance refused" "name its share" "${out}"
out="$(m jellyfin '{"path":"/m","share":"media","subdir":"../etc"}')";  has "subdir: .. refused"      "subdir" "${out}"
out="$(m jellyfin '{"path":"/m","share":"media","subdir":"/abs"}')";    has "subdir: leading / refused" "subdir" "${out}"
m jellyfin '{"path":"/m","share":"media","subdir":"a/b-c.d"}' >/dev/null; ck_rc "subdir: a nested relative path passes" 0 $?
out="$(m jellyfin '{"path":"/m","share":"media","stopUnits":"jellyfin.service"}')"; has "stopUnits: must be a list" "stopUnits" "${out}"
out="$(m jellyfin '{"path":"/etc","share":"media","access":"rw"}')";   has "mount: /etc refused" "not a directory a share may cover" "${out}"
out="$(m jellyfin '{"path":"relative","share":"media","access":"rw"}')"; has "mount: relative path refused" "must be absolute" "${out}"

# ── the firewall path (D5 layer 2) ────────────────────────────────────
out="$(m viewer '{"path":"/m","share":"media"}')";  ck_rc "path: cross-zone without network:rules refused" 1 $?
has "path: says which service derives the rule" "must depend on network:rules" "${out}"
m idle '{"path":"/m","share":"media"}' >/dev/null; ck_rc "path: same zone needs no rule" 0 $?
m viewer '{"path":"/m","share":"nope"}' >/dev/null; ck_rc "path: a pending mount needs no rule" 0 $?
out="$(m viewer '{"path":"/f","share":"files.example:/x"}')"; has "path: an unmodelled server needs network:rules" "must depend on network:rules" "${out}"

# ── the wan refusal (D2a) ─────────────────────────────────────────────
out="$(m jellyfin '{"path":"/f","share":"8.8.8.8:/x"}')";   has "wan: a public literal IP refused" "public address" "${out}"
m jellyfin '{"path":"/f","share":"192.168.1.20:/x"}' >/dev/null; ck_rc "wan: a private literal IP passes" 0 $?
echo '{"zone0":"wan","management":"unmanaged","nfs":{"exports":[{"name":"outside","path":"/x","grants":[{"consumer":"jellyfin"}]}]}}' > "${NFS_CONFIG_DIR}/edge.json"
out="$(m jellyfin '{"path":"/f","share":"outside"}')";      has "wan: a share on a wan-zone server refused" "wan zone" "${out}"
rm -f "${NFS_CONFIG_DIR}/edge.json"
nfs_is_public_ipv4 100.64.1.1; ck_rc "wan: CGNAT (the overlay) is not public" 1 $?

# ── the client list follows the consumers (D16) ───────────────────────
nfs_consumer_address() { case "$1" in jellyfin) echo 10.2.0.116 ;; viewer) echo 10.2.0.117 ;; idle) echo 10.0.0.50 ;; esac; }
. "${SCRIPT_DIR}/nfs-node.sh" 2>/dev/null || true
nfs_consumer_address() { case "$1" in jellyfin) echo 10.2.0.116 ;; viewer) echo 10.2.0.117 ;; idle) echo 10.0.0.50 ;; esac; }
e="$(nfs_export tappaas1 media)"
ck "clients: only granted, deployed, mounting consumers" "jellyfin rw 10.2.0.116" "$(nfs_node_clients "${e}")"
ck "clients: a deleted consumer (no config) contributes nothing" "" "$(nfs_node_clients "${e}" | grep gone)"
ck "clients: a granted consumer that does not mount contributes nothing" "" "$(nfs_node_clients "${e}" | grep idle)"
ck "clients: the consumer being deleted is left out" "" "$(NFS_EXCLUDE_CONSUMERS=jellyfin nfs_node_clients "${e}")"
has "share: the expected sharenfs" "rw=@10.2.0.116/32" "$(nfs_node_expected_share "${e}")"
ck "share: nobody mounting → off" "off" "$(NFS_EXCLUDE_CONSUMERS=jellyfin nfs_node_expected_share "${e}")"

# ── owner allocation (D5, Q2) ─────────────────────────────────────────
ck "owner: lowest free uid across the Site" "64001" "$(nfs_next_owner)"
ck "grant lookup" "rw" "$(nfs_grant_for tappaas1 media jellyfin)"
ck "grant lookup: none" "" "$(nfs_grant_for tappaas1 media stranger)"

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
has "fstab: marked block" "BEGIN pvehost:nfs" "${fst}"
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
echo '{"rebootOk":true}' > "${NFS_CONFIG_DIR}/ok.json"; echo '{}' > "${NFS_CONFIG_DIR}/no.json"
nfs_consent ok; ck_rc "consent: rebootOk" 0 $?
nfs_consent no; ck_rc "consent: none without rebootOk or --allow-disruption" 1 $?
TAPPAAS_ALLOW_DISRUPTION=1 nfs_consent no; ck_rc "consent: --allow-disruption" 0 $?

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
