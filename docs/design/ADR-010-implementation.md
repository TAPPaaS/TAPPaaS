# ADR-010 Implementation — Plan, Decisions & Tracker

**Companion to:** [ADR-010 — VPS Satellite for Reverse Proxy and Backup](../ADR/ADR-010-vps-satellite-reverse-proxy-backup.md) (the *why* + the decided design)
**Purpose of this doc:** a single place that (1) records **implementation-level decisions**, (2) breaks the work into **packages** with deliverables/dependencies/test-criteria, and (3) **tracks live execution state** — status, tests, commits — per stage.
**Status:** Planning (ADR still `draft`; no stage started)
**Branch:** `ADR010`, **off `ADR007`** (not `main`) — see [Relationship to ADR-007](#relationship-to-adr-007--build-sequencing)
**Started:** 2026-06-30

> Modeled on the ADR-007 design docs ([implementation plan](ADR-007-implementation.md) + [tracker](ADR-007-implementation-tracker.md)), collapsed into **one** document because ADR-010 is a single, self-contained capability rather than a multi-ADR taxonomy.

---

## How to read this doc

- **[Decisions log](#decisions-log)** — every decision that constrains the build, with a pointer to the ADR section that made it. Add a row when a new implementation choice is settled; never silently contradict the ADR.
- **[Implementation packages](#implementation-packages)** — P1…P7, the *what* of each stage (deliverables + test criteria).
- **[Stage tracker](#stage-tracker)** — live execution state; the row is **not done** until it passes the gate below.
- **[Open questions](#open-questions)** — the mechanical leftovers (ports, MTU, sizing) still to settle.
- **[Stage logs](#stage-logs)** — append-only narrative per stage.

### Convention: `config/` means the target system, not the repo

As in ADR-007: `config/satellite.json`, `config/network/zones.json`, etc. refer to **`~tappaas/config/` on the target** (`tappaas-cicd`), operator/runtime state — **not** files committed to the repo. The repository ships only **schemas**, **scaffolding/templates**, and **test fixtures**.

### Stage gate (Definition of Done)

A stage is done only when:

1. **Plan** — decompose the stage; identify the `test.sh` in scope (existing + new); list issues it closes.
2. **Implement** — specialist agents per CLAUDE.md routing (architect / nix-dev / bash-dev / typescript-dev / infra / tester / security).
3. **Validate** — `bash-script-validator` (ShellCheck + security) on every changed script; `tsc --noEmit` on changed TS; `nixos-rebuild test` before `switch` for non-trivial nix.
4. **Deep test** — run existing + new `test.sh` (deep/regression mode), backgrounded per the long-task rules. Record pass/fail.
5. **Gate** — ALL green → commit (`Closes #NNN`) → push. ANY red → stop-the-line, log here, fix, re-test. Do **not** advance.

> Unlike ADR-007 there is **no automated stage-gate driver skill** for ADR-010 (yet). Stages are operator-driven; a driver can be added if the build grows.

**Status legend:** ⬜ not started · 🟦 in progress · 🧪 testing · ✅ done (green, committed, pushed) · 🟥 blocked/red

---

## Relationship to ADR-007 & build sequencing

**Decision (2026-06-30): implement ADR-010 on a branch off `ADR007`, not in parallel on `main`.**

ADR-007 is a foundation-wide overhaul that **rewrites exactly the surfaces ADR-010 integrates with**. The cluster-side pieces ADR-010 needs exist **only on ADR007**:

| ADR-010 touch-point | On `main` (pre-ADR007) | On `ADR007` (the target world) |
|---------------------|------------------------|--------------------------------|
| Zone definitions + orchestration | `firewall/zones.json` + `zone-controller` (scripts) | **`network-manager`** (TS) owns `zones.json`; `zones-init/merge/check/distribute`, 4-plane `reconcile` (ADR-008) |
| Firewall/OPNsense module | `firewall` module | renamed **`network`** module (+ `migrate-firewall-to-network.sh`) |
| `satellite-manager` home | ad-hoc script | from **`manager/TEMPLATE`**, manager/controller contract |
| Backup integration (P6) | `backup-manage.sh` | **`backup-manager` + `backup-controller`** |
| Site/env model, `dns-manager`, install flow | `configuration.json`, old flow | `site.json` + `config/environments/`, `foundation/install.sh` orchestrator |

Building on `main` would mean coding against structure ADR-007 deletes/renames → **guaranteed rework** and a brutal 3-way merge later. Building on `ADR007` fits the final structure and merges cleanly.

**The test-system upgrade is a prerequisite, not extra cost.** The one live `main` system that needs satellite work also needs upgrading to ADR-007 regardless (operator-stated). Sequence: **upgrade the test system to ADR-007 (`migrate-to-adr007.sh`, see the [migration runbook](ADR-007-migration-runbook.md)) → then test ADR-010 on it.**

**De-risking the in-flight base** (ADR-007 not yet merged; a parallel session is moving it):

1. **Additive-only** — new `src/foundation/satellite/`, new `satellite-manager` (from `manager/TEMPLATE`), new `edge`/`admin` zones. Additions barely collide with ADR-007's renames.
2. **Satellite-side artifacts first** — `satellite.nix`, nginx `stream`, wg config, PBS pull, `nixos-anywhere`. These describe a standalone external node and are **branch-agnostic**, so the bulk of the work doesn't wait on ADR-007 settling. (Maps to packages **P3–P6 satellite half**.)
3. **Touch shared files via verbs, not edits** — add zones through `network-manager` `zones-merge`/lifecycle; reconcile firewall via the ADR-008 `opnsense` provider; never hand-edit `zones.json` or call retired scripts.
4. **Coordinate the two genuinely-shared surfaces** with the parallel ADR-007 session: `zones.json` (P1) and `backup-manager`/`backup-controller` (P6 ⇄ ADR-007 S9).

**If forced parallel** (satellite needed before the test system's ADR-007 upgrade lands): keep everything additive, adopt ADR-007 **names/verbs now** (`network`, `dns-manager`, `zone-manager reconcile`), and maintain the touch-point table above as the explicit re-fit checklist — but accept that `satellite-manager` (script → TS-from-TEMPLATE) and the backup glue (`backup-manage.sh` → `backup-manager`) would still need porting.

---

## Decisions log

Decisions already made in the ADR (the build must honour these). Implementation-level decisions get appended here with a date.

| # | Decision | Source |
|---|----------|--------|
| D1 | **TLS passthrough** — satellite never terminates TLS; SNI/host routing stays on Caddy-at-home. Terminate-at-satellite parked. | [ADR §2](../ADR/ADR-010-vps-satellite-reverse-proxy-backup.md) |
| D2 | **WireGuard infra tunnel; home dials out, satellite listens** (PersistentKeepalive ~25s) — solves CGNAT via outbound UDP. | ADR §4.1–4.2 |
| D3 | **Dedicated `edge` overlay zone** (modeled on `netbird`: `Overlay`/`Manual`/`vlantag 0`); least-privilege, role-gated firewall. | ADR §4.3 |
| D4 | **Tunnel subnet `/31`**, dedicated `10.255.0.0/31` slice; satellite `AllowedIPs` scoped to cluster ingress only. | ADR §4.4.1 |
| D5 | **Public ports:** `:443/tcp` passthrough; `:80/tcp` passthrough → **Caddy issues the redirect** (free HTTP-01 fallback). | ADR §4.4.2 |
| D6 | **WireGuard UDP port** default `51820`, **configurable** (`wgPort`); `443/udp` documented fallback for hostile egress. | ADR §4.4.3 |
| D7 | **DNS** automated via existing DNS-01 creds; **existing split-horizon kept** (no hairpin); **no IPv6 in v1**. | ADR §4.4.4 |
| D8 | **Backup = off-site PBS pull** — satellite pulls home, `--remove-vanished false`, **client-side encryption key stays home**, opt-in role. | ADR §3 |
| D9 | **admin-vpn = WireGuard terminating on OPNsense** (`admin` overlay zone → mgmt); satellite is a **blind UDP relay** (Option B). WG-hub rejected. SSH-only passthrough kept as a minimal sub-mode. | ADR §6 |
| D10 | **Provisioning = NixOS via `nixos-anywhere`**; Hetzner **Tier A (portal allocate) = default**, Tier B (`hcloud` API token) opt-in. | ADR §5.3 |
| D11 | **Optional foundation module `src/foundation/satellite/`** (named, not numbered — ADR-007 retired the `NN-name` scheme; apps/-module placement rejected). | ADR §5.7 |
| D12 | **Passthrough forwarder = nginx `stream`** (HAProxy alt; Caddy-l4/Traefik rejected). **PROXY protocol v2 required** to preserve client IP for ADR-005 ACLs. | ADR §5.8 |
| D13 | **Compromise isolation, applied uniformly to every satellite:** no standing cicd root; ephemeral provisioning credential; pull-based signed `autoUpgrade`; one-directional management over the tunnel; immutable history (S3 Object Lock / ZFS snapshots); Hetzner token never standing. | ADR §7.3 |
| D14 | **Roles** are independent (`reverse-proxy`, `admin-vpn`, `backup`) selected in `satellite.json`; a node may carry any combination; multiple satellites allowed. | ADR §1, §3.4 |
| D15 | **Build on a branch off `ADR007`**, not parallel on `main`; satellite-side artifacts kept branch-agnostic; test system upgraded to ADR-007 first. | [Relationship to ADR-007](#relationship-to-adr-007--build-sequencing) (2026-06-30) |
| D16 | **Backup storage backend = S3 object storage by default** (Hetzner Object Storage, PBS 4.2+), dedicated block volume the alternative; **immutability via S3 Object Lock** (bucket created with lock enabled) — stronger than ZFS snapshots. | ADR §3.4, §7.3 (2026-06-30) |
| D17 | **Satellite ships `README.md` + `INSTALL.md`**; the TAPPaaS install **conditionally references** `satellite/INSTALL.md` at the "does this site need a satellite?" decision point — never part of the mandatory chain. | ADR §5.9 (2026-06-30) |
| D18 | **Q1 resolved:** `wgPort`/`adminWgPort`/`sshPort` default `51820`/`51821`/`22`, all configurable; ship the `443/udp` fallback config. **Q2 resolved:** admin-WG MTU `1340`, tunable. | Open questions (2026-06-30) |

---

## Implementation packages

### Package dependency graph

```
            ┌────────────────────────────┐
            │ P1: Foundation & schema    │  satellite/ scaffolding,
            │ (module, zones, fw rules)  │  edge + admin zones, schema
            └──────────────┬─────────────┘
                           ▼
            ┌────────────────────────────┐
            │ P2: WireGuard infra tunnel │  os-wireguard peer, /31,
            │                            │  least-priv edge rules
            └──────────────┬─────────────┘
                           ▼
            ┌────────────────────────────┐
            │ P3: Provisioning           │  satellite-manager install,
            │ (nixos-anywhere lifecycle) │  ephemeral cred, autoUpgrade
            └──────┬──────────┬──────────┘
                   │          │          │     (P4 ∥ P5 ∥ P6)
        ┌──────────┘   ┌──────┘    ┌─────┘
        ▼              ▼           ▼
 ┌─────────────┐ ┌────────────┐ ┌──────────────┐
 │ P4: reverse │ │ P5: admin- │ │ P6: backup   │
 │ -proxy role │ │ vpn role   │ │ role         │
 └──────┬──────┘ └─────┬──────┘ └──────┬───────┘
        └──────────────┼───────────────┘
                       ▼
            ┌────────────────────────────┐
            │ P7: Hardening & docs       │  one-directional fw,
            │ (compromise-isolation,     │  runbook + DR drill,
            │  runbook, decommission)    │  decommission path
            └────────────────────────────┘
```

**Suggested sequence:** P1 → P2 → P3 → {P4 ∥ P5 ∥ P6} → P7. The three role packages are independent once the node + tunnel exist; do the one(s) you need first (a relay-only satellite is just P1–P4 + P7).

### P1 — Foundation & schema

- Scaffold `src/foundation/satellite/`: `satellite.json` + `satellite.nix`, `satellite-manager`, `install.sh` / `update.sh` / `test.sh` (module contract).
- Add `edge` + `admin` overlay zones to `manager/network-manager/zones.json` and the zones schema; define role-gated firewall entries for the ADR-008 `opnsense` provider (edge → Caddy ingress / OPNsense admin-WG / home PBS:8007 per active role).
- `satellite.json` schema: `provider`, `publicIp`, ssh access, `wgPort`, `adminWgPort`, `sshPort`, tunnel `/31`, fronted domains/SNI, `roles[]`.
- **Test criteria:** schema validates a sample config; `zones-check` green with `edge`+`admin`; firewall rules reconcile (dry-run) with no broad mgmt reach.

### P2 — WireGuard infra tunnel

- OPNsense `os-wireguard` peer: home dials out (`Endpoint = satellite:wgPort`, keepalive 25); `/31` `10.255.0.0/31`; `AllowedIPs` = role endpoints only.
- Satellite WireGuard listener; on-node key generation; pubkey read-back.
- **Test criteria:** handshake comes up; survives a simulated home-WAN IP change (roaming); `443/udp` fallback works on a UDP-restricted egress; least-privilege `edge` rules confirmed (satellite cannot reach mgmt).

### P3 — Provisioning (`satellite-manager`, nixos-anywhere)

- `satellite-manager install <name>`: Tier A (operator supplies IP) default; Tier B (`hcloud` create) opt-in; `nixos-anywhere` kexec deploy; `--copy-host-keys`; ephemeral provisioning credential **revoked post-install**; operator out-of-band key the only standing access; pull-based `autoUpgrade` (pinned/signed ref).
- `update` (pull-based) and `decommission` (revert tunnel/zone/DNS; Tier B `hcloud delete`).
- **Test criteria:** install → update → decommission clean on a real VPS; provisioning credential confirmed revoked; poisoned/unsigned config ref rejected.

### P4 — reverse-proxy role

- nginx `stream` passthrough (`:443`/`:80`) with **PROXY protocol v2**; Caddy-on-OPNsense configured to trust the relayed client IP; `dns-manager` points public records at the satellite.
- **Test criteria (`test.sh`):** public HTTPS → satellite → tunnel → Caddy resolves; **Caddy logs show the real client IP** (ADR-005 zone ACLs still apply); `:80`→`:443` redirect works.

### P5 — admin-vpn role

- OPNsense admin-WG road-warrior listener + `admin` overlay zone → mgmt; satellite blind UDP relay of `adminWgPort`; admin-side MTU tuned for double-encapsulation.
- **Test criteria:** an admin peer reaches node `:8006`, OPNsense UI, PBS `:8007`, and SSH to a host; satellite confirmed unable to decrypt the session.

### P6 — backup role

- PBS datastore backend: **S3 object storage by default** (provision a Hetzner Object Storage bucket **with Object Lock enabled at creation**; configure the PBS S3 endpoint, requires PBS 4.2+) **or** a dedicated block volume with local ZFS (selected in `satellite.json`).
- Register home PBS as a **pull remote** (`--remove-vanished false`, read-only `Datastore.Read` token); client-side encryption at home; reuse #228 verify/prune schedule; tune the Object-Lock retention window vs. PBS prune/GC.
- **Immutability:** S3 Object Lock (retention) on the default backend; local ZFS snapshots on the volume alternative.
- **Test criteria:** pull sync replicates home → satellite (S3 backend); data lands **encrypted**; **restore from satellite** succeeds *with* the key and fails *without* it; a delete/overwrite of a retention-locked object is refused.

### P7 — Hardening & docs

- Satellite **host firewall**: home/tunnel side cannot reach satellite SSH/PBS-admin (one-directional management).
- Compromise-isolation verification (the headline tests, §7.3); operator runbook + **DR drill incl. encryption-key recovery**; decommission path; advance ADR `draft → proposed`.
- **`README.md` + `INSTALL.md`** (D17): module overview/trust model + `satellite.json` reference; detailed install runbook (Tier-A provider prereqs; S3-bucket-with-Object-Lock for backup; `satellite-manager install` flow; role selection; verification; decommission). Add the **conditional reference** from the TAPPaaS install flow at the "does this site need a satellite?" decision point (after `network`/`tappaas-cicd`/`backup` prereqs).
- **Test criteria:** simulated `tappaas-cicd` compromise cannot delete satellite backups, remove immutable history, or destroy the VPS; one-directional management proven; the install-flow reference is present but the satellite step stays non-mandatory.

---

## Stage tracker

Maps 1:1 to the packages. All ⬜ until implementation starts.

| Stage | Delivers | Issues | Depends on | Status | Tests (pass/fail) | Commit | Pushed |
|-------|----------|--------|-----------|--------|-------------------|--------|--------|
| **P1** | Foundation & schema (`satellite/` module, edge+admin zones, fw rules) | TBD | — | 🟦 | fast: mgr 6/0, module 17/0 | 58a1f35.. | ⏳ |
| **P2** | WireGuard infra tunnel | TBD | P1 | ⬜ | — | — | — |
| **P3** | Provisioning (nixos-anywhere, lifecycle) | TBD | P1, P2 | ⬜ | — | — | — |
| **P4** | reverse-proxy role (nginx stream + PROXY v2) | TBD | P2, P3 | ⬜ | — | — | — |
| **P5** | admin-vpn role (WG via OPNsense, blind relay) | TBD | P2, P3 | ⬜ | — | — | — |
| **P6** | backup role (PBS pull + encryption + S3/Object-Lock) | TBD | P2, P3, **ADR-007 S9** (backup-manager/controller) | ⬜ | — | — | — |
| **P7** | Hardening & docs (isolation, README/INSTALL + install-flow ref, decommission) | TBD | P4, P5, P6 | ⬜ | — | — | — |

> **Issues:** none filed yet — open GitHub issues per package when the branch is cut, and backfill the `Issues` column with `#NNN`.

---

## Open questions

Mechanical leftovers from the ADR. Status: ✅ resolved · ⬜ open.

| Q | Question | Decide in | Status / notes |
|---|----------|-----------|----------------|
| Q1 | `wgPort` / `adminWgPort` / `sshPort` defaults & `443/udp` fallback | P2 / P5 | ✅ **D18** — `51820`/`51821`/`22`, all configurable; ship `443/udp` fallback config. |
| Q2 | Admin-WG **MTU** for the double-encapsulated path | P5 | ✅ **D18** — `1340`, tunable empirically. |
| Q3 | `admin` overlay zone — **new vs. reuse `netbird`** | P1 / P5 | ⬜ **Open (deliberately).** Possibly route admins straight into `mgmt`; or NetBird may be **removed** entirely if `admin-vpn` supersedes it. Revisit once `admin-vpn` is real. |
| Q4 | **Signing mechanism** for pull-based `autoUpgrade` config ref (key off-cluster) | P3 | ⬜ Open — core to D13 rule 3. |
| Q5 | Backup **storage backend** & sizing | P6 | ✅ **D16** — S3 object storage default (Hetzner Object Storage, Object Lock at bucket creation, PBS 4.2+); dedicated volume the alternative. Relay/admin node stays tiny (`cax11`-class). Open sub-tunable: Object-Lock retention window vs. PBS prune/GC. |
| Q6 | Exact `access-to` / `pinhole-allowed-from` entries for `edge`/`admin` | P1 | ⬜ Open — to be determined at implementation, per ADR §4.3 role table. |
| Q7 | Multi-site SNI fan-out (one satellite, several tunnels) | future | ⬜ **Out of scope for v2.** `ssl_preread` reserved; revisit post-v2. |

---

## Stage logs

Append-only narrative per stage (newest first). Template:

```
### Pn — <name> — <status> <date>
- Plan: …
- Implemented: …
- Tests: … (pass/fail)
- Commit/Push: …
- Follow-ups: …
```

### P1 — Foundation & schema — 🟦 in progress — 2026-06-30
- Plan: scaffold the `satellite/` module + `satellite-manager` + schema + the `edge`/`admin` zones, matching the ADR-007 module/manager contract.
- Implemented:
  - `src/foundation/satellite/` — `README.md`, `INSTALL.md`, `satellite.json` (example config), `satellite.nix` (role-gated NixOS skeleton w/ `TODO[P2..P6]`), `install.sh`/`update.sh`/`test.sh`.
  - `src/foundation/schemas/satellite-fields.json` — config field reference.
  - `src/foundation/tappaas-cicd/manager/satellite-manager/` — bash front door (`install`/`update`/`status`/`remove` wired but report not-implemented → P2-P6; `validate` works), component `install/update/test/validate.sh` + `README.md`.
  - `network-manager/zones.json` — `edge` overlay (decided) + `admin` overlay (**provisional, Q3**).
- Tests: satellite-manager fast **6/0**; satellite module fast **17/0**; all scripts `bash -n` clean. (ShellCheck + deep gate run on cicd.)
- Key call: satellite is an **external-host** module — NOT a `cluster:vm`; operator-driven, NOT in `rest-of-foundation.sh`.
- Follow-ups: real verbs (P2-P6); exact `edge`/`admin` `access-to` (Q6); finalise/merge `admin` zone (Q3); `autoUpgrade` signing (Q4); ShellCheck on cicd.

