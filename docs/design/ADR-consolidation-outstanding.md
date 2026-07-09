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

Feature issues closed and rolled into a single Release-1.2 gate issue each
(the delivered work is done + live-validated; only hardening/live-validation +
operator sign-off remains, which is what the successor tracks):

| Closed # | Delivered | Successor gate (Release 1.2, assigned operator) |
|----------|-----------|--------------------------------------------------|
| **#326** reverse proxy in a VPS | ADR-010 P4 reverse-proxy, live-validated | **#406** ADR-010 P7 hardening + sign-off |
| **#325** remote management easy | ADR-010 P5 admin-vpn, live-validated | **#406** |
| **#402** flexible backup on a cluster | ADR-012 P1–P3 live, P4/P7 coded | **#407** ADR-012 live validation + sign-off |
| **#389** remote backup setup | ADR-012 P4–P6/P9 coded, offline-green | **#407** |
| **#382** node backup client not installed | ADR-012 P3 client reconcile, live-verified | **#407** |

Already closed before this pass (referenced by the ADRs, no action needed):
**#227, #228** (010/012 backup foundation), **#333, #334, #335, #339, #372,
#373** (008 zone/switch orchestration), **#320** (007 discussion).

---

## 3. Outstanding — the two Release-1.2 gate issues

The delivered feature issues (§2) are closed; their remaining work is
consolidated into one tracking issue per ADR, both in the **Release 1.2:
Security and stability release** milestone and assigned to the operator.

### #406 — ADR-010 satellite: P7 hardening + compromise-isolation + sign-off

Gate for #326 + #325. Roles P1–P5 done + live-validated; P6 body coded. Remaining:
- One-directional host firewall on the satellite (§7.3 rule 4)
- P6 backup live round-trip + restore-from-off-site (with/without key)
- Compromise-isolation tests (hacked cicd can't delete satellite backups;
  read-only + non-persistent token enforcement)
- Final README/INSTALL, DR drill, decommission path, optional install-flow ref
- Operator sign-off → advance ADR draft → proposed

### #407 — ADR-012 backup: 3-node live validation + compromise-isolation + sign-off

Gate for #402 + #389 + #382. P1–P3 live; P4–P9 coded/offline-green. Remaining:
- Live push test (write-no-delete to remote PBS)
- Subset + immutability live tests (group-filter + ZFS-snapshot immutability)
- Compromise-isolation suite (6 scenarios incl. restore with/without key)
- Confirm `node add` installs the backup client on the new node (#382 loop)
- Operator sign-off → advance ADR draft → proposed

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

1. **#406 (ADR-010 P7)** — hardening + compromise-isolation tests + sign-off;
   the last gate for the satellite (advances ADR draft → proposed).
2. **#407 (ADR-012 live suite)** — 3-node push/immutability/restore +
   compromise-isolation tests + node-add backup-client check; advances ADR
   draft → proposed.
3. **Operator judgment on #365 / #364 / #318 / #319** — decide per §4.
4. **Documentation backlog (§5)** — schedule the `docs(adr-007)` write-ups when
   convenient; they gate nothing.
