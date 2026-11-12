# ADR-046 — Performance Monitoring

| | |
|---|---|
| **Status** | **Proposed** (every open question closed, 2026-11-10; P1–P6 built, live-tested on the test site and merged to `main` 2026-11-11, not yet released) |
| **Version** | 0.4 |
| **Date** | 2026-11-10 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Closes / addresses** | #927 (performance monitoring). Answers ADR-039 open question 1 (metrics, and whether a rule gains `source: metrics`). Fills ADR-040 D14's "metrics and traces are not collected today". Amends ADR-041 D1 (a `performance` condition type) and D3 (shipped rules for it). Related: ADR-007e (health as a lens), ADR-020 (declared fields), ADR-034 (console; Grafana kept for dashboards, A4), ADR-043 (internal CA), ADR-044 (site sizes), the logging module's v2 backlog ("no Prometheus yet"). |
| **Changelog** | v0.4 (2026-11-11) — **from P2–P6's live tests:** every timed raise names `--until`, the raise in force is an `investigation` attribute, `perf purge` (D3); a level change is the module's converge with no new generation (D3); Caddy's numbers are scraped by the mothership from a mgmt listener on the firewall, status codes as classes, labelled with the proxy route (D1, D2); the mothership is the one sender that names another CI, pools carry their node's identity (D4.1); change markers come from the CMDB in the console, Grafana annotations to follow (D4.2); generated module dashboards, `traces.otlp` only where emitted (D5); measured cost (D3); an *Implementation status* section with the known gaps (Caddy and authentik cannot emit traces yet). · v0.3 (2026-11-10) — **from P1's live test on hrossen:** guests push OTLP, not `remote_write` (only OTLP shows the receiver who authenticated); identity labels come from the authenticated user and a CMDB identity map on the logging VM (D1, D4); the Proxmox cluster pushes with one credential, its node label trusted only among CMDB nodes (D1); PVE 9.2 uses its OpenTelemetry metric server, PBS 4.2 InfluxDB HTTP; `site.json` accepts `off`, `basic` and `service` only (O4). Measured at `basic` on 3 nodes and 22 guests: ~1.9 k series, ~190 MB RAM for both Prometheus instances. PVE pushes every 10 s; thinning to the level's resolution is open until Alloy's processor is stable. · v0.2 (2026-11-10) — **every open question closed, and a Performance menu (operator):** D7 makes the console part of the solution: a Performance menu under Health with Overview, Browse, Levels and Investigations. O1 Prometheus; O2 `small` defaults to `off`; O3 the level is a module's declared field, the timed raise a health-manager verb, logging only renders; O4 `fine` may be standing, `trace` is timed only; O5 Proxmox and PBS push from the nodes, the API pull only as fallback; O6 static thresholds first; O7 Alloy's pipeline is a runtime file, no OS rebuild per level change; O8 foundation modules first. D1–D6 and the plan carry the answers; 90-day trends go to a second small Prometheus. · v0.1 (2026-11-10) — first draft, from the operator's direction of 2026-11-10: complement event-based health (operations and security events, CMDB associations, root cause and impact) with performance monitoring; decide what is realistic to monitor, how it is turned on and off, and how its level is set; tie it to traceability. |

TAPPaaS knows **whether** something is wrong: ADR-039 turns log lines into alerts, ADR-041 turns
every check into a condition on a CMDB object, derives root causes along the relations and mails
only the cause. It does not know **how well** anything runs. Nobody can say that Nextcloud's
pages got twice as slow after the last release, that `tanka1` has had 40 ms write latency every
night since the backup buddy started pulling, or that a guest has been CPU-starved for a week
without ever crossing a "down" threshold. Those are performance questions: they are answered by
numbers over time, not by events. This ADR decides which numbers TAPPaaS collects, at what cost,
how an operator switches them on, off and up, and how each number traces back to the CI, the
change and the release it belongs to.

## Context

### What exists today

| Piece | What it gives performance monitoring |
|---|---|
| **Loki** on the logging VM (30-day retention) | Logs only. Some numbers already travel as log lines: `tappaas-guest-memory` (every node, once a minute, one logfmt line per guest: working set, PSI, OOM kills, swap) is a metric shipped as a log, and `guest-memory-report.sh` turns a window of it into module memory defaults (ADR-044). It works, and it shows the gap: there is no store built for numbers. |
| **Grafana Alloy** on every NixOS guest and on the logging VM | An OpenTelemetry collector with a built-in host exporter (`prometheus.exporter.unix`), Prometheus scraping, `remote_write`, OTLP in and out. It already pushes each guest's journal with a per-VM credential (`logging:logs`, ADR-039 D9). Switching on metrics is configuration, not a new agent. |
| **Grafana** | Dashboards and alert rules (ADR-039). Has data sources for Prometheus and Tempo out of the box. |
| **Proxmox nodes, PBS, OPNsense** | Ship syslog, no Alloy. Proxmox has the numbers (API `/cluster/resources`, per-guest RRD) and an external metric server setting; PBS has the same; OPNsense has an `os-node_exporter` plugin. |
| **health-manager `assess`** (ADR-041) | Judges thresholds over observations in the CMDB into `capacity` conditions (disk, memory commitment, pool usage). A snapshot every 5 minutes; no history beyond the condition's own transitions. |
| **ADR-040 D14** | Every CI has an OpenTelemetry resource identity (`service.instance.id`, `host.id`, `tappaas.ci.id`, …) that Alloy already stamps on log lines. Explicitly reserved for metrics and traces "when they are" collected. |

### Events versus performance

The two complement each other and should not be confused:

| | Event health (ADR-039, ADR-041) | Performance (this ADR) |
|---|---|---|
| Question | Is it broken? Is it exposed? | How well does it run, and is that changing? |
| Data | Log lines, check verdicts, transitions | Numeric time series (and, on request, traces) |
| Output | A condition, a root cause, a mail | A trend, a baseline, a saturation warning, a "slower since" |
| Lives | CMDB attribute history, Loki | A time-series database, short retention, down-sampled |
| Cost | Small and constant | Grows with series × resolution × retention — **must be bounded and switchable** |

Performance feeds event health where a number crosses a line (D6), and event health gives
performance its context (which change, which root cause), but neither replaces the other.

### What the industry does

| Approach | Notes for a site our size |
|---|---|
| **USE** (Brendan Gregg): Utilization, Saturation, Errors per resource | The right lens for nodes, guests, pools, disks, NICs. Saturation (PSI, run queue, I/O wait, disk latency) is what predicts trouble; utilization alone does not. |
| **RED** (Tom Wilkie): Rate, Errors, Duration per service | The right lens for what users touch: a published service's request rate, error ratio and latency. |
| **Four golden signals** (Google SRE): latency, traffic, errors, saturation | USE + RED combined. |
| **Prometheus** (+ node exporter, exporters per app) | The de-facto metrics store; NixOS `services.prometheus`; native OTLP receiver in 3.x; a few hundred MB of RAM at a few tens of thousands of series. |
| **VictoriaMetrics** | Prometheus-compatible, notably lighter on RAM and disk; one binary. |
| **Grafana Mimir / Thanos** | Horizontal scale for many tenants. Far beyond one site. |
| **OpenTelemetry traces + Tempo / Jaeger** | Request-level tracing across services. High value when debugging a slow chain (proxy → identity → app), high cost when left on; sampled in practice. |
| **eBPF auto-instrumentation** (Beyla), continuous profiling (Pyroscope) | Instrumentation without code changes, CPU-level detail. Kernel-sensitive, memory-hungry, young. |
| **Netdata, Zabbix, Checkmk** | Monitoring appliances with their own agents and models — the same objection as ADR-041 A2: a second model of the site beside the CMDB. |

## Decision

### D1 — Performance is a third signal beside logs, carried by the logging module

The logging module provides two new services beside `logging:logs`:

- **`logging:metrics`** — a time-series store on the logging VM (Prometheus, O1), receiving
  pushes over OTLP (guests) and the metric-server protocols of Proxmox and PBS, behind nginx with
  one credential per pushing host, the same pattern as Loki's tcp/3101: a host can write series
  only under its own identity (the identity labels are set from the authenticated user and the
  CMDB, never trusted from the sender), and cannot read or delete. The Proxmox cluster, whose
  metric server is one setting and whose nodes are one trust domain, pushes with one credential;
  its `node` label is trusted only among the nodes the CMDB lists. Over TLS from the internal CA
  (ADR-043).
- **`logging:traces`** — a trace store (Grafana Tempo), installed but **idle** until some CI is at
  level `trace` (D3). Local filesystem storage, short retention.

Everything that can **push** does (O5):

- **Guests**: Alloy, already on every NixOS guest, gains a metrics pipeline when the guest's level
  asks for it.
- **Proxmox nodes and PBS** push through their own *external metric server* setting, pointed at a
  receiver on the logging VM (an Alloy component that takes the protocol the shipped Proxmox and
  PBS versions offer — InfluxDB line protocol over HTTPS, or OpenTelemetry where the version has
  it — and writes into the store with the node's identity). site-manager and backup-manager set the
  target as part of their reconcile, so a new node pushes from its first boot. Signals the metric
  server does not carry (PSI, the guest-memory sampler's working sets, ZFS latency) are pushed by
  the node's own sampler units, which logging's `update.sh` already installs on every node.
- **Pull** is the fallback only: for a Proxmox or PBS version whose metric target cannot be made to
  work, for OPNsense (whose Caddy plugin and base system run no Alloy of ours: Caddy's per-host
  metrics are served on a listener on the firewall's mgmt address, reachable by the mothership
  only), switches and black-box probes. The puller is the Alloy on the mothership
  (`tappaas-cicd`), which already reaches every plane, so no new firewall paths into client zones
  are opened for scraping.

Grafana gains the two data sources and shipped dashboards per class (node, guest, pool, published
service). The console (ADR-034) reads the same store for the CI panel (D7).

### D2 — What is realistic to monitor

Collected numbers are chosen per **class** (ADR-040 D3), by USE for resources and RED for services,
and each signal sits at the lowest level (D3) where it pays for itself:

| Class / target | Signals | Source | Level |
|---|---|---|---|
| `machine` (Proxmox node) | CPU utilization and steal, load and run queue, PSI (cpu, memory, io), memory used/available, ZFS ARC hit ratio, NIC throughput and errors, temperatures where exposed | Proxmox metric server + node sampler units, pushed | `basic` |
| `vm`, `lxc` (any OS) | CPU used vs allotted, memory working set (the guest-memory sampler's numbers, moved from log to metric), disk read/write IOPS and bytes, NIC throughput | Proxmox metric server + guest-memory sampler, pushed from the node | `basic` |
| `vm` (NixOS, with Alloy) | inside view: PSI, filesystem fill and inode use, systemd unit restarts, per-unit CPU and memory of the module's main services | Alloy `prometheus.exporter.unix`, pushed | `basic` |
| `storage-pool`, `disk` | pool used/free, read/write latency, IOPS, scrub and resilver progress, SMART wear and reallocated sectors | Proxmox metric server + node sampler (ZFS); SMART from site-manager's report | `basic` |
| `datastore` (PBS) | used, dedup ratio, job duration, transfer rate | PBS metric server, pushed | `basic` |
| firewall (`network` vm, OPNsense) | interface throughput and errors, state table size, CPU, Unbound query rate and latency | `os-node_exporter` + Unbound stats, pulled | `basic` |
| published `service` (anything behind `network:proxy`) | request rate, error ratio (status codes kept as classes 2xx–5xx), latency p50/p95/p99 per host — the user's view | Caddy's per-host metrics on the firewall's mgmt listener, scraped by the mothership, labelled with the proxy route's CI | `service` |
| published `service`, black-box | HTTP(S) response time and TLS expiry from inside the site, every minute | Alloy `prometheus.exporter.blackbox` on the mothership | `service` |
| `software` that exposes metrics | the module's own: Authentik, PostgreSQL, Redis, Grafana/Loki/Alloy, LiteLLM token rate and latency, Nextcloud via its serverinfo | Module exporters, declared in the module (D5) | `service` |
| request chains | spans across proxy → identity → app for software that emits OTel traces: Grafana today; Caddy and authentik when they can (see *Implementation status*) | OTLP into `logging:traces` | `trace` |

**Not realistic, and out of scope for now:** per-request APM inside applications that do not emit
traces (Nextcloud's PHP, most Community modules); eBPF auto-instrumentation and continuous
profiling (park until kernels and memory budgets allow; O6); Windows and HAOS guests' inside view
(they get the Proxmox outside view at `basic`); network flow analysis (NetFlow/IPFIX); real-user
monitoring in the browser. Each can be added later as a signal at a level without changing this
decision.

**Cardinality is bounded by design:** every pipeline keeps an allow-list of metric names and labels
per class; labels that carry user input (URL paths, query strings, user names) are dropped or
bucketed before they leave the guest, because they cost series and can carry secrets — the same
scrub rule the journal pipelines have (logging DESIGN, trust model).

### D3 — Levels, and how they are turned on and off

One ordered setting, **`performance.level`**:

| Level | Collects | Resolution | Typical cost (20-guest site) |
|---|---|---|---|
| `off` | nothing beyond today's logs | — | 0 |
| `basic` | D2's resource signals (USE) for nodes, guests, pools, disks, datastores, firewall | 60 s (Proxmox's own pushes arrive every 10 s) | measured on 3 nodes and 22 guests: ~1.9 k series for the outside view (~45 per guest, ~200 per node) plus ~64 per guest for a NixOS guest's inside view; both Prometheus instances ~190 MB RAM |
| `service` | `basic` + RED for published services, black-box probes, module exporters | 60 s | +~9 series per guest, plus Caddy, probe and exporter series per published service |
| `trace` | `service` + OTLP traces, head-sampled (default 10 %, errors and slow requests always kept) | per request | bounded by sampling and Tempo's retention; Tempo +~300 MB RAM while any CI is at `trace` |

Plus one modifier, **`performance.resolution: fine`** (15 s instead of 60 s), for an
investigation or for a module the operator wants to watch closely; it costs four times the
samples of the level it modifies.

**Where it is set** — the config cascade, most specific wins:

1. **Site** (`site.json`, `performance.level`, `performance.retentionDays`) — the default for all;
2. **Environment** — an environment may raise or lower it for its modules;
3. **Module instance** (`config/<module>.json`, `performance.level`) — a declared field under
   ADR-020's change model: validated, drift-checked, changed with `module-manager modify <m>
   --set performance.level=service`, previewed and applied as a job from the console;
4. **One CI, for a time** — `health-manager perf <ci> --level trace --until 2h` (or the console's
   *Investigate* verb on the CI panel): a temporary raise with an **expiry**, after which the CI
   falls back to its cascaded level by itself. **`trace` is only available this way** (O4): it is
   an investigation tool, never standing configuration. Every timed raise names its `--until`;
   *Extend* is the same raise with a later `--until`. `fine` may be set at any scope, standing or
   timed. The raise in force is an `investigation` attribute on the CI, set on the raise and unset
   when it ends or expires.

The level of a module instance is a declared field owned by module-manager; the timed raise is
health-manager's verb, since health is the lens that reads the numbers; the logging module only
renders what the levels ask for and owns no level of its own (O3).

**What switching does.** The level renders configuration, nothing else: the guest's Alloy
pipeline (which exporters, which allow-list, which interval), the mothership's pull jobs, the
Caddy metrics and tracing directives, Tempo's idle or active state. A change is a reconcile of
those files — no reinstall and **no OS rebuild** (O7): Alloy's NixOS module keeps only the fixed
part of its configuration (the journal pipeline, the credentials, the endpoints) and loads the
level-driven part from a runtime directory (`/var/lib/alloy/perf.d`, in the unit's
`ReadWritePaths`), which the reconcile writes and then tells Alloy to reload. Adding that directory
is one OS rebuild per guest, once. After that a level change is the module's ordinary converge,
which rewrites the runtime file and builds no new generation; a timed raise writes the file
directly. A guest that does not ship its journal (`logging:logs`) runs no Alloy and keeps only the
outside view its node reports. Lowering a
level stops collection at once; collected data ages out with retention. **`health-manager perf
purge <ci>`** (or `perf stop --purge`) deletes a CI's series and traces from the stores
(Prometheus `delete_series` on both instances, Tempo's compaction) for when data should not be kept.

**Defaults by site size** (ADR-044): `small` → `off` (O2: a one-box site pays nothing until the
operator asks), `medium` → `basic`, `large` → `basic` with `service` suggested. Retention 7 / 15 /
30 days. Prometheus has one retention per instance, so 5-minute downsampled data for trends goes
by recording rules and `remote_write` to a second, small Prometheus on the same VM that keeps 90
days and nothing else. Tempo keeps 72 hours. The logging VM's `memorySmallLarge` and
`diskSmallLarge` grow by the table above; install's capacity check (ADR-044) counts the level.

Every level change — who, from what to what, until when — is a change on the CI in the CMDB
(ADR-040 D13), so "who switched tracing on for identity last week" is a history query.

### D4 — Traceability: every number names its CI, its change and its release

Performance data is only useful if it can be traced to what it is about and to why it changed:

1. **Identity.** Every series and every span carries the CI's OTel resource identity (ADR-040
   D14). The logging VM sets `service.instance.id`, `service.name`, `service.namespace`,
   `deployment.environment.name` and `tappaas.ci.id` as labels from the authenticated user and
   the CMDB (an identity map the mothership renders from the CMDB onto the logging VM and Alloy
   re-reads on change); a sender's own identity labels are overwritten. Guests push OTLP rather
   than `remote_write` because only the OTLP path lets the receiver see who authenticated. A
   series about a guest sent by its node carries the guest's identity; a storage pool's series
   carry the identity of the node that measures it and the pool's name. The only sender allowed to
   name another CI is the mothership, for the published services it measures (Caddy's and the
   probes' series carry the proxy route's CI). A series is never matched to a CI by host name. `cmdb resolve` maps any label set back to a CI.
2. **Changes as annotations.** Every CMDB change that can move performance — an update to a new
   release, a `modify` of cores or memory, a reboot, a migration to another node, a level change
   itself — is drawn on the console's charts straight from the CMDB's change history, and is to be
   written as a Grafana annotation tagged with the CI id for the dashboards. "Slower since the update to 2.4" becomes something you see, not something you guess.
3. **The backbone.** From the CI the existing trace runs up (ADR-040 D1): desired record →
   release → module version → its design and its Codeberg issues. A regression found in a chart
   is one click from the release notes that caused it.
4. **Signal correlation.** At `trace`, the trace id is written into log lines (W3C
   `traceparent`), Loki gets a derived field linking to Tempo, and Prometheus histograms carry
   exemplars linking a slow bucket to a sample trace: metric → trace → log for one request.
5. **Root cause context.** When ADR-041 names a root cause, the CI panel shows the root's and its
   symptoms' performance around the transition, so "identity went critical" sits beside "its
   node's memory PSI climbed for twenty minutes before".

### D5 — Modules declare what they expose

A module declares its metrics and traces the way it declares log rules (ADR-039), in its module
JSON under `performance`:

```json
"performance": {
  "exporters": [
    { "name": "authentik", "port": 9300, "path": "/metrics", "level": "service",
      "keep": ["authentik_*_duration_seconds_*", "authentik_*_total"] }
  ],
  "traces": { "otlp": true, "level": "trace" },
  "thresholds": [
    { "signal": "http_p95_seconds", "warning": 1.5, "critical": 5, "for": "15m" }
  ]
}
```

A module without the block gets its class's signals (D2) and nothing more. **Foundation
modules first** (O8): module-manager refuses the block in a Community module until the format has
settled on the foundation's own exporters, as ADR-039 began with the foundation's rules. The platform builds
the scrape or push configuration, the allow-list and a generated Grafana dashboard of the kept
names from the declaration; a module never ships raw PromQL, the way ADR-039 modules never ship
LogQL. `traces.otlp` is declared `true` only where the software actually emits OpenTelemetry.

### D6 — Performance meets event health

- **A `performance` condition type** joins ADR-041 D1's table: *is it fast enough*, fed by the
  thresholds of D5 and per-class defaults (pool write latency, guest CPU steal, PSI some-avg60,
  service p95 latency and error ratio), judged by `health-manager assess` from the metrics store
  the way it judges `capacity` from the CMDB. A threshold must hold for a window (`for`) before
  the condition changes, so a spike is not an event. Thresholds are **static** (O6), deterministic
  like the rest of ADR-041; a baseline ("deviates from the same hour over the last 7 days") is a
  later experiment for the digest, not part of this decision.
- **Capacity gets trends:** `assess` may use the store's history for "full in N days" predictions
  on pools, datastores and memory commitment, turning a future `critical` into today's `warning`.
- **Correlation rules** (ADR-041 D3) gain shipped entries for `performance`: a `warning` on a
  `storage-pool` crosses `stored-on` as a `warning` impact; a `warning` on a `machine` (CPU
  steal, memory pressure) crosses `runs-on`. So "six guests are slow" derives to "their pool".
- **ADR-039 rules gain `source: metrics`**: a rule names a declared signal, a threshold and a
  window instead of a line pattern; delivery, labels and mail templates are unchanged.
  Performance conditions mail only as root causes, in the daily digest by default (D4 of
  ADR-041), never per symptom.
- **Performance is never the only proof of failure.** `operational` stays fed by liveness checks
  and alerts; a missing metric is `unknown`, not `critical`.

### D7 — Where it is seen: a Performance menu in the console

The solution is not complete without the console (ADR-034): performance gets its own
**Performance** entry in the console's menu, directly under *Health*, built on the console's
shared components and its preview/apply contract. Grafana stays for deep dives; the operator's
daily view and every switch of a level are in the console. The page has four parts:

- **Overview** — the site at a glance at the current level: the most saturated resources (USE:
  CPU steal, memory pressure, pool latency, fill rate), the slowest and most failing published
  services (RED: p95 latency, error ratio), each with a 24 h sparkline and the last change on it
  as a marker; any `performance` root cause (D6) on top. A site at `off` says so and offers to
  switch on `basic`, with its cost.
- **Browse** — the same containment tree as the Health view (ADR-041 D5), coloured by the
  `performance` condition instead of the worst condition; selecting an object opens its charts
  (24 h / 7 d / 30 d, and the 90-day trend) with change annotations (D4) and links to its root
  cause, its Grafana dashboard and its traces.
- **Levels** — the cascade as a table: the site's level and retention, each environment's and each
  module instance's level with where it comes from (set here or inherited), the resolution, and
  the estimated series, disk and memory cost of the whole against the logging VM's size (ADR-044).
  Changing a level is a job previewed and applied like any other (`module-manager modify … --set
  performance.level=…`, the site setting through site-manager).
- **Investigations** — the timed raises in force (`trace`, `fine`): which CI, who started it, until
  when, with *Extend* and *Stop*; *Investigate* starts one from here or from any CI panel, and
  `--until` is required for `trace` (D3). Ended investigations stay listed with their history.

Beside the menu:

- **The CI panel** (ADR-041 D5) gets a *Performance* section: sparklines of the class's key
  signals over 24 h / 7 d with change annotations, the current level and its expiry, and the
  *Investigate* verb. Read through the console's API from the metrics store; no Grafana embed.
- **Grafana** keeps the deep views: shipped dashboards per class and per published service, the
  explore views for traces, linked from the CI panel with the CI id as a variable.
- **The Overview** shows nothing new unless a `performance` root cause exists — performance stays
  quiet until it matters.

## Consequences

- TAPPaaS gains a metrics store and, idle by default, a trace store on the logging VM; the VM
  grows by the level's cost, and ADR-044's sizes account for it.
- Alloy configuration on guests and the mothership becomes level-driven; the guest-memory sampler
  moves from log lines to metrics (its log output kept until the report reads the store).
- ADR-041 gains a condition type and shipped rules; ADR-039 gains a rule source; ADR-040 D14's
  promise is kept for metrics and traces.
- Operators can answer "how well" and "since when", and turn the cost on only where they look.

## Alternatives considered

- **A1 — Keep numbers as log lines in Loki** (as the guest-memory sampler does). Works for one
  signal; LogQL over numbers is slow and expensive, and there are no histograms, no rates, no
  downsampling. Rejected for anything beyond today's sampler.
- **A2 — A monitoring appliance** (Netdata, Zabbix, Checkmk). Its own agents, its own model of the
  site, its own alerting beside ADR-039 and its own health beside ADR-041. Rejected as in ADR-041
  A2; their signal choices are borrowed.
- **A3 — Everything always on at fine resolution.** Simple to explain; on a 32 GB one-box site it
  costs more memory than several modules. Rejected: levels with expiry are the point.
- **A4 — Tracing as a standing level.** Sampling keeps it bounded, but most foundation software
  does not emit useful spans yet, and a standing trace store is cost with little return.
  Rejected: `trace` is timed only (O4).
- **A5 — Mimir/Thanos for scale.** One site does not need horizontal scale. Rejected.
- **A6 — VictoriaMetrics as the store.** About half the RAM and disk and native downsampling, but
  Prometheus is the operator's direction, NixOS-native, with the widest ecosystem. Rejected for
  now (O1); the store sits behind `logging:metrics`, so it can be swapped if measurement on a
  `service`-level site says so.
- **A7 — Pull Proxmox and PBS from the mothership.** One puller and no node change, but a second
  path to every node's API and numbers that arrive late. Kept as the fallback only (O5).

## Implementation status

Built 2026-11-10/11 on the `adr-046-*` branches (P1 → P2 → P5 → P3 → P4 → P6, each building on the
one before), each live-tested on the test site with a teardown. Known gaps:

- **Traces from the proxy and identity.** OPNsense's Caddy plugin generates every published site
  and has no per-site tracing option, so Caddy spans need an upstream feature; authentik ships no
  OpenTelemetry export (Sentry only). Until then `trace` is proven with Grafana's own spans, and
  identity declares `traces.otlp: false`.
- **Proxmox's 10 s pushes** are stored as they come; thinning to the level's resolution waits for
  Alloy's processor to leave experimental.
- **Grafana annotations** for CMDB changes are not written yet (the console draws them, D4.2).
- **The Overview** does not show CPU steal or pool fill rate until their units are verified.
- **A `service` raise on a pool or a route** is recorded but changes no collector.
- Guests pick up their own collector at their next OS update with the release that has it.

## Open questions

All closed by the operator on 2026-11-10.

- **O1** *(closed: Prometheus)* Prometheus or VictoriaMetrics as the store. **Decided:** Prometheus,
  the earlier direction: NixOS-native, an OTLP receiver, the widest ecosystem. The store sits
  behind `logging:metrics` so it can be swapped (A6).
- **O2** *(closed: `off`)* Default level on a `small` site. **Decided:** `off`; a one-box site pays
  nothing until the operator switches it on (D3).
- **O3** *(closed: the recommendation)* Who owns the level. **Decided:** a module instance's level
  is a declared field owned by module-manager, the timed raise is a health-manager verb, the
  logging module only renders (D3).
- **O4** *(closed: only `fine`)* Whether `trace` and `fine` may be standing configuration.
  **Decided:** `fine` may be standing at any scope; `trace` is timed only, `--until` required (D3).
- **O5** *(closed: push)* Proxmox and PBS numbers by pull or push. **Decided:** push from the nodes
  through their external metric server into a receiver on the logging VM, the node's sampler
  units for what it does not carry; the API pull from the mothership only as fallback (D1, A7).
- **O6** *(closed: static)* Static thresholds or baselines. **Decided:** static thresholds
  initially; baselines a later experiment for the digest (D6).
- **O7** *(closed: runtime config)* Alloy's metrics pipeline without an OS rebuild. **Decided:** a
  runtime directory in the unit's `ReadWritePaths`, written by the reconcile and reloaded; one
  rebuild per guest to add it (D3).
- **O8** *(closed: foundation first)* Community module declarations. **Decided:** foundation
  modules only until the format has settled (D5).

## Implementation plan

1. **P1 — Store and identity.** `logging:metrics` (Prometheus, per-VM credentials, TLS, retention,
   the second 90-day Prometheus for trends), Grafana data source, identity labels from the CI id;
   the receiver for Proxmox's and PBS's metric server, set by site-manager and backup-manager;
   the guest-memory sampler as metrics. Level `basic` for nodes and guests, switched by `site.json`.
2. **P2 — Levels and the cascade.** `performance.level` and `resolution` in site, environment and
   module config (ADR-020 declared field), Alloy's runtime directory on guests and the reload,
   mothership pull jobs for the fallback targets, `--purge`, sizing in ADR-044's capacity check.
3. **P3 — `service`.** Caddy metrics, black-box probes, foundation modules' `performance`
   declarations (D5), shipped dashboards per class.
4. **P4 — Health.** `performance` conditions with static thresholds and trend-based `capacity` in
   `assess`, correlation rules, ADR-039 `source: metrics`.
5. **P5 — Console.** The Performance menu (D7: Overview, Browse, Levels, Investigations), the CI
   panel's Performance section, change annotations, the *Investigate* verb with expiry.
6. **P6 — `trace`.** Tempo, OTLP from Caddy and Authentik, trace ids in logs, exemplars; timed only.
