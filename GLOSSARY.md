# TAPPaaS Ontology — Consolidated Glossary (SSOT)

> The **single summary glossary** for the TAPPaaS ontology. Every term used across ADR-007 (taxonomy),
> ADR-009 (composition), ADR-007f (realization) and **ADR-022a–h (the workload ontology)** is defined
> **once, here**. Other docs link to this; they do not redefine terms. The *decisions* live in the ADRs;
> this is the *vocabulary* SSOT.
>
> **Updated 2026-09-17** to the ADR-022 ribs. Four terms changed meaning and two left the file —
> see *§E What changed* at the end before relying on memory.

## Three orthogonal axes (one Module is described by all three)

| Axis | Question | Owns |
|------|----------|------|
| **Classification** | *what kind is it, for the value stream?* | ADR-007 + 007a–007e, ADR-022d–g |
| **Composition** | *how is it built?* | ADR-009, ADR-022c |
| **Realization** | *how is it operated (control plane)?* | ADR-007f |
| *(Discovery)* | *how do I browse it?* | catalog |

## A. Classification terms (ADR-007, ADR-022)

| Term | Definition |
|------|------------|
| **Site** | The physical + admin perimeter. One TAPPaaS = one Site. The *container* that holds the three classification terms. Its administrative boundary is the **Administrative Domain** (ADR-022a). |
| **Administrative Domain** | The boundary of one administrative authority (RFC 4375). What is inside it is *ours*; what is outside is **external**. A Site has one. |
| **People** | `Organization → Group → User`. Group is the RBAC primitive: finer-grained than Organization (org-level RBAC is too coarse), coarser than per-user rules. |
| **Module** | The atomic deployable unit — one `{name}.json` in `config/`. **The term is Module** (ADR-022f D8): *App* remains a user-facing label, never a type or a field value. See §B for its composition meaning. |
| **Environments** | Where Modules run — zones, domain, posture. Owned by one Organization. |
| **Health** | A cross-cutting **lens** (observability overlay) — applies across all classification terms, not a term itself. |
| **kind** | *What type of thing a module is* — equivalently, which Controller builds it. One leaf each (ADR-022f D1): `vm` · `lxc` · `machine` · `application` · `device`. `oci` and grouping concepts (`cluster`, `kubernetes`) are proposed, not decided. **Not** what it runs on — that is its Host. |
| **scope** | *Which level of Site ⊃ Environment a module belongs to* (ADR-022e): `site` (serves every Environment; installed in `mgmt`) · `environment` (belongs to one, may be installed in several). **Replaces `module.tier`.** Scope is not multiplicity, not `stack`, not a layer. |
| **management** | *Whether TAPPaaS runs a lifecycle against it* (ADR-022g): `managed` (installs, updates, tests, deletes) · `unmanaged` (registered so the Site knows it exists; no lifecycle). |
| **external** | **Only** "outside this Site's Administrative Domain" (ADR-022g D2). Never a management value, a `status`, a `kind` or a placement. An off-site machine the Site owns is *not* external — off-site is a Location. |
| **os** | A facet of every system (`machine`, `vm`, `lxc`), in two levels (ADR-022f D7): `os.family` = `linux` \| `windows`; `os.id` = `debian`, `nixos`, … An `application` inherits its Host's OS; a `device` has none. |
| **source** | Module origin/trust: `official` · `community` · `private` · `local`. |
| **status** | Maturity only (ADR-022g D3): `Development` · `Testing` · `Production` · `Deprecated`. |
| **tier** | **Trust class of a zone** (`zone.tier`, ADR-014) — and nothing else. The old `module.tier` is now `scope`; the Stack-promotion rule that lived here is now in ADR-007f. |
| **Tenant** | Architecture term for an isolated customer of a multi-tenant system. *Not* a UI term — the UI says **Organization**. |

### The `kind` values

| `kind` | It is | Example |
|---|---|---|
| **`vm`** | a virtual machine (KVM/QEMU) on a cluster member | `openwebui` |
| **`lxc`** | a Linux container on a cluster member | `vllm-amd` |
| **`machine`** | its own system with an OS, not a Proxmox guest — named for itself, not for what it hosts (RFC 1178) | `satellite` |
| **`application`** | software installed onto a Host, owning no system of its own; names its Host in `node` | `backup` |
| **`device`** | only network reachability is configured — no SSH, no checks | `alfen`, `smlight` |

> **`machine` is the kind; Host is the role.** ADR-022f D2 renamed the value `host` → `machine`
> precisely because the two were one word. A `machine`, `vm` or `lxc` **fills** a Host role; an
> `application` **runs on** one. ADR-022d's table still shows the old `host`/`app` spellings and is
> superseded on those two names by ADR-022f D2/D3.

## B. Composition terms (ADR-009 / ArchiMate, amended by ADR-022c)

| Term | Definition |
|------|------------|
| **Node** | ArchiMate's meaning, restored (ADR-022c D1): *a computational or physical resource that hosts, manipulates or interacts with other such resources.* A cluster member, a bare-metal host **and a VM** are all Nodes. |
| **cluster member** | A Node belonging to the Proxmox cluster, declared in `site.json` (ADR-022c D2). This is the narrow sense the glossary previously called "Node". |
| **Host** | The Node a Module runs on (ADR-022c D3). The `node` **field** keeps its name for compatibility: it names a Host and does **not** assert cluster membership. What it names is an **instance** (ADR-026 D6.5) — usually, but not necessarily, one whose name equals its module's. |
| **Module** | The atomic deployable unit: one `{name}.json`. *(The former "Module boundary = VM boundary" rule is amended by ADR-022d — a module need not be a VM: see `application`, `machine`, `device`.)* |
| **instance** | One *deployment* of a Module: one `{name}.json` in `config/`, whose file name is the **instance name** (ADR-026 D6). A Module may have several instances in one Environment (`tappaas1`, `tappaas2`, `tappaas3`). The instance name defaults to the module name (plus the environment suffix where the convention calls for it) but is not derived from it — the module is named by `.location`. |
| **Component** | A composable unit inside a Module (recursive). ArchiMate Application Component. |
| **Function** | Behaviour a Component realises. ArchiMate Application Function. |
| **Service** | A defined exposed interface (`provides`/`dependsOn`). ArchiMate Application Service. |
| **Stack** | An **Aggregation** of Modules realising a Capability. A *grouping*, not a dependency graph. Distinct from `scope` (ADR-022e D5). |
| **Capability** | What the platform can do (Strategy layer). A Stack *realizes* a Capability. |
| **Implementation** | The swappable concrete Artifact that realizes a Component/Module. |
| **Aggregation** | ArchiMate whole-part **grouping** (parts exist independently). *What is grouped.* A Stack is an Aggregation. |
| **Serving / dependency** | ArchiMate relation: one element depends on / is served by another (`dependsOn`/`provides`, `DEPENDENCIES.csv`). *How they relate.* **Distinct from Aggregation.** |
| **Facet** | An independent attribute of a module — `os`, `roles`, catalog domain — as against the single-valued `kind`. Registered in ADR-022h. |

> **Plane vocabulary is the `network` module's** (ADR-022c D4). Forwarding / control / management
> planes are defined by RFC 7426 in terms of network devices and traffic, and TAPPaaS runs a real
> forwarding plane in OPNsense and the switches — so the words are not reused for workloads. The
> general term for what a management plane acts on is **Managed Element** (MAPE-K).

## C. Realization terms (ADR-007f)

| Term | Definition |
|------|------------|
| **Manager** | Top-level control-plane orchestrator for a classification domain (e.g. `environment-manager`, `module-manager`, `site-manager`). Orchestrates one or more Controllers. Owns the domain's lifecycle contract. |
| **Controller** | A leaf control-plane component that operates one specific function (e.g. `opnsense-controller`, `proxmox-controller`). Invoked by the Manager; not exposed to end-users. Corresponds to a Function in ArchiMate terms. `kind` is the field a Manager reads to choose one (ADR-022d §1). |

> The **Stack-promotion rule** ("promote to Stack only on genuine ≥2-Module aggregation — not runtime
> coordination") moved to **ADR-007f** (ADR-022c D5). It is a rule, not a term, and this file holds
> vocabulary.

## D. Component naming decisions

The coordinate for a capability is **`<module>:<service>`** — the middle level is a *function
exposed as a service* (per the metamodel; `module-fields.json` `provides` defines the
services), never the kind of product behind it.

| Decision | Record |
|----------|--------|
| **`firewall` module → `network`** | The OPNsense module was renamed `network` in the ADR-007 refactor. The name under-described the implementation (an NGFW/UTM-class component also doing routing, DNS, DHCP, proxy), and `network` names the *function domain* rather than one product capability. |
| **No rename to `gateway`** | Considered and rejected (2026-05-31). |
| **`firewall:firewall` is gone** | The self-named coordinate was the symptom. Firewall pass rules are simply **`network:rules`**; the other services follow the same pattern (`network:proxy`, `network:dns`, `network:nat`, `network:discovery`). *(Cleanup candidates: `network.json` `provides` still lists a legacy `firewall` service, and deconz still depends on `firewall:*` names.)* |
| **Kind-of-component vocabulary** | Classifying *what the implementation is* (NGFW, reverse proxy, IdP…) is descriptive prose for READMEs/DESIGN docs — it never enters the coordinate. |

## E. What changed, 2026-09-17 (ADR-022a–h)

For review. Each row is a word whose meaning moved, so reading from memory will mislead.

| Was | Now | Rib |
|---|---|---|
| `module.tier` = `foundation` \| `app` | **`scope`** = `site` \| `environment` | 022e D1 |
| `tier` (two meanings) | **`zone.tier` only** | 022c D5, 022e D7 |
| `kind: host` | **`kind: machine`**; *Host* is the role it fills | 022f D2 |
| `kind: app` (proposed) | **`kind: application`** | 022f D3 |
| `external` as status / placement / kind | **`external` = outside the Administrative Domain**, nothing else; management is `managed` \| `unmanaged` | 022g D2, D3 |
| **Node** = the physical Proxmox host | **Node** = ArchiMate's meaning; the narrow sense is **cluster member** | 022c D1, D2 |
| Module boundary = VM boundary | a module need not be a VM | 022d |
| Stack-promotion rule lived here | moved to ADR-007f | 022c D5 |
| `kind: module` — ADR-007's marker that a config is a module | **retired**: `kind` names the workload, discovery is shape-based (migration 0004) | 022d, #611 |

**Still open, not glossary decisions:** `oci` and the grouping concepts `cluster` / `kubernetes`
(ADR-022d, deferred to their own ADR); whether a consumed PBS is a `device` or an `application` with
`management: unmanaged` (ADR-012 §0 argues the latter and amends ADR-022f D6 — Erik to confirm);
and how a dependency coordinate `<module>:<service>` names one instance when a Module has several
(ADR-026 D6a — the instance/module distinction itself is settled by ADR-026 D6).

> All terms here are **TAPPaaS-native**. Other organisations that consume this ontology map it via a
> one-way crosswalk maintained on **their** side — never in this repository.
