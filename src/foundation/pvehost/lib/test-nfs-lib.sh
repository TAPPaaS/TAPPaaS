#!/usr/bin/env bash
#
# Unit tests for the pure helpers behind pvehost:nfs (ADR-029) — nfs-lib.sh. No
# node, no guest: share references, the sharenfs renderer, export and mount
# declaration checks (the two-key check), and owner allocation.
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

# ── share references (D2) ─────────────────────────────────────────────
ck "ref: named"                "named tappaas1 media"           "$(nfs_parse_share_ref tappaas1:media)"
ck "ref: literal"              "literal nas.lan /volume1/video" "$(nfs_parse_share_ref nas.lan:/volume1/video)"
ck "ref: literal by IP"        "literal 10.2.0.9 /x"            "$(nfs_parse_share_ref 10.2.0.9:/x)"
nfs_parse_share_ref tappaas1 2>/dev/null;        ck_rc "ref: no colon refused" 1 $?
nfs_parse_share_ref :media 2>/dev/null;          ck_rc "ref: empty host refused" 1 $?
nfs_parse_share_ref tappaas1:Media 2>/dev/null;  ck_rc "ref: bad name refused" 1 $?

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

# ── mounts and the two-key check (D3, D11) ────────────────────────────
cat > "${NFS_CONFIG_DIR}/tappaas1.json" <<'EOF'
{"kind":"machine","management":"managed","nfs":{"exports":[
  {"name":"media","pool":"tankb1","backup":{"enabled":true},"owner":{"uid":64000,"gid":64000},
   "grants":[{"consumer":"jellyfin","access":"rw"},{"consumer":"viewer","access":"ro"}]}]}}
EOF
cat > "${NFS_CONFIG_DIR}/nas1.json" <<'EOF'
{"kind":"machine","management":"unmanaged","nfs":{"exports":[
  {"name":"video","path":"/volume1/video","grants":[{"consumer":"jellyfin","access":"ro"}]}]}}
EOF
cat > "${NFS_CONFIG_DIR}/tappaas2.json" <<'EOF'
{"kind":"machine","management":"managed","nfs":{"exports":[
  {"name":"photos","pool":"tankb1","backup":{"enabled":false},"owner":{"uid":64002,"gid":64002}}]}}
EOF
echo '{"dependsOn":["pvehost:nfs","network:rules"]}' > "${NFS_CONFIG_DIR}/jellyfin.json"
echo '{"dependsOn":["pvehost:nfs"]}' > "${NFS_CONFIG_DIR}/viewer.json"
m() { nfs_check_mount "$1" "$2"; }
m jellyfin '{"path":"/var/lib/jellyfin/media","share":"tappaas1:media","access":"rw"}' >/dev/null; ck_rc "mount: granted rw passes" 0 $?
m viewer '{"path":"/srv/media","share":"tappaas1:media"}' >/dev/null;                    ck_rc "mount: granted ro, default ro passes" 0 $?
out="$(m viewer '{"path":"/srv/media","share":"tappaas1:media","access":"rw"}')";        ck_rc "mount: rw against ro grant refused" 1 $?
has "mount: names the grant" "grants viewer only ro" "${out}"
out="$(m stranger '{"path":"/srv/media","share":"tappaas1:media"}')";                    has "mount: no grant refused, prints the grant to add" '"consumer": "stranger"' "${out}"
out="$(m jellyfin '{"path":"/srv/x","share":"tappaas1:nope"}')";                         has "mount: undeclared export refused, never auto-created" "declares no export 'nope'" "${out}"
out="$(m jellyfin '{"path":"/srv/x","share":"tappaas1:/tankb1/tappaas-nfs/media"}')";     has "mount: path form on a module instance refused" "name its share" "${out}"
out="$(m jellyfin '{"path":"/srv/x","share":"ghost:media"}')";                           has "mount: unknown instance refused" "not a module instance" "${out}"
m jellyfin '{"path":"/srv/v","share":"nas1:video"}' >/dev/null;                          ck_rc "mount: registered server, granted ro passes" 0 $?
m jellyfin '{"path":"/srv/f","share":"files.partner.example:/exports/shared"}' >/dev/null; ck_rc "mount: unmodelled server passes" 0 $?
out="$(m jellyfin '{"path":"/etc","share":"tappaas1:media","access":"rw"}')";             has "mount: /etc refused" "not a directory a share may cover" "${out}"
out="$(m jellyfin '{"path":"relative","share":"tappaas1:media","access":"rw"}')";         has "mount: relative path refused" "must be absolute" "${out}"

# ── the firewall path (D5 layer 2) ────────────────────────────────────
echo '{"zone0":"srvHome","dependsOn":["pvehost:nfs"]}' > "${NFS_CONFIG_DIR}/jelly-srv.json"
echo '{"zone0":"srvHome","dependsOn":["pvehost:nfs","network:rules"]}' > "${NFS_CONFIG_DIR}/jelly-rules.json"
echo '{"zone0":"mgmt","dependsOn":["pvehost:nfs"]}' > "${NFS_CONFIG_DIR}/jelly-mgmt.json"
jq '.zone0 = "mgmt" | .nfs.exports[0].grants += [{"consumer":"jelly-srv","access":"ro"},{"consumer":"jelly-rules","access":"ro"},{"consumer":"jelly-mgmt","access":"ro"}]' \
   "${NFS_CONFIG_DIR}/tappaas1.json" > "${NFS_CONFIG_DIR}/t" && mv "${NFS_CONFIG_DIR}/t" "${NFS_CONFIG_DIR}/tappaas1.json"
out="$(m jelly-srv '{"path":"/m","share":"tappaas1:media"}')"; ck_rc "path: cross-zone without network:rules refused" 1 $?
has "path: says which service derives the rule" "must depend on network:rules" "${out}"
m jelly-rules '{"path":"/m","share":"tappaas1:media"}' >/dev/null; ck_rc "path: cross-zone with network:rules passes" 0 $?
m jelly-mgmt '{"path":"/m","share":"tappaas1:media"}' >/dev/null;  ck_rc "path: same zone needs no rule" 0 $?
out="$(m jelly-srv '{"path":"/f","share":"files.example:/x"}')";   has "path: an unmodelled server needs network:rules too" "must depend on network:rules" "${out}"

# ── owner allocation (D5, Q2) ─────────────────────────────────────────
ck "owner: lowest free uid across the Site" "64001" "$(nfs_next_owner)"
ck "grant lookup" "rw" "$(nfs_grant_for tappaas1 media jellyfin)"
ck "grant lookup: none" "" "$(nfs_grant_for tappaas1 media stranger)"

# ── the guest side (D3, D10) ──────────────────────────────────────────
jq '.address = "tappaas1.mgmt.internal"' "${NFS_CONFIG_DIR}/tappaas1.json" > "${NFS_CONFIG_DIR}/t" && mv "${NFS_CONFIG_DIR}/t" "${NFS_CONFIG_DIR}/tappaas1.json"
jq '.address = "nas1.srv.internal"' "${NFS_CONFIG_DIR}/nas1.json" > "${NFS_CONFIG_DIR}/t" && mv "${NFS_CONFIG_DIR}/t" "${NFS_CONFIG_DIR}/nas1.json"
r1="$(nfs_resolve_mount '{"path":"/var/lib/jellyfin/media","share":"tappaas1:media","access":"rw"}')"
ck "resolve: managed export → node address + dataset mountpoint" \
   "/var/lib/jellyfin/media	tappaas1.mgmt.internal:/tankb1/tappaas-nfs/media	4.2	rw	false	tappaas1" "${r1}"
r2="$(nfs_resolve_mount '{"path":"/srv/v","share":"nas1:video","required":true}')"
ck "resolve: registered server → its address + descriptor path" \
   "/srv/v	nas1.srv.internal:/volume1/video	4.2	ro	true	nas1" "${r2}"
r3="$(nfs_resolve_mount '{"path":"/srv/f","share":"files.example:/exports/shared"}')"
ck "resolve: unmodelled → the literal" "/srv/f	files.example:/exports/shared	4.2	ro	false	-" "${r3}"
ck "options: not required → nofail + automount" "vers=4.2,rw,hard,_netdev,noatime,nofail,x-systemd.automount,x-systemd.mount-timeout=30" "$(nfs_mount_options 4.2 rw false)"
ck "options: required → no nofail" "vers=4.2,ro,hard,_netdev,noatime" "$(nfs_mount_options 4.2 ro true)"
nix="$(nfs_render_nixos "${r1}"$'\n'"${r2}")"
has "nixos: device" 'device = "tappaas1.mgmt.internal:/tankb1/tappaas-nfs/media";' "${nix}"
has "nixos: options list" 'options = \[ "vers=4.2" "rw" "hard"' "${nix}"
has "nixos: nfs support" 'boot.supportedFilesystems = \[ "nfs" \];' "${nix}"
if command -v nix-instantiate >/dev/null 2>&1; then
    printf '%s\n' "${nix}" > "${NFS_CONFIG_DIR}/frag.nix"
    nix-instantiate --parse "${NFS_CONFIG_DIR}/frag.nix" >/dev/null 2>&1; ck_rc "nixos: the fragment parses" 0 $?
fi
fst="$(nfs_render_fstab "${r1}")"
has "fstab: marked block" "BEGIN pvehost:nfs" "${fst}"
has "fstab: line" "tappaas1.mgmt.internal:/tankb1/tappaas-nfs/media /var/lib/jellyfin/media nfs vers=4.2,rw,hard" "${fst}"

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
