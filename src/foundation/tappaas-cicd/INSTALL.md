# tappaas-cicd — Installation

Primary audience: TAPPaaS admin.

The mothership is **not** installed with `install-module.sh` (it is the VM that
*provides* that tooling). It is built as step [5/5] of the first-node foundation
bootstrap (see the repo-root [INSTALL.md](../../../INSTALL.md) §2.1).

## Prerequisites

1. First-node bootstrap steps [1/5]–[4/5] complete: cluster node up, firewall at
   `10.0.0.1`, gateway cutover done, sanity check green.
2. The prebuilt NixOS template imported (VM 8080 — done by the same step [5/5]).
3. Your public domain name at hand (`--domain`) — the Caddy reverse proxy is configured
   for `<service>.<domain>`.

> To deviate from the defaults in `./tappaas-cicd.json` (target node, storage, sizing,
> replication schedule), copy the json to `/home/tappaas/config` and edit it before
> installing.

## Install

Normally: nothing to run by hand — `foundation/install.sh` step [5/5] runs
`cluster/install-platform.sh`, which (Phase B) clones VM 130 from the template and
drives the in-VM install end-to-end over SSH:

1. `bootstrap.sh <repo> <branch>` — clones the TAPPaaS repo, generates
   `hardware-configuration.nix`, `nixos-rebuild switch --flake .#tappaas-cicd`,
   creates the tappaas SSH keypair. Then the VM is rebooted.
2. `install.sh [--name N] [--branch NAME] [--domain DOMAIN]` — installs the cicd's SSH
   key on every node, links the toolbox into `~/bin`, writes `site.json`
   (`create-site.sh`), transforms `zones.json` (`network-manager init`), creates the
   `mgmt` + `<name>` environments, deploys the cluster/templates/network/tappaas-cicd
   module configs, runs their updates, stages the PXE netboot assets, installs Caddy on
   the firewall (`setup-caddy.sh`) and sets up the admin-vpn OPNsense termination.

To run those two scripts by hand inside the VM instead, pass `--manual-cicd` to
`install-platform.sh`. Re-running `install.sh` is supported for resuming a partial
install — it preserves operator-set fields in `site.json` and never overwrites a
customised `zones.json`. Completion is marked by `~/config/.tappaas-cicd-installed`.

## Post-install

1. Set up TLS certificates: `ssh tappaas@tappaas-cicd` then `acme-setup.sh` (interactive
   DNS-01 wildcard; repo-root [INSTALL.md](../../../INSTALL.md) §2.3). Optional for
   internal-only use.
2. Install the rest of the foundation (backup → identity → logging) and bootstrap your
   organisation/user: `rest-of-foundation.sh` (idempotent).
3. Optional: enrol your laptop in the admin VPN — `satellite-manager admin add-peer`
   (the OPNsense termination is already up); see [ADMIN-VPN.md](./ADMIN-VPN.md).

If the firewall was unreachable at install time the platform was configured with
`firewallType: "NONE"` — reverse proxy and firewall rules then need manual handling.

## Verification

    test-module.sh tappaas-cicd           # fast (~seconds)
    test-module.sh tappaas-cicd --deep    # minutes; creates real VMs, full component suites

| Check | Expected |
|-------|----------|
| `ssh tappaas@tappaas-cicd` | Login works (also via `10.0.0.x` address) |
| Fast test run | Toolbox scripts present, `site.json` validates, SSH to nodes, `update-tappaas.timer` active |
| `systemctl status update-tappaas.timer` on the VM | active (waiting) |
| `install-module.sh --help` | Toolbox on `PATH` |
| `~/config/.tappaas-cicd-installed` | Exists (install ran to completion) |

Full test inventory: [TEST.md](./TEST.md).

## Troubleshooting

**`nixos-rebuild` fails during bootstrap**
The full build log is in `/tmp/tappaas-bootstrap.log` (its tail is printed on failure).
`bootstrap.sh` is idempotent — fix and re-run; it reuses the existing checkout and keys.

**`error: getting status of hardware-configuration.nix`**
The prebuilt image ships without `/etc/nixos/hardware-configuration.nix`; `bootstrap.sh`
generates it. If missing, run
`sudo nixos-generate-config --show-hardware-config | sudo tee /etc/nixos/hardware-configuration.nix`.

**Install stopped halfway**
Re-run `install.sh` — `create-site.sh --force` preserves operator-set fields, zone/env
init is guarded on the environment file, and `install-platform.sh` keys its skip off
`~/config/.tappaas-cicd-installed` (written only at the very end).

**Caddy API calls 404 while installing the network module**
`setup-caddy.sh` must run first (it installs the `os-caddy` plugin); the install
sequence does this, but on a re-run you can invoke it manually then
`update-module.sh network`.

**`node add --pxe` says netboot assets missing**
The install stages them non-fatally; re-stage with `prepare-netboot.sh` (after a PVE
version upgrade: `prepare-netboot.sh --force`).

**Firewall was down at install time**
The network module was deployed with `firewallType: "NONE"` and Caddy/admin-vpn setup
was skipped. Once the firewall is reachable, re-run `install.sh` (or `setup-caddy.sh` +
`update-module.sh network` + `satellite-manager admin setup`).
