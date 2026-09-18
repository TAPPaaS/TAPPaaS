# ADR-026 — Managed Machines as Modules

| | |
|---|---|
| **Status** | **Proposed** (2026-09-18) |
| **Version** | 0.4 |
| **Date** | 2026-09-18 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Refines** | [ADR-022c](<ADR-022c - Node and Host.md>) (Node, cluster member, Host) · [ADR-022f](<ADR-022f - Kind Values and Operating System.md>) (`kind: machine`, OS facet) · [ADR-022g](<ADR-022g - Management.md>) (`management`) · [ADR-022e](<ADR-022e - Module Scope.md>) (`scope`, D4 multiplicity) |
| **Related** | [ADR-012](ADR-012-backup-enhancement.md) §1 (the fourth backup topology this enables) · [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) §8 (the satellite as a machine) · [ADR-007d](<ADR-007d - Site.md>) (`site.json hardware.nodes[]`) |
| **Changelog** | v0.4 (2026-09-18) — D8: a machine becomes a module by `module adopt <fqdn|ip>` (key, facts, module by OS, instance named after the machine, zone from its address) or `module add --pxe` (site-manager's PXE model); `node add` becomes their composition. · v0.3 (2026-09-18) — operator answers folded in: D2a decided (membership from `site.json`), D6.5 (`node` names an instance), D6.6 (a dependency pins an instance via a field on the caller), D7 (one module type per OS; `templates:<os>` reuse deferred). · v0.2 (2026-09-18) — D4 gains stage 3 (the cluster install becomes module installs); D6 settles that an instance name is not a module name — `config/<instance>.json`, module from `.location`, a synthetic `module` field, and the defaults. · v0.1 (2026-09-18) — proposal: every machine TAPPaaS manages is a module of `kind: machine`; `debianhost` supplies the OS lifecycle; cluster nodes and the satellite follow; several instances of one module in one Environment. |

A machine TAPPaaS manages is a **module**, not a special case.

---

## Context

TAPPaaS manages three kinds of machine today and models none of them the same way:

| Machine | How it is known | How its OS is patched |
|---|---|---|
| A Proxmox **cluster node** | a `{name, storagePools}` entry in `site.json hardware.nodes[]` | the `cluster` module, via `update-os.sh` |
| The **satellite** | a hand-copied `config/satellite-<name>.json` (ADR-010 §5.2) | `satellite-manager`, outside the module lifecycle |
| A **standalone PBS host** (Erik's setup) | not modelled at all | nothing — the operator patches it by hand |

Three mechanisms, three vocabularies, and one of them is "remember to do it yourself". The
gap is not cosmetic: **ADR-012 assumes its Host is patched by someone.** Backup installs
`proxmox-backup-server` onto a Host and manages the datastore, jobs and clients on it
(ADR-022f D5) — but the packages underneath belong to the Host. On a cluster node the
`cluster` module does that. On a machine outside the cluster nobody does, which is why
ADR-022f D5 records it as *"a gap for the module model, not for backup"*.

ADR-022 closed the vocabulary gap: `kind: machine` is exactly this thing (022f D1 leaf 3).
What is missing is the module that *is* one.

## Decision

### D1 — A managed machine is a module of `kind: machine`

Every machine TAPPaaS manages is declared as an ordinary module: a config in `config/`, a
source directory with `install.sh` / `update.sh` / `test.sh`, resolvable through `.location`
or a repository catalog, and swept like anything else. No parallel mechanism, no hand-copied
config, no "breaks the module mold" (ADR-010 §5.1).

This makes the Host a first-class object. A module of `kind: application` names its Host in
`node` (022f D3); that Host is now something the model can point at, patch and test, rather
than an assumed substrate.

### D2 — The OS of a cluster node and of a Debian machine is the same: `debian`

Measured on `tappaas1`, 2026-09-18:

```
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
ID=debian
pve-manager/9.2.20 (running kernel: 7.0.14-17-pve)
```

A Proxmox node's `/etc/os-release` says `ID=debian`. "PVE" is not an operating system
identifier — it is a package set (`pve-manager`) and a kernel flavour on top of Debian. Under
ADR-022f D7, whose anchor is the freedesktop `os-release` `ID`, both a cluster node and a
standalone PBS machine are:

```json
"os": { "family": "linux", "id": "debian" }
```

**This is the reason the fourth topology works at all.** Proxmox VE is a superset of Debian,
so `proxmox-backup-server` installs the same way on both — which is precisely what makes a
PBS on a non-cluster machine the same application as a PBS on a node (022f D5).

**What distinguishes them is not the OS but cluster membership**, which ADR-022c D2 already
names: a **cluster member** is a Node declared in `site.json`. A cluster node is a `machine`
that is a cluster member; a standalone PBS host is a `machine` that is not. Recording that as
`os.id: pve` would encode a role in an OS field and then have to be undone.

**D2a — cluster membership is read from `site.json`, not carried on the module.** The
alternative was a facet on the machine module, which would make the module self-describing at
the cost of two places to look. `site.json` stays the one source of truth: a machine module
says *what the machine is*, and membership is a property of the cluster, not of the machine.

The direction of travel makes this the cheaper answer as well. A **`cluster` module** is
already foreseen (ADR-022d leaves `cluster` as a grouping concept for its own ADR); when it
exists it owns the register of which machines have been rolled into the cluster, and that
register is `site.json`'s `hardware.nodes[]` grown up. Putting membership on the machine now
would be a field to migrate away from later.

### D3 — `debianhost` supplies the OS lifecycle

A new module type, `debianhost`, whose whole job is the thing no one does today for a machine
outside the cluster:

| Verb | Does |
|---|---|
| `install.sh` | register the machine: SSH access, key, OS facts; verify reachability |
| `update.sh` | `apt update && apt upgrade` under the sweep's rules — the same cadence and the same `rebootOk` consent a cluster node gets |
| `test.sh` | reachable, patched, no pending reboot, disk and time sane |

It is the landing point that lets ADR-012's fourth topology be tested rather than asserted.
Building it first, on its own, is deliberate: a module that only patches a machine is small
enough to get right, and everything below depends on it behaving.

### D4 — Cluster nodes become machine modules too, in three stages

`site-manager node add` becomes: **add a `machine` module, then join it to the cluster.** The
node is a module first and a cluster member second.

- **Stage 1 — register (#665).** Existing cluster nodes are declared as machine modules with
  `management: managed`, `os.id: debian`. Nothing changes about how they are patched; the
  model simply stops pretending they are not machines.
- **Stage 2 — lifecycle.** `update-os.sh` moves behind the module's `update.sh`, so a cluster
  node and a Debian host are patched by the same path with the same consent rules.
- **Stage 3 — install.** The cluster install is refactored to *install machines by installing
  modules*: bringing a node up is `module-manager module install <instance>` against a
  `machine` module, and joining the cluster is a step of that install rather than a separate
  bootstrap path. At the end of stage 3 there is one way to bring a machine into a TAPPaaS —
  the same way anything else arrives — and `site-manager` orchestrates module installs instead
  of carrying its own provisioning code.

Staging matters because the stages differ by an order of magnitude in blast radius: stage 1 is
inert — it adds configs; stage 2 changes how every node in every installation gets patched;
stage 3 changes how every installation is *built*, so it lands last and behind stage 2's
evidence that the module path patches a node correctly.

### D5 — The satellite starts `managed` and becomes `unmanaged`

The satellite is a `machine` module with `os.id: debian` (ADR-010 §8). Its `management` value
**changes over its life**, which no other module's does:

| Phase | `management` | Why |
|---|---|---|
| Provisioning | `managed` | `satellite-manager` installs the OS, keys and roles |
| Running | `unmanaged` | it must be independent to be secure |

This is not an exception to ADR-022g D1 but an instance of it: `unmanaged` means "registered,
no lifecycle applies", which is exactly the desired end state. ADR-010 §7.3 already requires
that `tappaas-cicd` retains no standing root on a satellite after provisioning — the
compromise-isolation rule that keeps the off-site vault outside the blast radius of the home
cluster. Recording the transition makes that rule visible in the model rather than only in
prose.

> **Consequence:** an `unmanaged` satellite is *not* patched by TAPPaaS. Its OS updates are
> its own (unattended-upgrades, per ADR-010 §5). D3's `debianhost` lifecycle therefore does
> **not** apply to a running satellite, and must not be assumed to.

### D6 — An instance name is not a module name

`tappaas1`, `tappaas2`, `tappaas3` are three instances of the same module in the same
Environment. Today the deployed-config convention has no room for that: a config is
`<module>` or `<module>-<environment>` (ADR-007b), so three cluster nodes collide on one name.
ADR-022e D4 already says scope is not multiplicity and names `satellite` as a site-scoped
module with several instances. This ADR settles what the names mean.

The starting point is that **the config file name is the instance**. What follows is not new
syntax; it is what `config/` already holds, written down so that scripts stop guessing.

**D6.1 — `config/<instance>.json` names the instance, always.** Every config in `config/` is
one instance of one module. The file name is the instance name and carries no other meaning.
That the instance name today usually *equals* the module name is a default (D6.4), not a
derivation rule, and the two must stop being conflated.

**D6.2 — the module is named by `.location`.** `.location` is the absolute path of the
module's source directory — the one holding `install.sh`, `update.sh`, `test.sh`. It is the
only field that points at the module, and it is therefore the single source of truth for
module identity. Its basename is the module name.

**D6.3 — a synthetic `module` field, derived from `.location`, used everywhere.** Derived, not
authored: nothing writes `module` into a config, and an operator cannot set it. Every script
and every TypeScript reader that means *"which module is this?"* reads that synthetic field
rather than parsing a name. It resolves in this order:

1. `basename(.location)` when `.location` is set — the normal case;
2. the catalog entry that resolved the config when it is not (`.location` postdates some
   configs; the catalog is #460's second resolution path);
3. an error when neither answers. A config whose module cannot be identified is not
   updatable — #659 made exactly that case fatal instead of a silent success.

**Never derive the module from `vmname`.** `vmname` is an instance name too: it names the
guest, and three instances of one module have three `vmname`s. The same caution applies to the
config file's own name — see the consequence below.

> **Consequence for `resolve_base_module_name()` (#659).** That helper derives a module name by
> stripping a declared-environment suffix from the config name. It is correct only while the
> instance name is `<module>` or `<module>-<environment>` — that is, only while D6.4's default
> has not been overridden. Under this decision it is a **fallback** for a config that answers
> neither 1 nor 2 above, not the rule; the primary path is D6.3. Its name should say what it
> does — it guesses a module from a config name.

**D6.4 — defaults, and an explicit argument.** When a module is created in, or added to, a
system:

| Given | Instance name | Example |
|---|---|---|
| nothing | the **module name**, with the environment appended where the deployment convention calls for it (`<module>-<environment>`, ADR-007b; `mgmt` takes no suffix) | `nextcloud` module → `config/nextcloud-lab1.json` |
| an instance argument | that name, verbatim | `--instance tappaas2` → `config/tappaas2.json` |

The default reproduces exactly today's names, which is why this decision migrates nothing on
day one: every existing config is already an instance whose name happens to be the default.

The three cluster nodes are then three configs — `tappaas1.json`, `tappaas2.json`,
`tappaas3.json` — with the same `.location`, hence the same synthetic `module`, in the same
Environment.

**D6.5 — `node` names an instance.** The `node` field names the Host a module runs on
(ADR-022c D3). Under D6 that Host is an **instance** of a module, not a module — `node:
"tappaas2"` points at the instance `config/tappaas2.json`. In something like 99% of
deployments the two names coincide, because D6.4's default makes them coincide, which is
exactly why the field has read either way until now. It reads as an instance.

**D6.6 — a dependency names an instance in the caller, not in the coordinate.** The coordinate
`<module>:<service>` (GLOSSARY §D) resolves to a module, which is now one-to-many. It stays
that way: the coordinate is not extended with an instance. When a `dependsOn` genuinely has to
reach one particular instance, **the caller carries a field naming it** — the dependency says
*which service*, the caller's own config says *which instance of it*. That keeps the
service graph about services and leaves instance selection where the deployment decision is
already made.

> **Refine on a real example.** No module needs this today; the rule above is the shape, and
> the field's name and how it is validated wait for the first actual case rather than being
> invented ahead of one.

### D7 — One module type per OS, not one that branches on the OS facet

`debianhost` is Debian's. **NixOS does not share it, and Windows certainly does not.** The
question was whether the `os` facet (022f D7) could select behaviour inside a single
`machinehost` module; the answer is no. What a machine module *is* — its `install.sh`,
`update.sh`, `test.sh` — is the OS's lifecycle, and `apt upgrade`, `nixos-rebuild` and Windows
Update are not three branches of one procedure. A module that tried to be all three would be a
`case` statement wearing a module's clothes, and every verb inside it would be written twice.

The `os` facet keeps the job it has: it **describes** a machine, and lets a reader ask what is
running where. It does not dispatch a lifecycle. Selecting the right module for a machine is
the operator's declaration, the same way it is for anything else.

> **Open (D7a):** whether a machine module can reuse the **`templates:<os>` dependency** that
> VM modules use — `dependsOn: ["templates:nixos"]` with `imageType: "clone"`, the mechanism
> that gives a VM its base image. A physical machine is not cloned from a Proxmox template, so
> the reuse would be of the *OS-hooks* half of `templates` (`services/<os>/*.sh`) rather than
> the image half. Worth doing if it falls out cleanly; **not in the first iteration** —
> `debianhost` is built standalone (D3) precisely so that it is small enough to get right.

### D8 — How a machine becomes a module: `adopt` it, or `add` it over PXE

A machine arrives in one of two states — already running, or bare — and each gets one verb on
`module-manager`. Neither is new in kind: `site-manager node add` already has exactly these two
shapes for cluster nodes (`adoptNode` for a node installed by hand, `provisionNode --pxe` for
a bare one, sharing one join pipeline — `site-manager/src/provision.ts`). D8 generalises that
from "a cluster node" to "any machine module", which is also what D4 stage 3 needs.

**D8.1 — `module-manager module adopt <fqdn|ip>`: a machine that already runs.**

1. **Reach.** Resolve the name, then print the mothership's public key with the one command
   that authorises it — on the machine's console, or `ssh-copy-id` from the operator's own
   laptop — and wait until a key login works (`BatchMode`, no password). `adopt` never asks
   for or handles a password: it cannot, since the nodes are key-only (#19), and it should
   not, since a password typed into the mothership is a credential the mothership then holds.
2. **Learn.** Read `/etc/os-release` into the OS facet (`os.family`, `os.id`, ADR-022f D7),
   the machine's hostname, and its addresses.
3. **Choose the module** by `os.id`, one module type per OS (D7): `debian` → `debianhost`. An
   OS with no machine module stops the adoption and says so; it does not fall back to a
   near match.
4. **Name the instance after the machine.** The instance name defaults to the machine's own
   hostname — a machine is named for itself (ADR-022f D2, RFC 1178), and D6.4's "module
   name" default would collide the moment a second one is adopted. It is **refused** if
   `config/<name>.json` already exists; `--instance <name>` overrides (D6.4).
5. **Find its zone** by matching its address against the subnets in `zones.json`; that
   becomes `zone0`. An address in no zone **stops** the adoption: the machine is either
   off-site — a Location reached through a tunnel, as the satellite is (ADR-010) — or outside
   the Administrative Domain, in which case it is not a managed machine at all (ADR-022g).
   Either is the operator's call, not a guess; `--zone` overrides.
6. **Become a module.** Write `config/<instance>.json` — `.location` pointing at the module,
   `kind: machine`, the OS facet, `zone0`, `management: managed` — and run the module's own
   `install.sh` (for `debianhost`, D3: register and verify). From then on the machine is in
   the sweep like any other module.

**D8.2 — `module-manager module add <module> --pxe`: a machine that is bare.** The same
outcome, reached by installing the OS first. It reuses `site-manager`'s model rather than a
second one: the node-provisioner PXE trap boots the machine, an answer file installs the OS
**with the mothership's key already in it** (so step 1 of D8.1 has nothing to do), and the
TTL on the trap keeps the boot phase fail-safe. After the install the flow joins D8.1 at
step 2 — one pipeline, two entry points, exactly as `provisionNode` joins `adoptNode`.

**D8.3 — `site-manager node add` becomes a composition.** A cluster node is a machine module
that is then joined to the cluster (D4). Once D8 exists, `node add tappaasN` is `module adopt`
(or `module add --pxe`) of a Proxmox machine followed by the join steps (`pvecm add`,
`site.json` capture) — which is D4 stage 3 made concrete.

> **Open (D8a):** PXE for an OS other than Proxmox. The node-provisioner trap installs
> Proxmox VE from an answer file; a `debianhost` over PXE needs a Debian netboot with a
> preseed that carries the key. Until that exists, `add --pxe` covers cluster nodes and
> `adopt` covers every other machine.
>
> *Naming note:* `adopt` already names a drift outcome in ADR-020 D9 — config follows
> reality for a grow-only field. The two mean the same thing in spirit (take what exists as
> the truth), which is why the word is reused rather than avoided.

## Consequences

**Positive.** One mechanism for every machine. ADR-012's fourth topology becomes testable. The
satellite stops being a special case. A Host is an object the model can name, patch and check,
which is what `kind: application` assumes.

**Costs.** Stage 2 of D4 changes how every installation patches its nodes — high blast radius,
and it needs the `rebootOk` and window rules to be exactly right; stage 3 rewrites the install
path itself. D6 renames no existing config — its default reproduces today's names — but the
synthetic `module` field has to be threaded through every script and TypeScript reader that
currently assumes a config's name is its module's name, and each of those is a place that was
silently correct until an instance was named something else. `debianhost` is a new module to
maintain.

**Neutral.** Registering machines as modules makes `module-manager list` longer. That is the
point: today those machines are invisible to it.

## Migration

The field changes are a change to the shape of `config/`, so under ADR-025 D7 each ships as a
numbered migration with a before→after fixture. Order, because each step depends on the last:

1. `debianhost` module built and tested against a real Debian machine (D3), brought in by
   `module-manager module adopt` (D8.1) — the first user of the verb.
2. ADR-012's fourth topology verified on it (PBS on a non-cluster machine).
3. The synthetic `module` field landed through the scripts and TypeScript (D6.3), and the
   instance argument accepted (D6.4) — a prerequisite for registering three cluster nodes.
4. Cluster nodes registered as modules, stage 1 only (D4).
5. Satellite converted (ADR-010 §8.2), including its `managed → unmanaged` transition.
6. Node patching moved behind the module lifecycle, stage 2 (D4).
7. The cluster install refactored onto module installs, stage 3 (D4): `node add` as `module
   adopt` / `module add --pxe` plus the join (D8.3).

## Open questions

Answered 2026-09-18 by the operator, and moved into the decisions: **D2a** (cluster membership
is read from `site.json`; a future `cluster` module owns that register), **D6a** (a dependency
names an instance through a field on the caller, not in the coordinate — D6.6), and the
per-OS question (one module type per OS — D7). What remains:

- **D6.6's field** — its name and validation, deliberately left until a module actually needs
  to pin one instance of another.
- **D7a** — whether a machine module can reuse the `templates:<os>` dependency VM modules use.
  Not in the first iteration.
- **D8a** — PXE for an OS other than Proxmox (a Debian netboot + preseed carrying the key).
  Until then `add --pxe` covers cluster nodes, `adopt` everything else.
- **`placementState`** — ADR-012 v0.9 settled the backup case (`node` \| `shim` \| `external`,
  §1). The general point the operator made stands and is recorded as **D6.5**: the `node` field
  names an *instance*, which coincides with a module name in almost every deployment but is not
  the same thing. Any remaining placement vocabulary follows from that, not from a separate
  decision here.
