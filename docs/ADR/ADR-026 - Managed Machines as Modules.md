# ADR-026 — Managed Machines as Modules

| | |
|---|---|
| **Status** | **Proposed** (2026-09-18) |
| **Version** | 0.2 |
| **Date** | 2026-09-18 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Refines** | [ADR-022c](<ADR-022c - Node and Host.md>) (Node, cluster member, Host) · [ADR-022f](<ADR-022f - Kind Values and Operating System.md>) (`kind: machine`, OS facet) · [ADR-022g](<ADR-022g - Management.md>) (`management`) · [ADR-022e](<ADR-022e - Module Scope.md>) (`scope`, D4 multiplicity) |
| **Related** | [ADR-012](ADR-012-backup-enhancement.md) §1 (the fourth backup topology this enables) · [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) §8 (the satellite as a machine) · [ADR-007d](<ADR-007d - Site.md>) (`site.json hardware.nodes[]`) |
| **Changelog** | v0.2 (2026-09-18) — D4 gains stage 3 (the cluster install becomes module installs); D6 settles that an instance name is not a module name — `config/<instance>.json`, module from `.location`, a synthetic `module` field, and the defaults. · v0.1 (2026-09-18) — proposal: every machine TAPPaaS manages is a module of `kind: machine`; `debianhost` supplies the OS lifecycle; cluster nodes and the satellite follow; several instances of one module in one Environment. |

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

> **Open (D2a):** whether "is a cluster member" is read from `site.json` (where it lives
> today) or becomes a facet on the machine module. Reading it from `site.json` keeps one
> source of truth; a facet makes the module self-describing. Not decided here.

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

> **Open (D6a):** how a *dependency* names an instance. The coordinate `<module>:<service>`
> (GLOSSARY §D) resolves to a module, which is now one-to-many. It is ambiguous only when a
> Site deploys two instances providing the same service; either `<instance>:<service>` or a
> rule that an unqualified module name means "any instance of it" would settle it. Not decided
> here.

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

1. `debianhost` module built and tested against a real Debian machine (D3).
2. ADR-012's fourth topology verified on it (PBS on a non-cluster machine).
3. The synthetic `module` field landed through the scripts and TypeScript (D6.3), and the
   instance argument accepted (D6.4) — a prerequisite for registering three cluster nodes.
4. Cluster nodes registered as modules, stage 1 only (D4).
5. Satellite converted (ADR-010 §8.2), including its `managed → unmanaged` transition.
6. Node patching moved behind the module lifecycle, stage 2 (D4).
7. The cluster install refactored onto module installs, stage 3 (D4).

## Open questions

- **D2a** — is cluster membership read from `site.json` or a facet on the machine module?
- **D6a** — how a dependency names one instance of a multi-instance module.
- **`placementState`** — ADR-012's placement vocabulary was written when a PBS could only be
  on a cluster node or somewhere else entirely. With a machine module as a Host, `node:<name>`
  and "consumed" no longer partition the space. Flagged by the operator 2026-09-18 and
  deliberately **not** decided here.
- Whether a Windows machine (`os.family: windows`) needs its own module type beside
  `debianhost`, or whether the OS facet is enough to select behaviour within one.
