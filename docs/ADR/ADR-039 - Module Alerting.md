# ADR-039 — Module alerting: a module ships alert rules over its own logs

| | |
|---|---|
| **Status** | **Proposed** |
| **Version** | 0.1 |
| **Date** | 2026-10-29 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | #904 (logging: module-supplied alert rules). Raised for @AndreasJe's hosting module. Builds on #126 (alerting from the logs), #770 / #903 (journal shipping, now NixOS, Debian and containers), #165 §1 (per-host push credentials) and #883 (the alert mail). |
| **Changelog** | v0.1 (2026-10-29) — first draft. |

A module may ship alert rules over its own logs. The module says *which lines* matter; the
platform builds the query, limits it to the module's own hosts, provisions it in Grafana beside
the core rules, and mails it through the existing receiver. A module cannot alert on, or read,
another module's logs.

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

**What makes it safe to let a module in.** Every line's `host` label is set on the logging VM
from the push credential that delivered it (#165 §1): a guest can write only as itself. So a
query that selects `host` from a list the platform computes reads only that list's lines,
whatever else the module puts in the rule.

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
| `name` | DNS-label; the rule's uid is `<module>-<name>`, so it cannot collide with a core rule (`tappaas-…`) or another module's |
| `title`, `headline` | as the core rules: the alert's name, and how the mail subject names it |
| `kind` | `event` or `state` (the receiver's meaning, unchanged) |
| `match` | an RE2 line filter (`\|~`), at most 512 characters |
| `unit` | optional RE2 over the `unit` label |
| `window` | seconds, 60 – 86400 |
| `above` | optional: fire when more than N lines match in the window (default 0) |
| `absent` | optional: fire when **no** line matched in the window, per host that logged at all in the hour before (HostSilent's shape) |
| `summary` | the mail's explanation |

Nothing else. In particular a module does **not** write LogQL.

### D2 — The platform builds the query, from the module's own hosts

For a rule of module `m`, with `H` = the vmnames of every deployed instance of `m`:

```
sum by (host) (count_over_time({host=~"^(H1|H2|…)$"[, unit=~"<unit>"]} |~ "<match>" [<window>s])) > <above>
```

and for `absent`, the HostSilent form over the same selector. `H` is computed by the mothership
from `config/` (instances whose module is `m`, ADR-026 D6.3), each name checked as a DNS label.
The rule's `query` annotation (the line to paste into Explore) is built the same way.

Because the selector is the platform's and `host` is set from the push credential, a rule can
only count lines its own guests wrote. Validating module-written LogQL instead would mean parsing
it, and a selector can be widened in ways a regex check misses (`or`, vector matching, a second
stream selector).

### D3 — Provisioned through Grafana's API, one rule group per module

The core rules stay in `logging.nix`. Module rules are not built into the logging VM; the
mothership writes them through Grafana's alerting provisioning API on the logging VM (over SSH,
to `localhost:3000`, with the admin credential that never leaves that VM):

- folder `TAPPaaS modules`, one rule group `module-<m>` per module, evaluated every minute;
- the group is replaced as a whole (PUT), so a rule removed from the file is removed from Grafana;
- labels: `kind`, `module=<m>`; no support bundle (that is the platform's, for platform events);
- the contact point and policy are the core ones: grouped by rule and host, repeated every 4 h.

A rule Grafana refuses (an RE2 that does not compile) fails that module's group with Grafana's
message, as a warning on the module's install or update; the module's other services go on.

### D4 — When rules are applied and removed

- **`logging:logs` install and update** of a consumer applies its module's group (after #903's
  client, so the lines exist). A new instance changes `H`, so it re-applies the group.
- **Consumer delete**: the last instance of `m` gone removes the group; otherwise `H` shrinks.
- **logging's own update** re-applies every module's group, so a rebuilt or restored Grafana
  database gets them back without waiting for each module's next update.
- **No file**: no group. A module that drops its file loses its group at its next update.

### D5 — Validation and limits

- `module-manager validate` and the install check the file: the fields of D1, at most 20 rules,
  names unique, `window` in range. A file that does not validate is refused on install and
  warned on update (the previous group stays).
- `--blueprint` (ADR-027) checks it at release time for TAPPaaS and Community modules.
- Cost: each rule is one instant Loki query a minute over a few streams. Twenty rules for a
  module with a handful of hosts is well inside what the logging VM already runs.

## Consequences

- A module gets operational alerts with no foundation edit and no logging rebuild; hosting drops
  its "operator adds the alert by hand" step.
- The mail format, the event/state meaning, the node-down folding and the heartbeat watchdog are
  unchanged: module alerts arrive through the same receiver as `ALERT: <title> on <host>`.
- Coverage depends on the guest shipping its journal: NixOS, Debian VMs and containers (#903).
  A module whose guest does not ship gets a rule that never fires; `validate` warns when the
  module declares alert rules but not `logging:logs`.
- The logging VM's Grafana holds state the Nix build does not: D4's re-apply on logging's update
  is what makes that safe.

## Alternatives considered

- **Module writes LogQL; the platform checks the selector.** The issue's proposal. Rejected (D2):
  safe only with a LogQL parser, and every new LogQL feature is a new way around the check.
- **Generate `alertRules` in `logging.nix` from every module's file.** Rejected: a module's
  change becomes a rebuild of the logging VM, and foundation's build reads Community modules.
- **Grafana file provisioning from a runtime directory.** Possible (Grafana reads every file in
  its alerting provisioning directory), but NixOS builds that directory into the store; a second,
  writable directory needs a Grafana configuration the module does not offer, and a bad file
  stops Grafana's whole provisioning at start. The API rejects one group and leaves the rest.
- **Each module runs its own alerting.** What hosting would do otherwise: a second mail path,
  without the node-down folding or the watchdog.

## Open questions

1. **Recipients.** Every alert goes to the site's notify address today. Should a module's rules
   be able to name a second recipient (the module's maintainer, a site's customer), or is that a
   routing rule in `site.json`?
2. **Metrics.** This ADR covers log lines only. A module that exports metrics (Prometheus) is not
   scraped today; alerts over metrics wait for that.
3. **Absent rules and deleted hosts.** HostSilent alerts once for a deleted host and clears after
   the hour. Is the same acceptable for `absent` module rules, or should D4's group update on
   delete suppress it?

## Implementation plan

- **P1 — Format and query builder.** The file's schema; a renderer from file + `H` to Grafana's
  rule-group JSON (bash and jq, in `lib/log-shipping.sh` or a sibling); unit tests: the selector
  is always the computed host list, a hostile `match` (quotes, `}`, `|`) stays inside the line
  filter, uids prefixed, `absent` and `above` forms.
- **P2 — Provisioning.** Apply and remove through the API from `logging:logs` install, update and
  delete, and from logging's `update.sh`; validation in `module-manager validate` and the install
  check.
- **P3 — Live test on hrossen.** A scratch module with one `event` and one `absent` rule: a
  `logger` line in its guest fires the event rule and mails; stopping its line raises the absent
  rule; a rule selecting another host cannot be written; delete removes the group. Teardown after.
- **P4 — Hosting adopts it** (with @AndreasJe), and the module template documents the file.
