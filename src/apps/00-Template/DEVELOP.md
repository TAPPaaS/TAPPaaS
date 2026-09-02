# Develop a Module — quick start

You have an application; you want it on TAPPaaS. What you build is a **module**: your app
plus a small json contract and a few lifecycle scripts, running in its own VM. In return
the platform gives you — without further work — VM provisioning, network zones and
firewall rules, a public URL behind the reverse proxy, scheduled updates, backup, and
health monitoring.

## Before you start

- **A TAPPaaS to develop against.** Ideally a test instance; a sufficiently stand-alone
  module can be developed on a production system — its own VM and, if you want, a
  dedicated zone keep experiments away from production. See
  [Git & repository topology](../../foundation/tappaas-cicd/DESIGN-GIT.md) for the
  dev-instance setup.
- **Decide where your module will be maintained** — the open-source TAPPaaS repo (via
  pull request), a community repository, or a private one. This shapes your git
  workflow: [Git & repository topology](../../foundation/tappaas-cicd/DESIGN-GIT.md).
- **Know how your app ships.** The default module VM is **NixOS** (configured
  declaratively in a `.nix` file); Debian cloud-images, ISO installs and even Windows
  are supported when your app needs them.

## Quick start — template to running VM

Work on the CICD mothership (`tappaas-cicd`), in its checkout of the source repo:

```bash
cd ~/TAPPaaS/src/apps
cp -r 00-Template myapp && cd myapp
mv README-template.md README.md
mv template.json myapp.json        # + template.nix -> myapp.nix, or delete it
```

Edit `myapp.json` — at minimum a free `vmid`, sizing (`cores`, `memory`, `diskSize`)
and the zone (`zone0`, typically `srv`). The template ships `tier: "app"`; leave it
unless this is a critical platform module, in which case set `tier: "foundation"`
(mgmt-only, single-instance, `--force` to delete — see [module-fields.json](../../foundation/schemas/module-fields.json)). Then:

```bash
module-manager module add myapp
```

The platform creates the VM, wires its network, and runs your `install.sh`.
**[README.md](README.md) documents every file you just copied** — the json fields,
image/OS choices, providing services, debugging, naming.

## Make it run your application

- **`install.sh`** — called once with the module name; puts your software in the VM.
  For NixOS modules the default `install.sh` rebuilds the VM from `myapp.nix` — porting
  your app is mostly writing that nix configuration.
- **`update.sh`** — called on the platform's update schedule; keeps the app patched
  without operator attention.
- **`test.sh`** — your regression check; the same tests gate updates.

## Iterate and debug

```bash
module-manager module test myapp        # run your test.sh
module-manager module reconcile myapp   # re-apply the current config to the VM
module-manager module modify myapp      # release update: snapshot + test + merge
module-manager module delete myapp      # --archive by default
```

Can't SSH in? [README.md](README.md) shows how to take a VM console screenshot through
Proxmox — works on any OS, including mid-install.

## Going deeper

The module details — every file, field and convention — are in **[README.md](README.md)**.
The contract and machinery behind it:

- [Schemas](../../foundation/schemas/README.md) — every `module.json` field, defined once.
- [Network zones](../../foundation/tappaas-cicd/manager/network-manager/ZONES.md) — where
  your module runs; a `network:proxy` dependency + `proxyPort` gives it a public
  TLS URL.
- [Backup design](../../foundation/backup/DESIGN.md) — data-bearing modules opt in with
  `backup:vm`.
- [Module Manager](../../foundation/tappaas-cicd/manager/module-manager/README.md) — the
  full verb and script reference.
- [CICD mothership design](../../foundation/tappaas-cicd/DESIGN.md) and the
  [module dependency graph](../../module-dependencies.md) — what the automation does
  with your json (optional reading).

## Ship it

A finished module is a **good platform citizen**: it updates unattended, its tests pass,
its data is backed up, it reports into health, and it carries its own `README.md` (what
it is) and `INSTALL.md` (what automation can't do for you).

Then contribute it — via pull request to
[TAPPaaS](https://codeberg.org/TAPPaaS/TAPPaaS), a community repository, or keep it
private ([where modules live](../../foundation/tappaas-cicd/DESIGN-GIT.md)). Good first
step: open an issue describing the app — someone may already be packaging it. See the
[contribution guide](https://tappaas.org/community/contributing/).
