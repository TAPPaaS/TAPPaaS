# ADR-039 — Module alerting: a module ships alert rules over its own logs

| | |
|---|---|
| **Status** | **Proposed** |
| **Version** | 0.4 |
| **Date** | 2026-10-29 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | #904 (logging: module-supplied alert rules). Raised for @AndreasJe's hosting module. Builds on #126 (alerting from the logs), #770 / #903 (journal shipping, now NixOS, Debian and containers), #165 §1 (per-host push credentials) and #883 (the alert mail). |
| **Changelog** | v0.4 (2026-10-29) — **`{lines}` decided (operator, option d):** foundation rules may put matching log lines in the mail; a Community module's only where the site opted in (`site.json` `alerts.includeLines`, default false) — D7. · v0.3 (2026-10-29) — **operator's review of D6:** DiskErrors and LanLegDown go to `pvehost` (the node's own hardware), FirewallCertChanged to `network`, HaStuck to `cluster`. A rule's owner is not always the host that logs it (the mothership logs the firewall's and the cluster's checks), so D2's scope names **modules** instead of `nodes`. The firewall and the nodes declare `logging:logs` too (D9), which gives HostSilent its list. The backup buddy's pulse stays outside Grafana (D6). `{lines}` elaborated (open question 2). · v0.2 (2026-10-29) — **operator's answers folded in:** recipients stay `site.json`'s (D3); the foundation's own rules move into module files, and converting them is the test of the format (D6) — which adds label capture, a per-rule repeat, a node scope and a foundation-only escape hatch to D1/D2; the mail is specified in the rule, with today's mail as the default template and the converted rules tested against today's mails (D7); open alerts can be read per module, machine and cluster (D8). Metrics are a separate ADR to write. The deleted-host question is answered by D4 (no false alert). · v0.1 (2026-10-29) — first draft. |

A module may ship alert rules over its own logs. The module says *which lines* matter and how the
mail reads; the platform builds the query, limits it to the module's own hosts, provisions it in
Grafana, mails it through the existing receiver, and can list what is open. A module cannot alert
on, or read, another module's logs. The foundation's own rules move into the same files.

## Context

**Alerting is a fixed list in foundation.** `logging/logging.nix` defines `alertRules`
(QuorumLost, HostSilent, OomKill, …): LogQL counts over Loki, provisioned into Grafana at the
logging VM's build, posted to `tappaas-alert-receiver` on the mothership, which mails through
`site-notify.sh` (`[TAPPaaS <site>] ALERT: <rule> on <host>`). Each rule carries a `kind`
(`event`: a resolve is not news; `state`: its resolve is mailed). Adding a rule means editing
`logging.nix` and rebuilding the logging VM.

**A module knows its own failure lines; the platform does not.** Hosting logs, under one tag,
events an operator must hear about: a release whose signature was rejected, an automatic
rollback, a site agent whose heartbeat stopped, a package snapshot out of date. Today these sit
in Loki until someone looks, or an operator adds a Grafana alert by hand, which the next rebuild
of the logging VM does not know about.

**What makes it safe to let a module in.** Every journal line's `host` label is set on the
logging VM from the push credential that delivered it (#165 §1): a guest can write only as
itself. So a query that selects `host` from a list the platform computes reads only that list's
lines, whatever else the module puts in the rule. (Syslog from the nodes and the firewall,
`source=proxmox|opnsense`, is labelled by its sender and is not authenticated; only foundation
modules may select it, D2.)

**The core rules need more than v0.1's format.** Read rule by rule, today's list uses:

| Rule | Lines from | Needs |
|---|---|---|
| QuorumLost, HaFencing, RootKeyChanged | node syslog | a count |
| ReplicationFailed | node syslog | a label from the line (`replication_job`), `> 1` |
| LanLegDown | node syslog | a label from the line (`slave`), down minus up per leg |
| DiskErrors | node syslog | a 24 h window, mailed once a day |
| BackupFailed | node syslog | a count — but the backup module's event, logged by the nodes |
| HaStuck, FirewallCertChanged | the mothership's journal | a unit, a label from the line (`ha_stuck`) |
| OomKill | every host | a count over all hosts |
| HostSilent | every host | the absent form |
| Heartbeat | every host | kind `heartbeat`, never mailed |

Six of them carry a support bundle (`bundle`), two a `headline`.

## Decision

### D1 — A module ships `<module>-alerts.json` next to its module JSON

```json
{
  "rules": [
    {
      "name": "signature-rejected",
      "title": "Release signature rejected",
      "kind": "event",
      "match": "tappaas-site: signature rejected",
      "capture": { "site": "site=(?P<site>[a-z0-9-]+)" },
      "window": 300,
      "summary": "A site release was refused because its signature did not verify. The site keeps its current release."
    },
    {
      "name": "agent-silent",
      "title": "Site agent heartbeat stopped",
      "kind": "state",
      "unit": "tappaas-site-agent\\.service",
      "match": "heartbeat",
      "absent": true,
      "window": 900,
      "summary": "A site agent stopped writing its heartbeat."
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `name` | DNS label; the rule's uid is `<module>-<name>`, so it cannot collide with another module's |
| `title`, `headline` | the alert's name, and how the mail subject names it |
| `kind` | `event` or `state` (the receiver's meaning, unchanged) |
| `match` | an RE2 line filter (`\|~`), at most 512 characters |
| `unit` | optional RE2 over the `unit` label |
| `capture` | optional: labels taken from the line, each an RE2 with one named group of the label's name; the alert is per host and per captured value, and the values reach the mail (D7) |
| `window` | seconds, 60 – 86400 |
| `above` | optional: fire when more than N lines match in the window (default 0) |
| `absent` | optional: fire when **no** line matched in the window, per host in scope (D4) |
| `repeat` | optional: how often a firing alert is mailed again, `1h` – `24h` (default `4h`) |
| `summary` | the explanation in the mail |
| `mail` | optional: the mail's subject and body (D7) |

A Community module does **not** write LogQL, and cannot set `bundle`, `scope` or `expr` (D2).

### D2 — The platform builds the query, from the rule's scope

For a rule of module `m`, with `H` its scope's hosts:

```
sum by (host[, <captures>]) (count_over_time({host=~"^(H1|H2|…)$"[, unit=~"<unit>"]} |~ "<match>" [| regexp "<capture>"]… [<window>s])) > <above>
```

and for `absent`, HostSilent's form over the same selector. The rule's `query` annotation (the
line to paste into Explore) is built the same way.

**Scope.** For every module, `H` is the vmnames of its deployed instances (ADR-026 D6.3),
computed by the mothership from `config/`, each checked as a DNS label.

The module a rule belongs to is not always the one whose host logs the line. The cluster's
quorum and fencing lines are logged by the nodes (`pvehost` instances); the firewall's
certificate check and the cluster's HA check run on the mothership and log there; a failed
backup is logged by the node that ran it. So foundation modules (the same test as
`pinhole.json`'s `fromZones: any`) may also set:

- `"scope": ["<module>", …]` — the hosts of those modules' instances instead of its own:
  `cluster` and `backup` read `["pvehost"]`, `network`'s and `cluster`'s mothership checks
  `["tappaas-cicd"]`;
- `"scope": "all"` — every host that declares `logging:logs` (D9): OomKill, HostSilent;
- `"bundle": true` — attach the support bundle (#883);
- `"expr"` — a LogQL expression as written, for a rule the form above cannot say (LanLegDown's
  down-minus-up). Grafana validates it on apply.

### D3 — Provisioned through Grafana's API, one rule group per module; recipients are the site's

Module rules are not built into the logging VM. The mothership writes them through Grafana's
alerting provisioning API on the logging VM (over SSH, to `localhost:3000`, with the admin
credential that never leaves that VM):

- folder `TAPPaaS modules`, one rule group `module-<m>` per module, evaluated every minute;
- the group is replaced as a whole (PUT), so a rule removed from the file is removed from Grafana;
- labels: `kind`, `module=<m>`, the captured labels, `bundle` where allowed;
- a rule's `repeat` becomes a notification-policy route matched on its `alertname`, as DiskErrors'
  24 h route is today.

**Recipients are `site.json`'s, as today** (operator, 2026-10-29): the contact point stays the one
webhook to `tappaas-alert-receiver`, which mails the site's notify address through
`site-notify.sh`. A module cannot name a recipient of its own.

A rule Grafana refuses (an RE2 or an `expr` that does not compile) fails that module's group with
Grafana's message, as a warning on the module's install or update; its other services go on.

### D4 — When rules are applied and removed; no alert for a deleted host

- **`logging:logs` install and update** of a consumer applies its module's group (after #903's
  client, so the lines exist).
- **An instance added or removed** changes `H`, so the group is re-applied **at once**, in the
  same install or delete.
- **logging's own update** re-applies every module's group, so a rebuilt or restored Grafana
  database gets them back without waiting for each module's next update.
- **No file**: no group. A module that drops its file loses its group at its next update.

*What this settles for `absent` rules.* An absent rule watches each host in its scope and fires
when one goes quiet. A host that is **deleted** also goes quiet. HostSilent today does not know
the difference: its selector is every host that logged in the last hour, so a deleted VM raises
one HostSilent ALERT and, an hour later, a RESOLVED — two mails about something the operator did
on purpose. Because `H` here comes from `config/` and the group is re-applied in the delete
itself, a deleted host leaves the selector before its silence can fire: no mail. (A guest that
is still configured but stopped is not deleted, and does alert — that is the point of the rule.)
When HostSilent becomes the logging module's rule (D6), it gets the same: no mail for a deleted
VM.

### D5 — Validation and limits

- `module-manager validate` and the install check the file: the fields of D1, D2's
  foundation-only fields refused elsewhere, at most 20 rules, names unique, `window` and `repeat`
  in range, `capture` groups named after their label. A file that does not validate is refused on
  install and warned on update (the previous group stays).
- `--blueprint` (ADR-027) checks it at release time for TAPPaaS and Community modules.
- Cost: each rule is one instant Loki query a minute over a few streams; well inside what the
  logging VM already runs.

### D6 — The foundation's rules move into module files (operator, 2026-10-29)

Every rule in today's `alertRules` moves to the module the event belongs to, and converting them
is the format's test: if a core rule cannot be written in D1/D2, the format is not done.

| Module | Rules |
|---|---|
| Module | Rules | Scope (who logs it) |
|---|---|---|
| `pvehost` | DiskErrors (`repeat: 24h`), LanLegDown (`expr`) | its own instances: the node whose disk or bond it is |
| `cluster` | QuorumLost, HaFencing, ReplicationFailed, RootKeyChanged | `["pvehost"]` |
| `cluster` | HaStuck | `["tappaas-cicd"]` (`check-ha-health` runs on the mothership) |
| `network` | FirewallCertChanged | `["tappaas-cicd"]` (`check-firewall-cert` runs on the mothership) |
| `backup` | BackupFailed | `["pvehost"]` (vzdump on the node) |
| `logging` | OomKill, HostSilent | `all` |
| stays in `logging.nix` | Heartbeat | — |

**Not Grafana rules, and they stay that way.** Two checks mail without the log pipeline on
purpose, because they must work when it is down: the backup buddy's **pulse** (ADR-031,
`backup/pulse/pulse.sh` on the backup node: buddies, uplink, firewall, mothership, PBS, mailed
with the node's own `sendmail`), which reports a dark site that cannot report itself; and the
mothership's **alert watchdog** (`tappaas-alert-watchdog`), which mails when Heartbeat stops. They
belong to `backup` and `tappaas-cicd` already. D8 lists their state too (`backup-manager pulse`,
the watchdog's state file), so an operator sees them beside the Grafana alerts.

`logging.nix` then provisions only the contact point, the policy and Heartbeat (which must exist
before any module has applied anything, so the watchdog has its signal). **The test:** before the
rules leave `logging.nix`, a unit test renders each converted rule and compares it with today's
provisioned rule (expression, labels, annotations); live, each converted rule fires once on
hrossen from a `logger` line on the right host and its mail is compared with today's (D7).

### D7 — The mail is specified in the rule, with today's mail as the default

A rule may give `mail.subject` and `mail.body`: templates with `{placeholder}` substitution and
nothing else (no conditions, no loops, no code — a module's text is never run). Placeholders:

| Placeholder | Value |
|---|---|
| `{state}` | `ALERT` or `RESOLVED` |
| `{title}` | `headline`, else `title` |
| `{host}`, `{hosts}` | the host, or the hosts of a grouped mail, comma-separated |
| `{module}` | the rule's module |
| `{label.<name>}` | a captured label (`{label.site}`) |
| `{labels}` | the captured labels as `name value, …` |
| `{summary}` | the rule's summary |
| `{since}`, `{resolved}` | when it started, and when it cleared |
| `{query}` | the Explore query |
| `{lines}` | up to 20 of the matching lines from the window, as Loki has them (already scrubbed of secrets by the client, #903) — limited, see below |

The templates travel as the rule's annotations (`mailSubject`, `mailBody`), so the receiver needs
nothing but the webhook payload; it fetches `{lines}` from Loki only when the template uses it.
Without `mail`, the defaults are **today's mail**: subject `{state}: {title} on {hosts}
({labels})`, body `== {title} — {host}`, the labels, `{summary}`, `since:`, the Explore query and
the footer. `site-notify.sh` still puts `[TAPPaaS <site>]` in front, and subjects stay ASCII
(#905). **The test:** `test-alert-receiver.sh` renders every converted core rule with the default
templates and checks the subject and body are byte-for-byte today's.

**Log lines in a mail** (operator, 2026-10-29). A mail leaves the site: through its relay to a
mail provider, perhaps forwarded, and with a bundle meant for `supportEmail`. The client scrubs
secrets, not personal data, and a module's own lines can carry it (a hosting site's visitor
addresses and user agents, login names, e-mail addresses). So:

- a **foundation** module's rule may use `{lines}`: the project reviews what its lines contain;
- a **Community** module's rule may use it too, but the receiver fills it only where the site
  opted in, `site.json` `alerts.includeLines: true` (default false). Otherwise `{lines}` reads
  `(log lines not mailed on this site — see the Explore link)`, and the Explore query, which shows
  the lines inside the site behind the identity gate, is always in the mail;
- the default templates do not use `{lines}`, so no mail carries a log line unless a rule asks
  for it.

The site's privacy notice (#359) says whether this site mails log lines.

### D8 — Open alerts can be read, per module, machine and cluster

Mails are not the only way to see an alert. Grafana's alertmanager holds every firing alert with
its labels; the receiver's `config/alerts.log` holds every mail sent.

- `health-manager alerts [--module <m>] [--host <h>] [--node <n>] [--json]` lists them:
  - **open** — `state` alerts firing now, from Grafana (over SSH to the logging VM, as D3);
  - **recent** — `event` alerts of the last 24 h, from `alerts.log` (an event "fires" only for its
    window, so "open" would hide it within minutes).
- Each alert is placed by its labels: `module` (D3) for module rules; `host` resolved to its
  instance through `config/` (vmname), a node to its `pvehost` instance; a cluster's alerts are its
  nodes' plus the `cluster` module's.
- `health-manager validate` gets an `open-alerts` gate (WARN, never FAIL) naming each open state
  alert, and the console shows them on the module, machine, node and cluster pages.

What an object *is*, and how alerts combine with its other signals into one health status, is not
decided here: it belongs to the health model (ADR-007e), the asset records of ADR-040 (the CMDB
side), and the metrics ADR still to write. This ADR only gives every alert the labels those need.

### D9 — Everything that ships logs declares `logging:logs`, syslog senders too

Today the firewall and the nodes ship by syslog, set up by logging's own `update.sh` (OPNsense's
target on :1514, the nodes' rsyslog forwarder on :1515), and declare nothing: `network.json` and
`pvehost.json` have no `logging:logs`. That is why HostSilent has to watch "every host that logged
in the last hour" instead of a list, and why D8 cannot say which machines are covered.

- `network` and `pvehost` declare `"integratesWith": ["logging:logs"]`, as every NixOS and Debian
  consumer does.
- `logging:logs` learns a third kind of client beside the NixOS fragment and Alloy (#903): a
  **syslog sender**. Its install and update configure the sender (OPNsense's remote target through
  `opnsense-controller`; a node's rsyslog forwarder), its delete removes it. The code moves out of
  logging's `update.sh` into the service.
- The sender's lines are labelled with the instance's **vmname**, as journal lines are: logging's
  Alloy maps the syslog `hostname` to it (today the firewall arrives as `OPNsense.internal`), so a
  rule's host list matches.
- `scope: "all"` (D2) is then exactly "every instance that declares `logging:logs`", and HostSilent
  stops guessing. Syslog stays unauthenticated until the TAPPaaS CA (#787); only foundation rules
  read it (D2).

## Consequences

- A module gets operational alerts with no foundation edit and no logging rebuild; hosting drops
  its "operator adds the alert by hand" step.
- One mechanism for every rule. `logging.nix` keeps the delivery path and the heartbeat; the
  rules live with the modules whose events they are.
- The mail format, the event/state meaning, the node-down folding and the heartbeat watchdog are
  unchanged for the core rules, proven by D6's and D7's tests. A deleted VM no longer mails a
  HostSilent pair (D4).
- Coverage depends on the guest shipping its journal: NixOS, Debian VMs and containers (#903). A
  module that declares alert rules but not `logging:logs` gets a `validate` warning.
- The logging VM's Grafana holds rules the Nix build does not: D4's re-apply on logging's update is
  what makes that safe. Between a fresh logging install and that re-apply only Heartbeat exists.

## Alternatives considered

- **Module writes LogQL; the platform checks the selector.** The issue's proposal. Rejected (D2):
  safe only with a LogQL parser, and every new LogQL feature is a new way around the check. The
  foundation-only `expr` is the exception, for code the project reviews.
- **Generate `alertRules` in `logging.nix` from every module's file.** Rejected: a module's change
  becomes a rebuild of the logging VM, and foundation's build reads Community modules.
- **Grafana file provisioning from a runtime directory.** NixOS builds that directory into the
  store; a second, writable directory needs configuration the module does not offer, and a bad file
  stops Grafana's whole provisioning at start. The API rejects one group and leaves the rest.
- **Per-module recipients.** Rejected by the operator: recipients stay `site.json`'s (D3).
- **A template language with logic** (Jinja, Go templates) for D7. Rejected: a module's text would
  become code run by the receiver; placeholders cover today's mails.

## Open questions

1. **Metrics** (operator, 2026-10-29: explore rolling in Prometheus, in an ADR of its own). This ADR
   covers log lines. The metrics ADR decides what is scraped (node exporter, cAdvisor, module
   exporters) and where it is stored, and then whether D1 gains a metric rule (`source: metrics`)
   beside the log rules. D3's delivery and D8's listing are meant to carry both unchanged.

## Implementation plan

- **P1 — Format and query builder.** The file's schema; a renderer from file + scope to Grafana's
  rule-group JSON; unit tests: the selector is always the computed host list, a hostile `match`
  (quotes, `}`, `|`) stays inside the line filter, uids prefixed, captures, `absent`, `above`,
  `repeat`; foundation-only fields refused elsewhere.
- **P2 — Mail templates.** The receiver renders `mailSubject`/`mailBody` with the placeholders, the
  defaults equal today's mail; `{lines}` from Loki, blanked for a Community rule unless
  `site.json` `alerts.includeLines` is true; `test-alert-receiver.sh` covers every core rule
  byte-for-byte and both `{lines}` cases.
- **P3 — Provisioning.** Apply and remove through the API from `logging:logs` install, update and
  delete, and from logging's `update.sh`; validation in `module-manager validate` and the install.
- **P3b — Syslog senders as `logging:logs` consumers** (D9): `network` and `pvehost` declare it; the
  service configures OPNsense's target and the nodes' rsyslog, logging's Alloy maps syslog
  hostnames to vmnames; HostSilent's list follows.
- **P4 — Convert the core rules** (D6), one module at a time: the comparison test, then the rule
  leaves `logging.nix`. Live on hrossen: each converted rule fired from a `logger` line on the right
  host, its mail compared with today's.
- **P5 — Open alerts** (D8): `health-manager alerts`, the `open-alerts` gate, the console.
- **P6 — Hosting adopts it** (with @AndreasJe); the module template documents the file.

Live test (P3–P5) on hrossen with a scratch module: an `event` rule fires from a `logger` line and
mails; an `absent` rule fires when the line stops; deleting an instance raises nothing; a rule
cannot select another module's host; `health-manager alerts --module` lists the open one. Torn
down after.
