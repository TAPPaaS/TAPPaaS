# TAPPaaS Managers

This directory holds the TAPPaaS **managers**. A manager is one of the two kinds
of cluster-control component in TAPPaaS (the other is a *controller*).

## What a manager is

A **manager owns configuration state.** It does CRUD + validation on the JSON
config files (and their schemas) for one domain — people, the site, environments,
modules, the network, cluster health — and it may orchestrate one or more
**controllers** to push that desired configuration onto live infrastructure.
Every manager ships a `validate.sh` that checks its config for schema conformance
and reference integrity.

A **controller**, by contrast, owns *runtime / device state*: it talks to a live
service or device (OPNsense, Authentik, a switch, Proxmox) and reconciles the
real world toward the desired config a manager hands it. Controllers live under
the sibling `controller/` directory and do **not** ship `validate.sh`.

The short version:

| | Manager | Controller |
|---|---------|------------|
| Owns | configuration state (JSON files + schemas) | runtime / device state |
| Does | CRUD + validate config; may orchestrate controllers | reconcile a live service/device toward desired state |
| Ships `validate.sh` | yes | no |

## The verb contract

The TAPPaaS "mothership" (the `tappaas-cicd` VM) drives every component
generically through a fixed, small set of **verb scripts**. Each manager is a
subdirectory here and provides these executables in its own root:

| Verb | Purpose |
|------|---------|
| `install.sh` | One-time setup: build any compiled artifact and link the component's CLI(s) onto `PATH` (`~/bin`). Idempotent. |
| `update.sh`  | Re-build (for compiled components) and re-link; run any on-disk state migration the new version needs. Idempotent. |
| `test.sh`    | Self-contained tests. Fast/non-disruptive by default; `TAPPAAS_TEST_DEEP=1` adds live/heavy tiers. Exits non-zero on failure. |
| `validate.sh`| (managers only) Schema + reference validation of this domain's config. |

All four verbs are **idempotent** — safe to re-run any number of times.

## How the dispatcher runs them

A parent dispatcher at `manager/{install,update,test}.sh` runs each child
manager's matching verb. It iterates the subdirectories, **skips `TEMPLATE/`**,
runs the child's executable verb script if present, and continues past a failing
child (returning the worst exit code so a failure is never hidden). There is no
shared runner — each manager's verb script is fully self-contained. The
`tappaas-cicd` module calls these parent dispatchers as part of its own
install/update/test, so adding a new manager subdirectory makes it part of the
system automatically.

## The managers

| Manager | Owns / does |
|---------|-------------|
| [`people-manager`](people-manager/) | The People domain: Organizations, Groups, Users, and Roles. CRUD/read on `config/people/`, bootstrap of a minimal org, and a reconcile/`sync` engine that drives the identity (Authentik) controller. |
| [`site-manager`](site-manager/) | The Site: site-wide identity, location, hardware (Proxmox nodes + storage pools), backup, update schedule, repositories. Owns `config/site.json` and migrates the legacy `configuration.json` into it. |
| [`environment-manager`](environment-manager/) | The Environment taxonomy: per-tenant deployment contexts (public domain(s), DNS mode, network-zone reference, data residency, backup, legal). Owns `config/environments/*.json` and bootstraps the always-required `mgmt` + default environments. |
| [`module-manager`](module-manager/) | The module lifecycle: install / update / delete / test / snapshot of TAPPaaS modules, with tier/source classification lint and environment-aware deployment. Owns the per-module JSON in `config/`. |
| [`network-manager`](network-manager/) | The network front door: owns `zones.json` (CRUD + VLAN allocation) and reconciles four infrastructure planes (OPNsense, Proxmox, switch, access points) by orchestrating their controllers. |
| [`health-manager`](health-manager/) | Cluster / VM / disk / OS health and maintenance utilities: inspect the cluster, diff a VM against its config, grow disks over a threshold, update a VM's OS. Operational/read-mostly; ships no `validate.sh`. |

`TEMPLATE/` is the scaffold skeleton, not a manager — the dispatcher skips it.
See [`TEMPLATE/README.md`](TEMPLATE/README.md) for the canonical rules on building
a new manager or controller.
