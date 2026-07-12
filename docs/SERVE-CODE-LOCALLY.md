# Serving the TAPPaaS repo locally for installs

The first-node installer (`src/foundation/install.sh` and everything it
chains) downloads each script individually from
`codeberg.org/…/raw/branch/…`. Repeated install runs — e.g. wipe-and-reinstall
testing — can trip the forge's per-IP rate limiting and start failing with
`curl: (22) ... error: 429`. Serving the repo from a machine on your LAN
avoids the rate limit entirely, is faster, and lets you install a branch
that only exists locally.

The installers build every URL as `${REPO}${BRANCH}/<path-in-repo>`, so any
plain HTTP server exposing a directory *named after the branch* works.

## 1. Get the branch you want to serve

Fresh clone of one working branch (shallow, fast):

```bash
git clone -b ADR007 --single-branch https://codeberg.org/TAPPaaS/TAPPaaS.git ~/src/TAPPaaS
```

(Already have a clone? `git -C ~/src/TAPPaaS fetch origin && git -C ~/src/TAPPaaS checkout ADR007` is enough.)

## 2. Export the branch into a directory named after it, and serve it

`git archive` exports exactly the committed tree — no working-tree edits, no
`.git`. The `mkdir` + `tar -x -C` form works on both macOS (bsdtar) and Linux:

```bash
mkdir -p /tmp/tappaas-serve/ADR007
git -C ~/src/TAPPaaS archive ADR007 | tar -x -C /tmp/tappaas-serve/ADR007
cd /tmp/tappaas-serve && python3 -m http.server 8000
```

Leave this terminal running for the duration of the install.

Find the serving machine's LAN IP: `ipconfig getifaddr en0` (macOS) or
`hostname -I` (Linux).

## 3. Point the installer at it

On the target Proxmox node, fetch the entry script from your server and run
it with your server as `REPO`:

```bash
curl -O http://<server-ip>:8000/ADR007/src/foundation/install.sh
chmod +x install.sh
./install.sh "http://<server-ip>:8000/" ADR007 --name <orgname> [--domain <d>] ...
```

Sanity check first (must print `HTTP/1.0 200 OK`):

```bash
curl -sI http://<server-ip>:8000/ADR007/src/foundation/cluster/install.sh | head -1
```

## Serving the VM images locally too

Two large disk images are fetched from GitHub *Releases* during install (a
different endpoint from the raw CDN, with laxer rate limits — but local is
still faster and works offline): the OPNsense firewall image and the NixOS
template image. `Create-TAPPaaS-VM.sh` builds the download URL from each
module JSON's `imageLocation` + `image` fields, so pointing them at the
local server needs no script change.

Download the assets once into the serve dir:

```bash
mkdir -p /tmp/tappaas-serve/images/{opnsense-firewall-v1.1,nixos-template-v1.2}
curl -fSLo /tmp/tappaas-serve/images/opnsense-firewall-v1.1/tappaas-firewall.qcow2.zst \
  https://github.com/TAPPaaS/TAPPaaS/releases/download/opnsense-firewall-v1.1/tappaas-firewall.qcow2.zst
curl -fSLo /tmp/tappaas-serve/images/nixos-template-v1.2/tappaas-nixos.qcow2.zst \
  https://github.com/TAPPaaS/TAPPaaS/releases/download/nixos-template-v1.2/tappaas-nixos.qcow2.zst
```

Then rewrite `imageLocation` in the **exported serve tree** (never the git
checkout — the snapshot is disposable, and a LAN IP must not be committed).
Both variants detect the serving machine's LAN IP themselves — pure
copy-paste, no editing:

macOS:

```bash
sed -i '' "s#https://github.com/TAPPaaS/TAPPaaS/releases/download/#http://$(ipconfig getifaddr en0):8000/images/#" \
  /tmp/tappaas-serve/ADR007/src/foundation/network/network.json \
  /tmp/tappaas-serve/ADR007/src/foundation/templates/tappaas-nixos.json
```

Debian/Linux:

```bash
sed -i "s#https://github.com/TAPPaaS/TAPPaaS/releases/download/#http://$(hostname -I | awk '{print $1}'):8000/images/#" \
  /tmp/tappaas-serve/ADR007/src/foundation/network/network.json \
  /tmp/tappaas-serve/ADR007/src/foundation/templates/tappaas-nixos.json
```

(macOS: if your Mac is on Wi-Fi and `en0` isn't it, check `ipconfig getifaddr en1`.
Verify the result with `grep imageLocation /tmp/tappaas-serve/ADR007/src/foundation/network/network.json`.)

Re-apply the `sed` after every re-export (step 2 overwrites it). Third-party
images (e.g. `apps/hass`) use the same `imageLocation` mechanism and can be
mirrored the same way when needed.

## Caveats

- **Re-export after every new commit** — `git archive` is a snapshot; repeat
  step 2 (the `mkdir`/`tar` lines) when the branch moves.
- **Committed state only.** Uncommitted working-tree changes are not in the
  archive. That is a feature: you install exactly what a git checkout would
  give you.
- **Gateway cutover.** Install step [3/5] swaps the node's default route to
  the new firewall. If the node then can't reach your serving machine, later
  fetches fail loudly — re-run from that point once routing is up, or serve
  from a machine both networks can reach.
- The cloned repo the installer sets up on the tappaas-cicd VM still points
  at the real GitHub remote (from `site.json .repositories`) — the local
  server only feeds the *bootstrap* downloads.
