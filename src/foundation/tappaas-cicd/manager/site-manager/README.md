# site-manager

The **Site** manager. The Site is the umbrella over a whole TAPPaaS installation:
site-wide identity, location, hardware (Proxmox nodes + storage pools), backup,
update schedule, repositories, and references to the environment/organization
config. (Domain / DNS / identity are *per-environment*, owned by
`environment-manager`, not here.)

## What it owns

`config/site.json` (default `${TAPPAAS_CONFIG:-/home/tappaas/config}/site.json`),
validated against `site-fields.json`. A site from before 2.1 may still list
its repositories in the legacy `config/configuration.json`
(`.tappaas.repositories`); the repository tools and the config migrations read
them there while `site.json` has none.

## `site-manager`

The `site-manager` bin is the front door. It owns the Site as a **singleton**
and the `node` / `repository` sub-entities, following the same `<entity> <verb>`
shape as `network-manager`. The heavy git/cluster I/O stays in the still-live
bash tools, invoked as thin delegations: `add` → `create-site.sh`,
`repository add`/`delete` → `repository.sh`, `validate` → `validate-site.sh`.
The bin owns config CRUD (`site modify`, `node` CRUD, the `site.json` writes) +
`validate` + `reconcile`.

### Entities and verbs

```
site (singleton)   site show [--json]
                   site modify --<field> <value> [...]
node               node list [--json]
                   node add <N> [--pxe] [--boot-disk <d>] [--mac <m>]
                            [--wan-port <if>|--no-wan] [--lan-ports <a,b>]
                            [--lan-mode <m>] [--lan-primary <if>] [--pool <p>] [--ttl <s>]
                            [--config-only]
                   node delete <name> [--apply] [--shutdown|--erase|--lost]
                               [--config-only]
                   node reconcile [--apply]
                   node qdevice add <host> [--user <u>] [--force] | remove | status
                   node network show <node> [--json]
                   node network set <node> [--lan-ports <a,b>] [--lan-mode <m>]
                            [--lan-primary <if>] [--mtu <n>] [--no-wan] [--config-only] [--apply] [--yes]
                   node network test <node> [--apply] [--yes]
repository         repository list [--json]
                   repository add <url> [--branch <b>] [--managed full|tracked] [--catalog <p>]
                   repository delete <name> [--force]
                   repository reconcile [--apply]
                   repository sync <name> [--dry-run]                (#814)
                   repository hold <name> --reason <text> [--until <30m|12h|7d|date>]
                   repository release <name>
                   repository validate-catalog [<name>] [--strict]   (#463)
                   repository stash list [<name>]                    (#681)
                   repository stash show|restore|discard <name> <sha> [--force]
top-level          add --name <site-code> [--organization <org>] [create-site options]  (= create-site.sh)
                   validate [FILE] [--schema-dir PATH]     (= validate-site.sh)
                   (validate also checks updateSchedule and prints the OnCalendar it renders)
                   reconcile [--apply] [--deep]
                   update [--dry-run] [--force] [--no-git-pull]   (starts update-tappaas.service)
                   test [--deep]                                  (= module-manager test each)
```

`update` runs the whole-site update **now** by starting `update-tappaas.service`
— the unit the timer starts, so the operator exercises the scheduled path
(ADR-017 D4). It follows the run's journal; Ctrl-C only detaches. The options
travel in a one-shot request, `config/.update-request.json`, which the unit
claims. `--dry-run` starts nothing: it reports each repository against its
origin, then the sweep's plan. `--force` updates every module even when its
pre-update test failed fatally, and nothing more — it reboots nothing.
`--allow-disruption` opens the downtime window for that run: a module with
`rebootOk: true` may be rebooted or migrated offline, every other module keeps
its disruptive changes deferred, and `rebootOk: false` is never overridden
fleet-wide. For one module that is
`module-manager module update <module> --allow-disruption` (ADR-020 v0.10 D8, #633). `--no-git-pull` (`TAPPAAS_NO_GIT_PULL`) updates
whatever is checked out — refresh-control-plane.sh skips the per-repo pull — so local,
not-yet-pushed changes can be tested. `--dry-run` previews the plan.

`test` runs every deployed module's tests: it iterates
`module-manager list` (foundation + apps, from every registered repository) and
runs `module-manager test <m>`, forwarding `--deep`. Continue-on-failure; exits
non-zero if any module test failed.

Common options: `--config-dir DIR`, `--json` (machine output for list/show),
`--apply` (reconcile commits; default is preview), `--deep` (reconcile cascade),
`--force` (repository delete → `repository.sh remove --force`).

When a run fails, the site owner hears about it: `update-tappaas-failure.service` mails
`site.json` `email` through a Proxmox node's mail system, naming the step that failed
(#651; ADR-007e v1.3 owns the target). Every run is also followed by a security scan of
what it left running (`health-manager report security`, ADR-011). `site show` prints the schedule as it is meant —
no weekday under `daily`/`none` (#447) — and the TAPPaaS version the site runs, read from its
checkout (`2.2`, or `2.2+14` between boundaries; ADR-028 D13), beside the one it was installed from.

`repository hold` stops the scheduled sweep from pulling one repository, so a test
site can run changes that are not pushed yet (#653). The marker is
`config/.repo-hold/<repo>.json`; every hold expires (default 24h), and an
expired hold is removed by the next sweep, which then pulls again.
`repository list` and `update` show active holds.

`repository sync <name>` brings one repository to the tip of its declared branch
without the sweep (#814). It keeps the sweep's guards (the hold, the auto-stash,
no commits that exist only in the checkout) and decides on the fetched tip before
anything moves. It **refuses**, and proposes `site-manager update`, when the tip
carries a config migration the ledger does not hold or changes the mothership's
own NixOS configuration: both need steps only the sweep runs. It names every
installed module whose source directory changes, and deploys none of them; a
change under `tappaas-cicd/lib/` is said to reach every module. When the
repository is the one the control plane is linked from, `refresh-control-plane.sh`
runs afterwards without a pull. `repository reconcile` now says how far behind
origin each checkout is, rather than calling a stale checkout "Converged".

`repository stash` is where the local changes a sync had to set aside go to be
found (#681). A dirty managed checkout is stashed so the pull can move and the
entry is put back afterwards; one that no longer applies is kept, and used to be
reported only as a number — `git stash list`, run by hand in a checkout the
operator is told not to edit, was the only way to see what the number meant. One
estate carried 12 such entries. `stash list` names every entry with its
repository, its age and the files it holds; `stash show` prints its diff;
`stash restore` puts it back when it still applies; `stash discard --force`
drops it. Entries an operator stashed by hand carry no repo-sync tag: they are
never listed, restored or dropped.

`repository validate-catalog` checks that a repository's module catalogue says true
things (#463): its shape and fields, a `moduleJson` that exists, `stack` and `vmid`
agreeing with the module's own file, one name and one VMID per module, and no module in
the tree left unlisted. With no argument it checks every `managed: full` repository. It
reports and exits 0 — every catalogue predates the check, and a stale one is no reason to
refuse a repository; `--strict` exits non-zero and is what CI and a contributor run before
opening a pull request. `repository add` runs it too, as a report.

`site modify` editable fields (scalar, site-wide): `--channel`, `--displayName`, `--owner`,
`--email`, `--automaticReboot`, `--snapshotRetention`, `--backupTarget`,
`--backupOffsite`, `--locationCountry`, `--locationTimezone`,
`--locationLocale`, `--locationKeyboard`, `--locationLatitude`,
`--locationLongitude`, `--locationCity`, `--locationBuilding` (#609: what an off-site copy is compared
with), `--networkIsp`, `--networkPublicIp`. The discovery-derived
`hardware.nodes[]` (use `node …`) and the `repositories`/`environments`/
`organizations` lists (own CRUD / own managers) are **not** modifiable here.

### `channel` — which release the site takes (ADR-028 D9, D11)

A **channel is a promise about risk**; the **branch is where the code sits**. They are separate
fields because they are separate statements, and an operator changing one before the other is a
normal moment, not an error.

| Channel | Branch (TAPPaaS repo) | What it means |
|---|---|---|
| `unstable` | `main` | development is proven here; the test site |
| `staging` | `staging` | soaks a revision under real use for one boundary |
| `production` | `stable` | what everyone else runs — the default for a new site |

```bash
site-manager site modify --channel staging          # the promise
site-manager repository modify TAPPaaS --branch staging   # the code
```

Either order works. Whichever you do first, the other command **warns** that the two disagree
and names the command that would settle it. It does not refuse: refusing would make the
two-step move impossible.

**Two moves need `--force`, because both take the site backwards:**

- **Towards production** (`unstable → staging → production`) moves to *older* code. Config
  migrations are forward-only (ADR-025), so a migration this site has already applied cannot be
  undone by changing channel — the older code simply reads a config shape it does not know.

**It checks every repository, not just TAPPaaS (ADR-028 D11).** Which branch realizes which channel
is declared by each repository in `channels.json` at its root, so setting a channel compares each
registered repository's branch against what that repository says, warns where they disagree — or
where no `channels.json` exists, in which case every branch in it reads as unstable — and prints the
`site-manager repository modify <name> --branch <b>` that would settle each. It never switches a
branch itself: that is a code change to a live site.
  `site modify --channel` refuses without `--force` and says why.
- **Onto a branch behind this site's migrations.** `repository modify --branch` reads the
  target branch's `migrations/` directly from the forge — no checkout needed — and compares its
  newest migration with the newest this site has applied (`config/.migrations/applied`). If the
  branch is behind, it refuses without `--force`. This is the same fact as above, caught from
  the branch side, and it also catches a hand-typed branch that belongs to no channel at all.

Both gates are passable on purpose. A release tool that cannot be overridden gets worked around
with a text editor, which is worse than an override that announces itself — and each one prints
what it is doing when `--force` lifts it.

Only the **TAPPaaS** repository is held to the train's branches: a community repository has no
`staging` or `stable` to track, so its branch is whatever its publisher uses.

#### `location` is the site's master data for time and locale (#408)

Country, keyboard and timezone are answered by the operator **once**, on the first
Proxmox install, and that node is the only place the answers exist. `site add` reads
them back from it — `timedatectl`, `XKBLAYOUT`, `LANG` — rather than from the
mothership, which is a NixOS template whose clock says nothing about where the site is.
The country is the exception: the installer asks for it and stores it nowhere, so it
stays derived from the timezone.

What is recorded here is what the rest of the estate is set from: the PXE answer file
(`node add --pxe`), the USB installer's defaults (`make-install-media.sh`), and the
per-OS convergence of guests and hosts. A value already in `site.json` is the operator's
and is never overwritten — a `site add --force` re-run fills in what is *missing* (a
site.json that predates `keyboard`) and warns when the recorded value and the master
disagree, naming the `site modify` command that would adopt the master.

`latitude` / `longitude` are operator-set: no node knows where it is. They exist for
modules that need a position rather than a country (#348).

### `node add` — standing up a follow-on node (design N3/N4)

`node add <tappaasN>` is the operator front door for growing the cluster;
hardware-validated end-to-end on 2026-07-07. Three modes:

- **default (adopt)** — a Proxmox was already installed by hand (USB stick,
  §2.1 media) at the node's DESIGNATED mgmt IP (`tappaasN` → `10.0.0.<9+N>`):
  verifies the hostname + `pveversion` over ssh, then runs the join pipeline.
  A node that is already clustered skips straight to capture.
- **`--pxe`** — bare machine: registers the node with `node-provisioner`,
  arms the TTL-limited PXE trap, waits for the unattended install (the ONLY
  console interaction is the boot-disk question, and only when `--boot-disk`
  was not given), then continues with the same join pipeline. Requires the
  netboot assets staged once per PVE version — done automatically by the
  cicd install (`prepare-netboot.sh`). Booting the SAME prepared ISO from a
  USB stick instead of PXE works identically (the answer still comes over
  HTTP from the mothership).
- **`--config-only`** — just write the `hardware.nodes[]` entry (no machine
  contact); the pre-N3 behaviour.

The join pipeline (shared by adopt and `--pxe`): asks for the WAN NIC and
the data-pool declarations with the node's REAL hardware listed (skip the
questions with `--wan-port <if>`/`--no-wan` and `--pool 'tanka1=…'`),
serves the repo from the mothership on :8090 (committed branch state — no
GitHub dependency), runs the node step (`install.sh --join`), corrects
`/etc/hosts`, seeds node→tappaas1 ssh trust, `pvecm add`, and captures the
node + its pools via `node reconcile --apply`. Every wait is time-boxed and
the PXE trap is disarmed on every exit path. Fully unattended example:

```
site-manager node add tappaas2 --pxe --boot-disk 25414A800205 \
    --mac aa:bb:cc:dd:ee:ff --no-wan --pool 'tanka1=single:50026B73842AD86F'
```

Up front, disks are named by **serial** (`lsblk -o NAME,SERIAL`) or
`disk/by-id/…`: a kernel name was read on another boot than the install's, and
NVMe names swap between boots (#729 §3), so `--pxe` refuses `sda`/`nvme0n1`.
After the install node add puts the installed disk first in the UEFI boot
order, and if the answer's ssh key did not survive the first boot it restores it
with the node's generated root password (`/home/tappaas/.node-secrets/<name>.pw`,
the operator's, 0600).

Afterwards run `site-manager update` to fold HA + replication.

### `reconcile` and the `--deep` cascade

`reconcile` is **shallow by default** — it converges the site's own concern:
validate `site.json`, then bring each `repositories[]` entry to a live clone
(clone if missing, checkout if the branch drifts). Default output is a
**preview**; `--apply` commits. `repository reconcile` is the repo-scoped
subset of the same engine.

`reconcile --deep` then cascades to the dependent managers in dependency order:

```
site reconcile --deep
  → identity-manager  reconcile          (people → Authentik)
  → network-manager reconcile          (the 4 network planes — ONE system-wide pass)
  → for each environment in config/environments/*.json:
       environment-manager reconcile <env> --deep --skip-network
```

people/network are single bins; environments fan out — one deep reconcile per
registered environment. The **network pass runs once for the whole site**:
`network-manager reconcile` has no zone or environment filter, so letting each
environment run its own would repeat the identical whole-platform operation once
per environment. Every leg is idempotent, so re-running is safe; this is
the natural whole-platform converge after `update-tappaas`.

A cascade that exits non-zero is reported by name and makes `site reconcile`
exit 1 — the remaining legs still run, so one bad environment does not strand
the rest.

### Build

Built by `default.nix` into `result/bin/site-manager` — mirroring
`identity-manager` / `network-manager`. `install.sh` is **not** yet wired to build
it (the bash tools below remain the installed entry points for now).

## Commands (legacy bash tools — kept live until cutover)

All scripts are bash, linked onto `PATH` by `install.sh`. `repository.sh` and
`validate-site.sh` remain live and are the tools the `repository add`/`delete`
and `validate` verbs delegate to; `create-site.sh` backs the `add` verb.

### `repository.sh` — manage module repositories

The tool behind `site-manager repository …`: it registers the module
repositories TAPPaaS pulls modules from (add / remove / modify / list) in
`site.json` `repositories[]`, cloning each under `/home/tappaas/<name>/` over
HTTPS. A repository is always cloned by `add`, never adopted from an existing
checkout elsewhere. A private repository is reached with a deploy key — see
[Private repositories](../../DESIGN-GIT.md#adding-a-private-repository).

```
repository.sh add <url> [--branch <b>] [--managed full|tracked] [--catalog <path>]
repository.sh remove <name> [--force]
repository.sh modify <name> [--url <new>] [--branch <new>]
repository.sh list
```

### `validate-site.sh` — validate site.json

This is the manager's `validate` operation, named `validate-site.sh` per the
script-manager `validate-<manager>.sh` convention; runnable directly.

```
validate-site.sh [FILE] [--schema-dir PATH] [--quiet]
```

- `FILE` — site.json to validate (default `$TAPPAAS_CONFIG/site.json`).
- `--schema-dir PATH` — directory holding `site-fields.json`.
- `--quiet` — errors/warnings only.

```bash
validate-site.sh
```

## Legacy tools (kept until the flag-day cutover)

These predate `site.json` and operate on the legacy `configuration.json`:

### `create-configuration.sh`

Create/update `configuration.json` by discovering the running Proxmox cluster.
Accepts named flags (`--upstream-git`, `--branch`, `--domain`, `--email`,
`--schedule monthly|weekly|daily|none`, `--weekday`, `--hour`, `--primary-node`,
`--update`) or legacy positionals
(`<upstreamGit> <branch> <domain> <email> <schedule> [weekday] [hour]`). Idempotent.

### `validate-configuration.sh`

Validate `configuration.json`. Flags: `--config <path>`, `--check-connectivity`
(ping nodes), `--check-cluster` (SSH the first node, compare cluster membership),
`--check-repos` (git ls-remote each repo URL), `--quiet`.

### `convert-json-to-config.sh`

Convert a flat module JSON into the canonical config-block form. CLI:
`convert-json-to-config.sh [--in-place|--dry-run] <module-json>`; or source it and
call `regroup_to_pattern_a`.
