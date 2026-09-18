# ADR-022f — Kind Values and Operating System

| | |
|---|---|
| **Status** | **Accepted** (2026-09-18) |
| **Version** | 1.0 |
| **Date** | 2026-09-17 (v1.0: 2026-09-18) |
| **Author** | ErikDaniel007 |
| **Deciders** | @ErikDaniel007, @LarsRossen |
| **Parent** | [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>) |
| **Amends** | [ADR-022d](<ADR-022d - Workload Classification.md>) (`kind` values — folded into it on acceptance) · [ADR-007b](<ADR-007b - Apps.md>) :17 ("App ≡ Module") · [ADR-009](<ADR-009 - Composition Meta-Model.md>) :42 (App) · [GLOSSARY.md](../../GLOSSARY.md) :22 (Apps) · [ADR-012](ADR-012-backup-enhancement.md) §1.3 (consumed PBS as a `device` record), §3.1 (`backup:filesystem` reads `os.id`) |
| **Related** | [ADR-022c](<ADR-022c - Node and Host.md>) (Host); [ADR-012](ADR-012-backup-enhancement.md) (backup); [ADR-011](<ADR-011 - SBOM Governance.md>) (CycloneDX); [ADR-022h](<ADR-022h - Facet Register.md>); #637, #614 |
| **Changelog** | v1.0 (2026-09-18) — accepted as implemented (operator): `os` is a string holding `os.id`, the family derived (D7). · v0.1 (2026-09-17) — proposal: `application` accepted, `host` → `machine`, operating system as a facet; backup as the worked example. |

Which unit a module realizes, and which operating system a system runs.

## Context

ADR-022d accepts `vm`, `lxc`, `host`, `device` and proposes `app`, `oci`. Three collisions remain:

1. **`host` is both a type and a role.** ADR-022d uses `host` as a `kind`; ADR-022c D3 defines **Host** as *the Node a module runs on*. A `vm` can be the Host of an application.
2. **`app` is taken twice** — `tier: app` (ADR-007b) and "App ≡ Module" (ADR-007b :17), where every module is an App.
3. **Operating system has no single definition.** The VM schema's `os` mixes family and distribution (`windows` beside `debian`, `nixos`, `ubuntu`); LXC derives `ostype` from the template name; satellites carry `os: debian | nixos`; cluster members and the `backup` machine carry nothing; `backup:filesystem` reads `.os // .ostype` as if both were one field.

The backup module shows why it matters. It installs PBS with `ssh root@<node> apt install proxmox-backup-server` (`backup/install.sh`). Proxmox documents that same command for *"Install Proxmox Backup Server on Debian"* and *"… on Proxmox VE"*. Greenfield, the Host is `tappaas1`, a cluster member. A PBS on a separate machine, not a cluster member, exists today only by adopting an existing install; PR #614 makes it a supported placement.

## Decision

**D1. `kind` names the unit a module realizes** — equivalently, which Controller builds it (ADR-007f). Every module lands in exactly one leaf:

1. Only network reachability is configured → `device`
2. It owns a Proxmox guest → `vm` or `lxc`
3. It owns a system with an OS that is not a Proxmox guest → `machine`
4. It installs software onto a Host → `application`

**D2. `host` is renamed `machine`.** **Host** stays the role defined in ADR-022c D3, filled by a `machine`, `vm` or `lxc`. Anchor: Cluster API `Machine` (physical or virtual); DMTF Redfish `ComputerSystem`.

A `machine` is named for itself, not for a service it hosts ([RFC 1178](https://www.rfc-editor.org/rfc/rfc1178)): services move between Hosts, names of machines should not. Cluster members keep their name for life (Proxmox VE: *"Changing the hostname and IP is not possible after cluster creation"*). An existing machine named after its service is not renamed by this ADR.

**D3. `application` is accepted**, replacing the proposed `app` — software installed onto a Host, owning no system of its own. It names its Host in the `node` field. Anchor: CycloneDX component type `application` (ECMA-424, already adopted by ADR-011); ArchiMate System Software assigned to a Node.

**D4. Backup is `kind: application` in every variant.** The variants differ only in their Host (`node`); whether that Host is a cluster member is recorded in `site.json`; whether PBS is installed, consumed or not yet built is `placementState`. Services are addressed by `<module>.<zone>.internal`, never by the Host's name.

**D5. Managing an application is independent of its Host.** Backup installs the same packages on a cluster member or on a separate machine, and afterwards manages its packages, datastore, jobs and clients the same way on both. Today it does not: an adopted PBS on a separate machine is recorded as `placementState: external`, and `backup/update.sh` then skips the job reconcile — PR #614 and ADR-022g D5 remove that difference. The Host's operating system — patches and major upgrades — belongs to the Host: the `cluster` module upgrades cluster members; a machine outside the cluster has no owner today, which is a gap for the module model, not for backup. Finding a Host that is not a cluster member is also a Host concern.

**D6. A consumed external PBS is not the backup module's kind.** When tracked, it is its own `device` registration that backup depends on.

**D7. Operating system is a facet of every system** — `machine`, `vm`, `lxc` — in two levels:

| Field | Values | Anchor |
|---|---|---|
| `os.family` | `linux` \| `windows` | Kubernetes `kubernetes.io/os` label |
| `os.id` | `debian`, `nixos`, `ubuntu`, … | freedesktop `os-release` `ID` |

An `application` inherits the OS of its Host; a `device` has none. For a VM, `ostype` stays the Proxmox hypervisor profile — a different question; for an LXC, `ostype` already names the distribution and becomes `os.id`.

> **As implemented (operator, 2026-09-18):** the facet is held in the existing field **`os`, a string holding `os.id`** — `cluster:vm` already carried `os` with exactly this vocabulary (`debian`, `ubuntu`, `nixos`, `windows`, `unknown`). `os.family` is **derived**, never stored: `debian`, `ubuntu`, `nixos` → `linux`; `windows` → `windows`. So `os: "debian"` means `{family: linux, id: debian}`, no config needs a migration, and the field became a general one (every system has an OS). Where this ADR writes `os.family` / `os.id`, read the derived family and the stored string.

**D8. The term is Module.** "App" remains a user-facing label, never a type or a field value (amends ADR-007b :17).

## Migration

- ADR-022d table: `host` → `machine`; `app` → `application` (Accepted); backup examples per D4–D6.
- `satellite`: `kind: external-host` → `machine` (the ADR-022d retirement list is unchanged).
- ~~VM `os` string → `os.family` + `os.id`~~ — not needed: the string **is** `os.id` and the family is derived (see D7, as implemented). Satellites and machines gain `os`; `backup:filesystem` reads it.

## Conflicts

- **#637 (09-16)** — backup with an external PBS as `kind: device`. D6 keeps backup's kind stable and gives the consumed endpoint its own `device` record.
- **#637 (09-14)** — `app` declined as service decomposition. `application` here is atomic: one package set on one Host, no decomposition.

## Acceptance

- [ ] ADR-022d updated per Migration; this ADR marked folded
- [ ] `machine`, `application`, `os.family`, `os.id` defined in `GLOSSARY.md`
- [ ] ADR-007b :17 amended
