# network — Installation

Primary audience: TAPPaaS admin.

The network module is **not** installed with `install-module.sh` — the firewall VM is
stood up **during foundation bootstrap, before tappaas-cicd exists**, as step [2/5] of
`foundation/install.sh` (see the repo-root [INSTALL.md](../../../INSTALL.md) §2.1). The
zone/proxy/rules layer is then configured by the tappaas-cicd install.

## Prerequisites

1. The node's `lan`/`wan` bridges exist (`cluster` module network phase) — the OPNsense
   VM attaches `net0→lan`, `net1→wan`.
2. Internet reachable on the WAN side (the prebuilt image is downloaded from a GitHub
   Release).
3. A strong root password for the firewall (prompted, or generated for you).

> To deviate from the defaults in `./network.json` (target storage, sizing, image
> release), copy the json to `/home/tappaas/config` and edit it before installing. The
> management subnet and LAN conventions live in `firewall-config.xml.template`.

## Install

Normally: nothing to run by hand — the first-node bootstrap does it all:

    ./install.sh "$REPO" "$BRANCH" --name <orgname> --domain "yourdomain.com"
    # step [2/5] runs network/config-firewall.sh; step [5/5] installs tappaas-cicd,
    # whose install deploys config/network.json and runs update-module.sh network

Standalone (re)run on the first node, after the bridges exist:

    /root/tappaas/config-firewall.sh [--repo URL] [--branch NAME] [--root-pw PASS]
                                     [--non-interactive]

`config-firewall.sh` downloads and boots the **prebuilt OPNsense image** (no GUI, no
installer, issue #231): it generates a unique API key + root password, renders
`firewall-config.xml.template`, pushes the unique config over the image's one-time
bootstrap SSH, reboots into it, verifies `10.0.0.1`, and writes the API credentials to
`~/.opnsense-credentials.txt` for tappaas-cicd.

If the firewall is unreachable when tappaas-cicd installs, the module is deployed with
`firewallType: "NONE"` and you manage your own firewall manually.

## Post-install

- Set up TLS certificates: run `acme-setup.sh` on the mothership (repo-root
  [INSTALL.md](../../../INSTALL.md) §2.3). Skippable for internal-only use.
- Register physical switches (`setup-switches.sh`) and WiFi SSIDs/passphrases
  (`setup-wlan-secrets.sh`) if your site has managed switches or APs — see
  [scripts/README.md](scripts/README.md).
- Keep the firewall root password and `~/.opnsense-credentials.txt` safe; the API key is
  unique per deploy.

## Verification

From the mothership:

    test-module.sh network            # fast (seconds–minutes)
    test-module.sh network --deep     # 5–10 min; provisions real test VMs, then cleans up

Output is mirrored to `~/logs/firewall-test-<timestamp>.log`. Exit 2 means a Basic
DNS/connectivity/OPNsense check failed (firewall unreachable — `update-module.sh` rolls
back on it). Full test inventory: [TEST.md](./TEST.md).

| Check | Expected |
|-------|----------|
| `ping 10.0.0.1` from a node | Replies (firewall LAN up) |
| `https://10.0.0.1` | OPNsense GUI login |
| Internal + external DNS from the mothership | `<vm>.<zone>.internal` and public names resolve |
| `zone-manager --summary` | Parses and connects to the OPNsense API |
| `caddy-manager list` | Lists the registered reverse-proxy entries |

## Troubleshooting

**Firewall LAN not at `10.0.0.1` after bootstrap**
The unique-config push failed. Re-run `config-firewall.sh` — it is safe to re-run and
verifies reachability at the end.

**`test.sh` exits 2 / update rolled back**
A Basic check (DNS, ping, OPNsense API/SSH) failed — the firewall is unreachable. Fix
connectivity first; later test tiers cannot run without it.

**Caddy API calls 404 during install**
The `os-caddy` plugin is missing — it is installed by `setup-caddy.sh`, which the
tappaas-cicd install runs *before* updating the network module. Run
`~/TAPPaaS/src/foundation/tappaas-cicd/scripts/setup-caddy.sh` and re-run
`update-module.sh network`.

**DNS breaks right after a firewall update**
Update order matters: OPNsense software update + reboot happen **before** zone-manager
re-applies configuration (which regenerates Unbound). See
[DESIGN.md](./DESIGN.md#troubleshooting-unbound--dnsbl) ("Troubleshooting:
Unbound / DNSBL") for background and `update.sh` for the exact sequence.

**`firewallType=NONE` deployments**
All OPNsense operations are skipped; `rules-manager` prints rules in human-readable form
for manual entry into your firewall (exit 0).
