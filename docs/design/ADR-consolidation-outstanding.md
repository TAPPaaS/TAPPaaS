# ADR Consolidation — Outstanding Work Across ADR-007 / 008 / 010 / 012

**Compiled:** 2026-07-09 (branch `ADR007`, HEAD `0359d35`).
**Scope:** the four "more or less implemented" ADRs. This is the single
consolidated view of what remains and which GitHub issues block closing what.
Method: four parallel audits of each ADR + its implementation/tracker docs,
cross-referenced against git history and the live GitHub issue set.

Per-ADR detail lives in the individual trackers
([ADR-007 post-refactor](ADR007-post-implement-refactor.md),
[ADR-007 impl tracker](ADR-007-implementation-tracker.md),
[ADR-010 impl](ADR-010-implementation.md),
[ADR-012 impl](ADR-012-implementation.md),
[node-provisioning](node-provisioning.md)). This doc does not duplicate them —
it consolidates the *outstanding* set and the issue-closure decisions.

---

## 1. Status at a glance

| ADR | Title | Status | Outstanding |
|-----|-------|--------|-------------|
| **007** | TAPPaaS Taxonomy | ✅ Feature-complete, merged + live-verified (fresh install + `update-tappaas --force` clean) | Documented follow-ups only (legacy bash retirement, native TS schema validation, doc consolidation). None blocking. |
| **008** | Network infrastructure / zone orchestration | ✅ Substantially complete, live-verified (network-manager + 4 controllers, 5-verb contract) | Deferred vendor plugins (MikroTik, Meraki); multi-switch cascades WIP; OPNsense binary rename cosmetic. No open issues block it. |
| **010** | VPS satellite (reverse-proxy / admin-vpn / backup) | 🟨 P1–P5 done + live-validated; P6 body done, untested; **P7 not started** | P7 hardening + compromise-isolation tests + final docs + operator sign-off. ADR still *draft*. |
| **012** | Backup enhancement | 🟨 P1–P3 live-verified; P4–P9 coded (offline-green / cicd-verified) | 3-node-cluster live tests (push, subset, immutability, compromise-isolation, restore-with/without-key) + operator sign-off. ADR still *draft*. |

Bottom line: **007 and 008 are done**; **010 and 012 are code-complete but
gated on live validation + operator sign-off**, so their headline issues stay
open until that lands.

---

## 2. Issues closed by this consolidation (truly done + verified)

Closed on GitHub as part of this pass — each had unambiguous, verified
implementation evidence and a tracker "Closes #N" note:

| # | Title | ADR | Evidence |
|---|-------|-----|----------|
| **#56** | Create default user and role profiles | 007 (S2) | `people-manager/minimal-org/roles/{user,admin,root}.json` + `groups/users.json` + default user templates; live-bootstrapped 2026-06-22 (commit `79ef2c6`, `e5bd8c3`). |
| **#313** | introduce timezone in configuration.json | 007 (S3a) | `site.json .location.timezone` is a first-class field with `detect_timezone()` auto-detection in create-site.sh; the configuration.json→site.json migration landed it (commit `52089c9`). |
| **#380** | document and revalidate install sequence | 007 | INSTALL.md + INSTALL-ENVIRONMENT.md revalidated on a fresh hardware install (test4, PVE 9.2) and kept current through the node-provisioning work; `--dns-mode` gap closed. |

Already closed before this pass (referenced by the ADRs, no action needed):
**#227, #228** (010/012 backup foundation), **#333, #334, #335, #339, #372,
#373** (008 zone/switch orchestration), **#320** (007 discussion).

---

## 3. Outstanding — blocked issues, per ADR

Each row: what remains, and the GitHub issue(s) that cannot close until it does.

### ADR-010 — VPS satellite (P7 gate)

| Outstanding work | Blocks issue | Why it can't close yet |
|------------------|--------------|------------------------|
| **P7 hardening**: one-directional host firewall on the satellite (reject inbound SSH/PBS-admin from home/tunnel) | #326, #325 | §7.3 isolation rules not yet enforced in code. |
| **P7 compromise-isolation tests**: prove a hacked cicd can't delete satellite backups; read-only-token + non-persistent-provider-token enforcement | #325, #326 | Decided, not tested live. |
| **P6 backup live round-trip**: satellite pulls home PBS end-to-end; restore-from-off-site (proves key-criticality) | #326 (backup facet) | Body coded (Debian PBS 4.2.2, pull sync) but needs a live home PBS. |
| **P7 final docs + operator sign-off**: README/INSTALL finalize, DR drill, decommission path; advance ADR *draft → proposed* | #326, #325 | ADR-010 explicitly gates closure on operator review after P7. |

- **#326** ("reverse proxy in a VPS") — the reverse-proxy role (P4) is
  implemented and live-validated (external → satellite:80 → tunnel → Caddy 308).
  Do NOT close until P7 hardening + sign-off; land the closing commit with
  `Closes #326`.
- **#325** ("make remote management easy") — the admin-vpn role (P5) is
  implemented and live-validated (admin↔OPNsense handshake through the blind
  satellite relay). Same gate as #326.

### ADR-012 — Backup enhancement (live-test gate)

| Outstanding work | Blocks issue | Why it can't close yet |
|------------------|--------------|------------------------|
| **Live push test**: local cluster pushes VMs to a remote PBS, write-no-delete verified | #402, #389 | P4 offline-green; needs a real remote PBS on a 3-node cluster. |
| **Subset + immutability live tests**: group-filtered replication + ZFS-snapshot immutability on a live ZFS datastore | #389 | P5 offline-green (7/0); live pending. |
| **Compromise-isolation + restore suite** (6 scenarios incl. restore with/without key) | #389, #402 | P9 test plan documented; must run live. |
| **Operator sign-off**: advance ADR *draft → proposed* | #402, #389, #382 | ADR-012 acceptance requires the live suite green. |

- **#402** ("more flexible backup on a cluster") — placement policy + shim
  promotion + client reconcile (P1–P3) are live-verified on tappaas1; the
  push/endpoint-agnostic paths (P4/P7) are coded but need live cluster tests.
- **#389** ("remote backup setup") — remote/push/immutability bodies coded and
  offline-green; blocked on the live compromise-isolation + restore tests.
- **#382** ("adding a node does not install backup client") — the per-node
  client reconcile (P3) is **live-verified**; this is the closest to closable.
  Recommend closing it *with* the node-provisioning `node add` flow, once
  confirmed that a `node add` run installs the backup client on the new node
  (the reconcile exists; the node-add integration is the last check).

### ADR-007 / 008 — non-blocking follow-ups (no issue gates completion)

- Legacy bash retirement (Phase 7), native TS JSON-schema validation, deferred
  health sub-ports, SSO cosmetic cleanup, configuration.json phase-D deletion,
  firewall→network hostname full switch. All documented in the 007 trackers;
  none block any issue.
- ADR-008 deferred vendor plugins (MikroTik #—, Meraki #—) and multi-switch
  cascades: not tracked by open issues; future work.

---

## 4. Referenced issues needing operator judgment (NOT closed)

These are implemented, but under a different name or technology than the issue
title states — so "truly closed" is an operator call, not an automatic one:

| # | Title | What was delivered | The judgment |
|---|-------|--------------------|--------------|
| **#365** | control-plane: implement **Python** managers per classification domain | Managers delivered in **TypeScript** (module/site/environment/backup/health/people/network); controllers in Python (opnsense/identity). A TS-first decision superseded "Python managers". | Close if "managers per domain" was the intent; keep open if Python specifically was required. |
| **#364** | control-plane: extract **caddy-controller and authentik-controller** | authentik-controller extracted as **identity-controller**; caddy folded into **opnsense-ensure-patches** (a verb, not a standalone controller). | Close if the extraction intent is satisfied by the current naming; keep open if the specific component names matter. |
| **#318** | rename "variant" to something more descriptive | Code renamed **variant → environment** (environment-manager, environments/). | Close if the rename is what was wanted; check for residual "variant" terminology first. |
| **#319** | delete zones that can be managed but variants/client | **Decided as a no-op** (2026-06-23): already-installed modules stay in their zones; the occupancy guard keeps zones Active. Legacy-zone sunset deferred. | Close as "won't do / resolved by design decision". |

---

## 5. Documentation follow-ups (open, out of code scope)

`docs(adr-007)` issues that are documentation tasks, not code — the code they
describe is implemented; the write-ups remain: **#356** (source: local intent),
**#357** (update scheduling), **#358** (backup cross-level cascade), **#359**
(legal/processor cross-cutting), **#360** (v2 review summary), plus the
cross-ADR **#362** (documentation structure/standards), **#363** (module
lifecycle blueprint). None block ADR-007/008/010/012 completion; they are the
documentation backlog.

---

## 6. Recommended next actions

1. **ADR-012 #382** — verify a `node add` run installs the backup client on the
   new node; if so, close #382 (its reconcile is already live-verified). This is
   the single closest-to-done issue.
2. **ADR-010 P7** — the last gate for #326 + #325; schedule the hardening +
   compromise-isolation tests, then close both with `Closes #` commits.
3. **ADR-012 live suite** — run the 3-node compromise-isolation + restore tests;
   green unblocks #402 + #389 and moves the ADR draft → proposed.
4. **Operator judgment on #365 / #364 / #318 / #319** — decide per §4.
5. **Documentation backlog (§5)** — schedule the `docs(adr-007)` write-ups when
   convenient; they gate nothing.
