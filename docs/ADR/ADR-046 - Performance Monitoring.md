# ADR-046 — Performance Monitoring

| | |
|---|---|
| **Status** | **Draft** |
| **Version** | 0.1 |
| **Date** | 2026-11-10 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Closes / addresses** | #927 (performance monitoring). Answers ADR-039 open question 1 (metrics, and whether a rule gains `source: metrics`). Fills ADR-040 D14's "metrics and traces are not collected today". Amends ADR-041 D1 (a `performance` condition type) and D3 (shipped rules for it). Related: ADR-007e (health as a lens), ADR-020 (declared fields), ADR-034 (console; Grafana kept for dashboards, A4), ADR-043 (internal CA), ADR-044 (site sizes), the logging module's v2 backlog ("no Prometheus yet"). |
| **Changelog** | v0.1 (2026-11-10) — first draft, from the operator's direction of 2026-11-10: complement event-based health (operations and security events, CMDB associations, root cause and impact) with performance monitoring; decide what is realistic to monitor, how it is turned on and off, and how its level is set; tie it to traceability. |

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

- **`logging:metrics`** — a time-series store on the logging VM (Prometheus, see O1), receiving
  pushes over Prometheus `remote_write` and OTLP, behind nginx with one credential per pushing
  VM, the same pattern as Loki's tcp/3101: a VM can write series only under its own identity (the
  identity labels are set from the credential, never trusted from the sender), and cannot read or
  delete. Over TLS from the internal CA (ADR-043).
- **`logging:traces`** — a trace store (Grafana Tempo), installed but **idle** until some CI is at
  level `trace` (D3). Local filesystem storage, short retention.

Guests **push**: Alloy, already on every NixOS guest, gains a metrics pipeline when the guest's
level asks for it. Pull is used only where there is no Alloy and the target cannot push — the
Proxmox API, PBS, OPNsense, switches, and black-box probes — and the puller is the Alloy on the
mothership (`tappaas-cicd`), which already reaches every plane, so no new firewall paths into
client zones are opened for scraping.

Grafana gains the two data sources and shipped dashboards per class (node, guest, pool, published
service). The console (ADR-034) reads the same store for the CI panel (D7).

### D2 — What is realistic to monitor

Collected numbers are chosen per **class** (ADR-040 D3), by USE for resources and RED for services,
and each signal sits at the lowest level (D3) where it pays for itself:

| Class / target | Signals | Source | Level |
|---|---|---|---|
| `machine` (Proxmox node) | CPU utilization and steal, load and run queue, PSI (cpu, memory, io), memory used/available, ZFS ARC hit ratio, NIC throughput and errors, temperatures where exposed | Proxmox API + node RRD, pulled by mothership Alloy | `basic` |
| `vm`, `lxc` (any OS) | CPU used vs allotted, memory working set (the guest-memory sampler's numbers, moved from log to metric), disk read/write IOPS and bytes, NIC throughput | Proxmox API, pulled | `basic` |
| `vm` (NixOS, with Alloy) | inside view: PSI, filesystem fill and inode use, systemd unit restarts, per-unit CPU and memory of the module's main services | Alloy `prometheus.exporter.unix`, pushed | `basic` |
| `storage-pool`, `disk` | pool used/free, read/write latency, IOPS, scrub and resilver progress, SMART wear and reallocated sectors | Proxmox API + node exporter's ZFS collector; SMART from site-manager's report | `basic` |
| `datastore` (PBS) | used, dedup ratio, job duration, transfer rate | PBS API, pulled | `basic` |
| firewall (`network` vm, OPNsense) | interface throughput and errors, state table size, CPU, Unbound query rate and latency | `os-node_exporter` + Unbound stats, pulled | `basic` |
| published `service` (anything behind `network:proxy`) | request rate, error ratio (5xx), latency p50/p95/p99 per host — the user's view | Caddy's metrics on the firewall VM | `service` |
| published `service`, black-box | HTTP(S) response time and TLS expiry from inside the site, every minute | Alloy `prometheus.exporter.blackbox` on the mothership | `service` |
| `software` that exposes metrics | the module's own: Authentik, PostgreSQL, Redis, Grafana/Loki/Alloy, LiteLLM token rate and latency, Nextcloud via its serverinfo | Module exporters, declared in the module (D5) | `service` |
| request chains | spans across proxy → identity → app for software that emits OTel traces (Caddy, Authentik, Grafana, others as they gain it) | OTLP into `logging:traces` | `trace` |

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
| `basic` | D2's resource signals (USE) for nodes, guests, pools, disks, datastores, firewall | 60 s | ~5–8 k series, ~20 MB disk/day, +~250 MB RAM on the logging VM |
| `service` | `basic` + RED for published services, black-box probes, module exporters | 30 s for services | ~15–25 k series, ~60 MB/day, +~500 MB RAM |
| `trace` | `service` + OTLP traces, head-sampled (default 10 %, errors and slow requests always kept) | per request | bounded by sampling and Tempo's retention; Tempo +~300 MB RAM while any CI is at `trace` |

Plus one modifier, **`performance.resolution: fine`** (15 s scrapes), for an investigation.

**Where it is set** — the config cascade, most specific wins:

1. **Site** (`site.json`, `performance.level`, `performance.retentionDays`) — the default for all;
2. **Environment** — an environment may raise or lower it for its modules;
3. **Module instance** (`config/<module>.json`, `performance.level`) — a declared field under
   ADR-020's change model: validated, drift-checked, changed with `module-manager modify <m>
   --set performance.level=service`, previewed and applied as a job from the console;
4. **One CI, for a time** — `health-manager perf <ci> --level trace --until 2h` (or the console's
   *Investigate* verb on the CI panel): a temporary raise with an **expiry**, after which the CI
   falls back to its cascaded level by itself. `trace` and `fine` are **only** available this
   way at first (O4): they are investigation tools, not standing configuration.

**What switching does.** The level renders configuration, nothing else: the guest's Alloy
pipeline (which exporters, which allow-list, which interval), the mothership's pull jobs, the
Caddy metrics and tracing directives, Tempo's idle or active state. A change is a reconcile of
those files — no reinstall, no OS rebuild where Alloy's config is a runtime file (O7). Lowering a
level stops collection at once; collected data ages out with retention. **`--purge`** deletes a
CI's series and traces from the stores (Prometheus `delete_series`, Tempo's compaction) for when
data should not be kept.

**Defaults by site size** (ADR-044): `small` → `off` (O2), `medium` → `basic`, `large` → `basic`
with `service` suggested. Retention 7 / 15 / 30 days, with 5-minute downsampled data kept 90 days
for trends (recording rules into a second retention class, or VictoriaMetrics' native
downsampling, depending on O1). Tempo keeps 72 hours. The logging VM's `memorySmallLarge` and
`diskSmallLarge` grow by the table above; install's capacity check (ADR-044) counts the level.

Every level change — who, from what to what, until when — is a change on the CI in the CMDB
(ADR-040 D13), so "who switched tracing on for identity last week" is a history query.

### D4 — Traceability: every number names its CI, its change and its release

Performance data is only useful if it can be traced to what it is about and to why it changed:

1. **Identity.** Every series and every span carries the CI's OTel resource identity (ADR-040
   D14). On OTLP ingest, `service.instance.id`, `service.name`, `service.namespace`,
   `deployment.environment.name` and `tappaas.ci.id` are promoted to labels; on `remote_write`
   Alloy sets the same labels from the CI id cmdb-controller wrote beside the push secret. A
   series is never matched to a CI by host name. `cmdb resolve` maps any label set back to a CI.
2. **Changes as annotations.** Every CMDB change that can move performance — an update to a new
   release, a `modify` of cores or memory, a reboot, a migration to another node, a level change
   itself — is written as a Grafana annotation tagged with the CI id, and drawn on the CI panel's
   charts. "Slower since the update to 2.4" becomes something you see, not something you guess.
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

A module without the block gets its class's signals (D2) and nothing more. The platform builds
the scrape or push configuration, the allow-list and the Grafana dashboard from the declaration;
a module never ships raw PromQL, the way ADR-039 modules never ship LogQL.

### D6 — Performance meets event health

- **A `performance` condition type** joins ADR-041 D1's table: *is it fast enough*, fed by the
  thresholds of D5 and per-class defaults (pool write latency, guest CPU steal, PSI some-avg60,
  service p95 latency and error ratio), judged by `health-manager assess` from the metrics store
  the way it judges `capacity` from the CMDB. A threshold must hold for a window (`for`) before
  the condition changes, so a spike is not an event.
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

### D7 — Where it is seen

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
  does not emit useful spans yet, and a standing trace store is cost with little return. Deferred:
  investigation-only first (O4).
- **A5 — Mimir/Thanos for scale.** One site does not need horizontal scale. Rejected.

## Open questions

- **O1** Prometheus (operator's earlier direction, NixOS-native, OTLP receiver, widest ecosystem)
  or VictoriaMetrics (roughly half the RAM and disk, native downsampling, Prometheus-compatible).
  Recommendation: Prometheus first, with the store behind `logging:metrics` so it can be swapped;
  measure on hrossen at `service` before deciding.
- **O2** Default level on `small`: `off` (cheapest, nothing to explain) or `basic` (the numbers
  are there when something goes wrong, which is when you need yesterday's data).
- **O3** Who owns the level: `health-manager perf` (health is the lens that reads it) or a new
  `perf-manager`, or the logging module's own verb. Recommendation: the level is a declared field
  of each module (module-manager), the timed raise is a health-manager verb, logging only renders.
- **O4** Whether `trace` and `fine` may ever be standing configuration, or only timed.
- **O5** Proxmox numbers: pull the API from the mothership (one puller, no node change), or set
  Proxmox's and PBS's external metric server to push into the store (closer to the source, but
  their supported targets need checking against the version shipped).
- **O6** Baselines and anomaly: static thresholds only (deterministic, like ADR-041), or also
  "deviates from the same hour over the last 7 days" for the digest. Recommendation: static only
  in the first release, anomaly as an experiment in the digest.
- **O7** Whether Alloy's metrics pipeline can be a runtime config file on the guest (switching
  without a NixOS rebuild) given the unit sandbox, or needs an OS rebuild per level change.
- **O8** Community modules: may they declare exporters and traces from day one, or only
  foundation modules until the format has settled (as ADR-039 did first for the foundation)?

## Implementation plan

1. **P1 — Store and identity.** `logging:metrics` (Prometheus, per-VM credentials, TLS, retention),
   Grafana data source, identity labels from the CI id; mothership Alloy pulls the Proxmox API.
   Level `basic` for nodes and guests only, switched by `site.json`.
2. **P2 — Levels and the cascade.** `performance.level` in site, environment and module config
   (ADR-020 declared field), rendering of guest Alloy pipelines and pull jobs, `--purge`, sizing in
   ADR-044's capacity check; guest-memory sampler as metrics.
3. **P3 — `service`.** Caddy metrics, black-box probes, module `performance` declarations (D5),
   shipped dashboards per class.
4. **P4 — Health.** `performance` conditions and trend-based `capacity` in `assess`, correlation
   rules, ADR-039 `source: metrics`.
5. **P5 — Console.** The CI panel's Performance section, change annotations, the *Investigate* verb
   with expiry.
6. **P6 — `trace`.** Tempo, OTLP from Caddy and Authentik, trace ids in logs, exemplars; timed only.
