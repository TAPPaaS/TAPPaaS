#!/usr/bin/env bash
#
# capture.sh — refresh the console's fixtures from a live system.
#
#   ui/test/fixtures/capture.sh [--host <ssh-alias>] [--out <dir>]
#
# Runs read verbs only, in one ssh session (default cicd-hrossen), and unpacks
# what they said into this directory (or --out): the files the fakes name
# (modules.json, topology.json, ...), reads/<slug>.out for every other verb,
# cmdb/ for the CMDB and config/ for the records the console reads directly.
# redact.py runs over it first, in a temporary directory: the repository is
# public, and a capture that does not come out clean is not kept. A verb that
# fails leaves its output and reads/<slug>.rc; the summary names them. It changes
# nothing on the system but a scratch directory under /tmp, which it removes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="cicd-hrossen"
OUT="${HERE}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) echo "usage: capture.sh [--host <ssh-alias>] [--out <dir>]" >&2; exit 2 ;;
    esac
done

# The Mac's agent: a shell started by an app does not inherit it.
if [[ -z "${SSH_AUTH_SOCK:-}" ]] && command -v launchctl >/dev/null 2>&1; then
    SSH_AUTH_SOCK="$(launchctl getenv SSH_AUTH_SOCK)"
    export SSH_AUTH_SOCK
fi

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT INT TERM

ssh -o ConnectTimeout=10 "${HOST}" bash -s > "${TMP}/capture.tgz" <<'REMOTE'
set -uo pipefail
W="$(mktemp -d /tmp/console-capture.XXXXXX)"
trap 'rm -rf -- "${W}"' EXIT
mkdir -p "${W}/reads" "${W}/cmdb/show" "${W}/cmdb/history" "${W}/config/environments" "${W}/config/identities/organizations" "${W}/config/identities/users"
CONFIG="${HOME}/config"

slug() { printf '%s' "$*" | sed -E 's/[^A-Za-z0-9._]+/-/g; s/^-+//; s/-+$//'; }

# save <file> <bin> <args...>: a verb's stdout under the name the fakes know.
save() {
    local f="$1"; shift
    "$@" > "${W}/${f}" 2>> "${W}/capture.log"
    local rc=$?
    [[ "${rc}" -eq 0 ]] || echo "${rc}" > "${W}/${f}.rc"
    echo "rc=${rc} $*" >> "${W}/capture.log"
}
# read_ <bin> <args...>: any other verb, reads/<slug>.out, the slug the runner derives.
read_() { save "reads/$(slug "$@").out" "$@"; }

jqnames() { python3 -c 'import json,sys
d=json.load(sys.stdin)
d=d.get("modules",d) if isinstance(d,dict) else d
print("\n".join(x if isinstance(x,str) else x["name"] for x in d))'; }

# ── the files the fakes name ──
save validate.json          health-manager validate --json
save guests.json            health-manager guests --json
save modules.json           module-manager list --json
save backup.json            backup-manager list --json
save backup-runs.json       backup-manager restore list-all --json
save topology.json          network-manager topology --json --no-health
save storage-inventory.json storage-manager inventory --json
save environments.json      environment-manager list --json
save aps.json               ap-manager list --json
save ssids.json             ap-manager ssid list --json
journalctl -u update-tappaas.service --since -7d -o short-iso --no-pager 2>> "${W}/capture.log" | tail -n 3000 > "${W}/sweep-journal.txt"

# ── every other read the console makes ──
read_ health-manager roots --json
read_ backup-manager key status --json
read_ backup-manager peers --json
read_ site-manager site show --json
read_ git -C /home/tappaas/TAPPaaS describe --tags --long --match 'v[0-9]*'
read_ site-manager node list --json
read_ site-manager repository list --json
read_ site-manager node media --json
read_ asset-manager faceplates list --json
read_ network-manager wgvpn list
read_ node-provisioner status
read_ ipv6-manager wan --json

# What a job may run: each manager's manifest, as the console loads them.
python3 - "${CONFIG}/control-plane.json" <<'PY' > "${W}/managers.txt"
import json,sys
d=json.load(open(sys.argv[1]))
for c in d.get("components",[]):
    if c.get("kind")=="manager" and c.get("manifest")=="help-json": print(c["name"])
PY
while read -r m; do read_ "${m}" --help --json; done < "${W}/managers.txt"
rm -f "${W}/managers.txt"

# One read per object, as a page asks.
for k in org group user role; do
    read_ identity-manager "${k}" list --json
    read_ identity-manager "${k}" list --declared --json
    identity-manager "${k}" list --json 2>/dev/null | jqnames | while read -r n; do
        case "${n}" in ""|-*) ;; *) read_ identity-manager "${k}" show "${n}" --json ;; esac
    done
done
environment-manager list --json 2>/dev/null | jqnames | while read -r e; do read_ environment-manager show "${e}" --json; done
module-manager list --json 2>/dev/null | jqnames > "${W}/mods.txt"
while read -r m; do
    read_ module-manager show "${m}" --json
    read_ module-manager resolve "${m}" --json
    read_ module-manager fields "${m}" --json
    read_ backup-manager show "${m}" --json
    read_ backup-manager coverage "${m}" --json
done < "${W}/mods.txt"
rm -f "${W}/mods.txt"
site-manager node list --json 2>/dev/null | jqnames | while read -r n; do
    read_ site-manager node network show "${n}" --json
    read_ site-manager node usb "${n}" --json
done

# ── the CMDB ──
save cmdb/objects.json   cmdb query --all --json
save cmdb/relations.json cmdb relations --json
save cmdb/classes.json   cmdb class list --json
save cmdb/sweep.json     cmdb sweep --last --json
# Whole records for what a page opens; the rest the fixture CMDB derives from
# objects.json and relations.json. A history keeps its latest rows: raw, it is 22 MB.
python3 - "${W}/cmdb" <<'PY'
import json, subprocess, sys
d = sys.argv[1]
DETAIL = {"node", "vm", "lxc", "machine", "server", "disk", "storage-pool", "device", "network-device", "other-device", "passive-device", "site", "location", "room"}
KEEP = 20
for o in json.load(open(f"{d}/objects.json")):
    if o["class"] not in DETAIL:
        continue
    i = o["id"]
    with open(f"{d}/show/{i}.json", "w") as f:
        subprocess.run(["cmdb", "show", i, "--json"], stdout=f, stderr=subprocess.DEVNULL)
    r = subprocess.run(["cmdb", "history", i, "--json"], capture_output=True, text=True)
    if r.returncode == 0:
        h = json.loads(r.stdout)
        for k in ("attributes", "relations", "changes"):
            h[k] = h.get(k, [])[-KEEP:]
        json.dump(h, open(f"{d}/history/{i}.json", "w"), indent=1)
PY

# ── the records the console reads directly: named, never the whole directory ──
cd "${CONFIG}" || exit 1
for f in site.json zones.json identity.json control-plane.json positions.json last-update-result.json \
         update-tappaas.failures switch-configuration-actual.json network.json storage.json module-fields.json \
         wan-address.json; do
    [[ -f "${f}" ]] && cp "${f}" "${W}/config/"
done
[[ -f /var/lib/tappaas/wan-address.json ]] && cp /var/lib/tappaas/wan-address.json "${W}/config/"
cp environments/*.json "${W}/config/environments/" 2>/dev/null
cp identities/organizations/*.json "${W}/config/identities/organizations/" 2>/dev/null
cp identities/users/*.json "${W}/config/identities/users/" 2>/dev/null
# A module's own record: its config, not what it was given to run with.
module-manager list --json 2>/dev/null | jqnames | while read -r m; do [[ -f "${m}.json" ]] && cp "${m}.json" "${W}/config/"; done

{ date -u +%FT%TZ; hostname; git -C "${HOME}/TAPPaaS" rev-parse --short HEAD; } > "${W}/CAPTURED"
tar -C "${W}" -czf - .
REMOTE
rc=$?
if [[ "${rc}" -ne 0 ]]; then
    echo "capture: ssh ${HOST} failed (rc ${rc}); ${OUT} is unchanged" >&2
    exit 1
fi

mkdir "${TMP}/new"
tar -C "${TMP}/new" -xzf "${TMP}/capture.tgz"
mv "${TMP}/new/capture.log" "${TMP}/capture.log"
if ! python3 "${HERE}/redact.py" "${TMP}/new"; then
    echo "capture: redaction failed; ${OUT} is unchanged" >&2
    exit 1
fi

# Replaced as a set: an object gone from the site must not linger here. The
# hand-kept overlay over the CMDB stays (README: cmdb/overlay.synthetic.json).
[[ -f "${OUT}/cmdb/overlay.synthetic.json" ]] && cp "${OUT}/cmdb/overlay.synthetic.json" "${TMP}/overlay.synthetic.json"
rm -rf -- "${OUT}/reads" "${OUT}/cmdb" "${OUT}/config"
cp -R "${TMP}/new/." "${OUT}/"
[[ -f "${TMP}/overlay.synthetic.json" ]] && cp "${TMP}/overlay.synthetic.json" "${OUT}/cmdb/overlay.synthetic.json"
echo "captured into ${OUT}: $(tr '\n' ' ' < "${OUT}/CAPTURED")"
grep -E '^rc=[^0]' "${TMP}/capture.log" || echo "every verb answered"
