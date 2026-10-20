# TAPPaaS Managers

This directory holds the TAPPaaS **managers**. A manager is one of the two kinds
of cluster-control component in TAPPaaS (the other is a *controller*).

**Listed in [`../components.json`](../components.json).** Every controller and manager here has an
entry there: it is the one list the site's registry (`config/control-plane.json`) is written from,
and the self-check and the console read the registry, not this directory. A new component without
an entry fails `scripts/test/test-control-plane-registry.sh`. Modules contribute controllers and
managers of their own the same way (ADR-035).

## What a manager is

A **manager owns configuration state.** It does CRUD + validation on the JSON
config files (and their schemas) for one domain — people, the site, environments,
modules, the network, cluster health — and it may orchestrate one or more
**controllers** to push that desired configuration onto live infrastructure.
Every manager exposes a **`validate` operation** that checks its config for
schema conformance and reference integrity (see "How a manager is named" below
for how that operation is named).

**Every manager and controller answers `--help` anywhere in its argv, before it
does anything, and refuses an option the verb does not declare** (#644 — a
`distribute --help` once pushed zones.json for real). What a verb accepts is its
help entry, so an accepted option is a documented one.

**`<manager> --help --json` is the verb manifest** (ADR-034 D4): every verb with its words,
positionals and options (whether each takes a value, its choices), whether it reads or writes,
how its dry run is spelled (`--apply` to apply, or `--check` / `--dry-run` to preview, or no
preview and what it touches), and whether it is destructive (typed name, Installer). It is
rendered from the same `HelpSpec` (`lib/ts/src/help.ts` `renderManifest`); a verb's `effect`,
`destructive`, `readWhen` and `disruptive` marks are data in that spec, defaulting from its
name and options. The typed name is the verb's first positional unless the verb
declares its `object` — the positional that identifies what it acts on and those it is within
(`remove-port`: the port, shown as `<switch>:<port>`); a verb that does not declare one has no
`object` field. The console runs nothing a manifest does not declare; the bash
managers' verbs it runs (switch-manager, ap-manager) are declared in `ui/manifest/bash-verbs.json`.

A **controller**, by contrast, owns *runtime / device state*: it talks to a live
service or device (OPNsense, Authentik, a switch, Proxmox) and reconciles the
real world toward the desired config a manager hands it. Controllers live under
the sibling `controller/` directory and have **no `validate` operation** (there
is no config of their own to validate).

The short version:

| | Manager | Controller |
|---|---------|------------|
| Owns | configuration state (JSON files + schemas) | runtime / device state |
| Does | CRUD + validate config; may orchestrate controllers | reconcile a live service/device toward desired state |
| Has a `validate` operation | yes | no |

## The verb contract

The TAPPaaS "mothership" (the `tappaas-cicd` VM) drives every component
generically through a fixed, small set of **verb scripts**. Each manager is a
subdirectory here and provides these executables in its own root:

| Verb | Purpose |
|------|---------|
| `install.sh` | One-time setup: build any compiled artifact and link the component's CLI(s) onto `PATH` (`~/bin`). Idempotent. |
| `update.sh`  | Re-build (for compiled components) and re-link; run any on-disk state migration the new version needs. Idempotent. |
| `test.sh`    | Self-contained tests. Fast/non-disruptive by default; `TAPPAAS_TEST_DEEP=1` adds live/heavy tiers. Exits non-zero on failure. |

These three **lifecycle** verbs use generic filenames (every component has them)
and are **idempotent** — safe to re-run any number of times.

`validate` is different: it is a *domain operation* (validate this manager's own
config), not a lifecycle verb, and it is **not** dispatched generically. It is
named by the manager-naming convention below.

## How a manager is named (the verb convention)

A manager's own operations follow one of two forms depending on how it is built:

- **Single-binary managers** take the operation as their
  first argument: `identity-manager validate`, `network-manager reconcile`, etc.
  `validate` is simply one verb among the others.
- **Script (bash) managers** expose each operation as a separate
  `<verb>-<manager>.sh` script: `install-module.sh`, `update-module.sh`,
  `validate-environment.sh`, `validate-site.sh`. So a script manager's validate
  operation is `validate-<manager>.sh`, **not** a generic `validate.sh`.

The long-term direction is that all managers become single-binary, at which point
every operation — `validate` included — is a verb of the manager's binary.

## How the dispatcher runs the lifecycle verbs

A parent dispatcher at `manager/{install,update,test}.sh` runs each child
manager's matching **lifecycle** verb. It iterates the subdirectories, runs the
child's executable verb script if present, and continues past a failing child
(returning the worst exit code so a failure is never hidden). There is no
shared runner — each verb is fully self-contained. The
`tappaas-cicd` module calls these parent dispatchers as part of its own
install/update/test, so adding a new manager subdirectory makes it part of the
system automatically. (`validate` is invoked directly via the manager's own
verb — `validate-<manager>.sh` or `<manager> validate` — not through a parent
dispatcher.)

## The managers

| Manager | Owns / does |
|---------|-------------|
| [`identity-manager`](identity-manager/) | The People domain: Organizations, Groups, Users, and Roles. CRUD/read on `config/identities/`, bootstrap of a minimal org, and a reconcile/`sync` engine that drives the identity (Authentik) controller. |
| [`site-manager`](site-manager/) | The Site: site-wide identity, location, hardware (Proxmox nodes + storage pools), backup, update schedule, repositories. Owns `config/site.json` and migrates the legacy `configuration.json` into it. |
| [`environment-manager`](environment-manager/) | The Environment taxonomy: per-tenant deployment contexts (public domain(s), DNS mode, network-zone reference, data residency, backup, legal). Owns `config/environments/*.json` and bootstraps the always-required `mgmt` + default environments. |
| [`module-manager`](module-manager/) | The module lifecycle: install / update / delete / test / snapshot of TAPPaaS modules, with scope/source classification lint and environment-aware deployment. Owns the per-module JSON in `config/`. |
| [`network-manager`](network-manager/) | The network front door: owns `zones.json` (CRUD + VLAN allocation) and reconciles four infrastructure planes (OPNsense, Proxmox, switch, access points) by orchestrating their controllers. Also the admin VPN (`network-manager wgvpn`: WireGuard into mgmt, terminating on OPNsense — formerly `satellite-manager admin`). |
| [`health-manager`](health-manager/) | The health lens (ADR-007e): `validate` asserts the live site is healthy (liveness, disk, memory, backup coverage, pending reboots, CVE status); `update-os` and `reboot` patch and restart a guest; `scan security` / `report security` inventory everything running and match it against CVE databases (ADR-011 — `config/sbom/`, run after every sweep). Read-mostly; owns no config. |
| [`backup-manager`](backup-manager/) | The backup hierarchy: the Site → Environment → Module backup-policy cascade. Resolves the effective backup policy (retention, residency, enabled, exclude) for any module, reports status across all modules, validates the hierarchy, and delegates restore/PBS ops to `pbs-controller` + the foundation `restore.sh`. |
| [`storage-manager`](storage-manager/) | Storage for consumer modules (ADR-029 v0.9): owns `config/shares.json`, the Site's NFS shares keyed by name, and changes it one share at a time (`nfs share add/modify/delete/purge`, `nfs grant/revoke`, `nfs show`, `nfs converge`). Each change is validated, written atomically and converged at once — the share's server builds it through its module's NFS hook and the alias `nfs-<share>.mgmt.internal` follows. Consumers mount through the `storage` module's `storage:nfs`. |

The satellite has no manager of its own: `satellite-manager` was retired (ADR-010 §8.4) —
the satellite is an ordinary module under `module-manager`, and its admin-VPN verbs are
`network-manager wgvpn`.

To build a new manager, copy the nearest real one and edit (see the
"Scaffolding a new component" section in [`../README.md`](../README.md) — the
scaffold TEMPLATE dir was retired).
