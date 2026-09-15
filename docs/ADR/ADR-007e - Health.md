# ADR-007e — Health (Lens)

| | |
|---|---|
| **Status** | Accepted — **partially implemented** (the observability plane is built; status-badge UI is future) |
| **Version** | 1.3 |
| **Date** | 2026-09-15 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #320, #651 (failed-sweep notice), #126 (Proxmox notifications); **realized by:** the `logging` Module (Loki/Grafana/Promtail) + the read-only `health-manager` |
| **Changelog** | v1.3 (2026-09-15, #651) — adds the **site notification target**: a failure that needs a person is mailed to `site.json` `email` through a Proxmox node's mail system; the failed update sweep is its first user. v1.2 — **as-built (2026-06-30):** the lens is realized by the **`logging` foundation Module** (Loki + Grafana + Promtail + syslog ingest from OPNsense and the PVE nodes) and a **read-only `health-manager`** (inspect/check verbs — no `add/modify/delete`, since a lens owns no entities). The per-artifact status-badge UI remains future work. v1.1 — "bucket" → "classification domain" throughout; Health = lens, not a classification domain (2026-06-17) |

The **🩺 Health** lens. **Not a classification domain** — a cross-cutting *overlay* that shows status on People,
Apps, and Environments.

## Decision

Health is a **lens**, not a fourth classification domain. Observability is folded into each artifact's status badge,
with a single Site-level Health page as the system-wide overview. This keeps the "it just works"
prosumer UX (status on the thing it relates to) while preserving a cross-cutting ops view.

> **As built.** The observability plane is the **`logging`** Module (Grafana dashboards over Loki; Promtail
> + syslog receivers ingest the firewall and every PVE node's journal). The control-plane lens is
> **`health-manager`** — deliberately **read-only** (`inspect`/`check`), with **no** `validate`/`add`/
> `modify`/`delete` verbs, because a lens observes entities it does not own (see the verb-alignment doc).

## Site notification target (v1.3)

Status on a page only helps someone who is looking. A failure that needs a person — first of
all a failed update sweep (#651), which on 2026-09-14 left cluster DNS down for 5.5 hours before
anyone noticed — is **sent** as well as shown.

- **Target:** `site.json` `email`, the site owner's address. It is already there (create-site
  copies it from Proxmox's `root@pam`); nothing new is configured. No address means no notice,
  and the sender says so in its log.
- **Transport:** a Proxmox node's own mail system — the `sendmail` of the postfix that PVE
  uses for its own mail — reached over the operator ssh the managers already use. The cicd has
  no mailer and gets none. Nodes are tried in order until one accepts the message. The sender is
  PVE's configured `email_from` when set.
- **Deliverability is the site's.** A node delivers straight to the recipient's MX unless a
  relay is configured; a node whose outgoing IP has no matching reverse DNS will see some
  providers refuse it. Configure a `relayhost` on the nodes (PVE's documented way) where that
  matters.
- **Every send is recorded**, delivered or not, in `config/update-tappaas.failures`, and a
  notice that no node accepted fails its own systemd unit, so it shows in `systemctl --failed`.
- **Reuse:** #126 (Proxmox's own notifications) and later alerting send through the same target
  rather than growing their own.

## How it surfaces

| Where | Example |
|-------|---------|
| next to an **App** | 🟢 service responding, recent backup OK |
| next to an **Environment** | 🟡 one node degraded, others fine |
| next to a **User** | 🔴 MFA expired |
| Site-level Health page | system-wide overview (the only dedicated Health UI page) |

## Why a lens, not a classification domain

A module that *observes everything* cannot be MECE-assigned to a single classification domain. Modeling Health as a
classification domain would break ADR-007's "exactly one classification domain per artifact" invariant. As a lens it
overlays all three classification domains without partitioning them. Industry: Health is universally tracked but
variably positioned — TAPPaaS chooses *lens* over *classification domain* for prosumer UX. Evidence:
[ADR-007 Appendix A.1](<ADR-007 - TAPPaaS Taxonomy.md#appendix-a-industry-evidence>).

## Acceptance

- [ ] Status badges defined for App / Environment / User.
- [ ] One Site-level Health overview page in the UI mockup.
