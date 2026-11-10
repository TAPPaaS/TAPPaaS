# logging — Design notes

Implementation and reference detail for the logging module (Loki + Grafana + Alloy).
For the catalog entry see [README.md](./README.md); for installation see
[INSTALL.md](./INSTALL.md); for test coverage see [TEST.md](./TEST.md).

## Architecture

- **Grafana Loki** — log store, single-binary mode, filesystem-backed, 30-day retention.
- **Grafana** — web UI, port 3000, fronted by Caddy at `logging.<tappaas.domain>`.
- **Grafana Alloy** (on this VM) — tails the local journal **and** receives syslog from
  OPNsense on tcp/1514 and from the Proxmox nodes on tcp/1515.
- **Alloy clients** (on every NixOS VM that declares `logging:logs`) — push their journal
  to the push-only receiver `http://logging.mgmt.internal:3101` (#770).

Alloy replaced Promtail in 2026-09 (#721): NixOS 26.05 removed both the promtail module
and the package, promtail having reached end of life. Alloy embeds promtail's own
pipeline, so the scrape, the relabelling and the redaction stages carry over unchanged —
the configs were translated by `alloy convert --source-format=promtail`, not rewritten.

```
   ┌──────────────┐   journal     ┌────────────────────────────────┐
   │ tappaas-cicd │──Alloy───────►│                                │
   ├──────────────┤               │   logging (this VM)            │
   │ identity     │──Alloy───────►│   ┌──────────┐    ┌─────────┐  │
   ├──────────────┤               │   │  Alloy   │───►│  Loki   │  │
   │ <app VMs>    │──Alloy───────►│   └──────────┘    └────┬────┘  │
   ├──────────────┤               │                        ▼       │
   │ OPNsense     │──syslog 1514─►│                   ┌─────────┐  │
   │ (firewall)   │  RFC 5424 TCP │                   │ Grafana │◄─┼── admin
   └──────────────┘               │                   └─────────┘  │
                                  └────────────────────────────────┘
```

The whole stack is declared in [`logging.nix`](logging.nix).

## VM facts

| Field | Value |
|---|---|
| VMID | 150 |
| Zone | `mgmt` |
| Cores / RAM / Disk | 2 / 2 GB / 32 GB |
| Storage | `tanka1` |
| `provides` | *(empty in v1 — see backlog)* |
| Public URL | `https://logging.<tappaas.domain>` (via Caddy) |

## Ports

| Port | Proto | Purpose | Source |
|---|---|---|---|
| 22 | TCP | SSH | mgmt admins |
| 3000 | TCP | Grafana UI | Caddy on the firewall |
| 3100 | TCP | nginx → Loki's API, admin credential (#165) | the mothership's tools — mgmt only, never opened to other zones |
| 3101 | TCP | nginx → Alloy `loki.source.api` → Loki: push only, a credential per VM | every VM's journal client (`logging:logs` pinhole) |
| 3102 | TCP | Loki itself (localhost only) | Grafana, this VM's Alloy |
| 3103 | TCP | Alloy's push receiver (localhost only) | nginx |
| 1514 | TCP | Syslog ingest (RFC 5424) → `source=opnsense` | OPNsense firewall |
| 1515 | TCP | Syslog ingest (RFC 5424) → `source=proxmox` | Proxmox nodes (rsyslog) |
| 9080 | TCP | Alloy metrics and component UI (localhost only) | local |
| 3120 | TCP | nginx (TLS) → Alloy → Prometheus: metrics push only, a credential per host — OTLP/HTTP at `/v1/metrics`, InfluxDB v2 at `/api/v2/write` | the Proxmox cluster's metric server and its nodes' sampler, PBS (`logging:metrics` pinhole for other zones) |
| 3121 | TCP | nginx (TLS) → the Prometheus API, admin credential; `/trends/` is the 90-day instance | the mothership's tools — mgmt only |
| 3122 | TCP | Prometheus, the metrics store (localhost only) | Grafana, this VM's Alloy |
| 3123 | TCP | Prometheus, 90-day trends (localhost only) | Grafana, the store's remote_write |
| 3124 | TCP | Alloy's OTLP receiver (localhost only) | nginx |
| 3125 | TCP | Alloy's InfluxDB receiver (localhost only) | nginx |
| 3127 | TCP | Alloy's OTLP gRPC receiver (localhost only): this VM's own spans | Grafana |
| 3200 | TCP | Tempo's API (localhost only), only while a CI is at trace | Grafana |
| 4317 | TCP | Tempo's OTLP receiver (localhost only), only while a CI is at trace | this VM's Alloy |

## Label scheme

Every log line in Loki carries at least these labels:

| Label | Values | Meaning |
|---|---|---|
| `job` | `systemd-journal` \| `syslog` | how it was ingested |
| `host` | `logging`, `tappaas-cicd`, `tappaas1`, `network`, … | source machine: a journal line's from its push credential, a syslog line's from the first label of its hostname — either way the instance's vmname |
| `source` | `opnsense`, `proxmox` | only on `job=syslog`; identifies the syslog sender |
| `unit` | `pveproxy.service`, `filterlog`, `sshd`, … | systemd unit or syslog program |
| `severity` | `info`, `warn`, `err`, `crit`, … | syslog severity |
| `facility` | `daemon`, `auth`, `kern`, … | syslog facility (only on `job=syslog`) |

## First-boot secrets

The Grafana admin password is auto-generated on first boot. The cleartext is **never**
echoed to the journal — instead it is written to a root-only one-shot file
(`/root/grafana-admin-password.initial`; retrieval steps in [INSTALL.md](./INSTALL.md)).
The journal-scrape pipeline also drops `generate-*-secrets` units as belt-and-braces
protection. Grafana reads the password from `/etc/secrets/grafana-admin-password`
(`0600 grafana:grafana`).

## Syslog forwarding setup (automatic)

`update.sh` configures two syslog forwarders automatically on every install/update —
both are idempotent:

### OPNsense → `:1514` (source=opnsense)

`syslog-manager add-destination` creates/updates the OPNsense destination matching the
description `tappaas-logging`. Skipped when `firewallType=NONE` in the module config
(e.g. you're using pfSense/UniFi/etc.).

The destination is matched by description (`tappaas-logging`) for idempotency —
re-running the install or update updates the existing entry rather than creating
duplicates.

Inspect or manage the destination:

```
syslog-manager list --no-ssl-verify
syslog-manager delete-destination --description tappaas-logging --no-ssl-verify
syslog-manager reconfigure --no-ssl-verify
```

To verify, on `logging`:

```
sudo journalctl -u alloy -f
# then trigger an OPNsense event (e.g. ssh into the firewall and `logger -t test hi`)
# you should see Alloy accept the line and ship it to Loki
```

In Grafana, query `{job="syslog"}` or `{job="syslog", source="opnsense"}`.

### Proxmox nodes → `:1515` (source=proxmox)

For each cluster node, `update.sh`:

1. Installs `rsyslog` via `apt-get` if missing (Proxmox 9 / Debian 13 ships
   journald-only by default — no rsyslog).
2. Writes `/etc/rsyslog.d/99-tappaas-loki.conf` with an `omfwd` forwarder pointing at
   `logging.mgmt.internal:1515` (RFC 5424, octet-counted framing).
3. `systemctl enable --now rsyslog && systemctl restart rsyslog`.

rsyslog's default config wires `imjournal` to read systemd-journal, so all journal
entries flow through to Loki: PVE services (`pveproxy`, `pve-cluster`, `pve-firewall`,
`qemu-server`, `watchdog`), kernel messages, sshd, cron, etc.

To remove the rsyslog forwarder from a node (e.g. when retiring it):

```
ssh root@<node>.mgmt.internal "rm /etc/rsyslog.d/99-tappaas-loki.conf && systemctl restart rsyslog"
```

### Guest memory samples from the nodes (#663)

Module memory defaults are to be chosen from measurement, and Proxmox's own figure
cannot be used for that: it counts the guest's page cache as used (from the balloon's
`free_mem`), or shows the host's view when the guest reports nothing. So each node
also runs `tappaas-guest-memory.service` (`node/tappaas-guest-memory`, a Perl loop on
Proxmox's own modules), installed by the same `update.sh` step and restarted only
when its files change. Once a minute it writes one logfmt line per running guest to
its journal, which the rsyslog forwarder above already ships:
`{source="proxmox", unit="tappaas-guest-memory"}`.

- **VMs:** `used` = total − the guest's MemAvailable, read from the balloon's
  `guest-stats` through Proxmox's monitor API. Nothing logs into a guest. A guest
  without balloon stats (the FreeBSD firewall, Windows) reads `measured=0`.
- **Containers:** `used` = the cgroup's `memory.current` − `file`.
- **Pressure:** PSI `some avg60` of the guest's host cgroup, and the guest's own
  OOM kills, direct reclaims and allocation stalls (counters since its boot).

About 20 lines a minute for a 20-guest site; within the 30-day retention.

`guest-memory-report.sh [window]` (default `7d`) turns a window into per-guest
peak, p99 and average, the pressure seen, and a suggested size by the rule written
in its header. In Grafana: `{unit="tappaas-guest-memory"} | logfmt | unwrap used`.

To remove the sampler from a node:

```
ssh root@<node>.mgmt.internal "systemctl disable --now tappaas-guest-memory && rm /etc/systemd/system/tappaas-guest-memory.service /usr/local/sbin/tappaas-guest-memory && systemctl daemon-reload"
```

> **Security note:** OPNsense and Proxmox syslog streams include filter logs, VPN auth
> events, sshd auth attempts, and other sensitive data. Today both use plain TCP, which
> is acceptable inside the `mgmt` zone with no rogue switches. Moving to RFC 5425 over
> TLS on tcp/6514 is in the v2 backlog (needs a TLS cert on `logging.mgmt.internal` and
> a `tls_config` block on Alloy's `loki.source.syslog` listener).

## Journal shipping from other VMs — `logging:logs` (#770)

A module declares `integratesWith: ["logging:logs"]`. While logging is deployed,
`update-os.sh` writes `/etc/nixos/tappaas-logging.nix` on its VM (the mothership's
`tappaas-self-rebuild.sh` writes its own), and the NixOS baseline imports it. The
fragment comes from one renderer, `tappaas-cicd/lib/log-shipping.sh`, so every VM runs
the same pipeline:

1. **Drop** units that handle secrets — `generate-.*-secrets.*` everywhere, plus the
   module's `config."logging:logs".dropUnits` (identity: the Authentik secret units;
   tappaas-cicd: `opnsense-controller`, `setup-caddy`).
2. **Scrub** secret assignments, `curl -u user:pass` and `Authorization:` headers (only
   the captured value is replaced, #724).
3. **Label** `host` (the vmname), `zone`, `unit`, `severity`, `job="systemd-journal"`.
4. **Push** to `logging.mgmt.internal:3101`, the push-only receiver.

Why a second port: 3100 is Loki's whole API — queries, deletes — and must never be open to
an app zone. 3101 accepts pushes only.

Who may push (#165 §1): each VM has a credential of its own, username = its vmname. The
mothership keeps them (`~tappaas/.loki-push/<host>`) and writes the VM's copy to
`/etc/secrets/tappaas-logging-push`, which systemd hands to Alloy (`LoadCredential`). nginx
on this VM checks it against `/etc/loki-auth/push.htpasswd` (synced by `logging:logs` and
`update.sh`) and passes the username on as the tenant; Alloy here makes that the line's
`host`, whatever the line said. So a VM writes as itself and nobody else. 3100 takes one
admin credential (`~tappaas/.loki-admin-password`, user `tappaas`;
`log_shipping_curl_admin` in `lib/log-shipping.sh`).

Why the firewall lets an app zone in: mgmt's `pinhole-allowed-from` is empty, so no zone
may pinhole into it. `services/logs/pinhole.json` says `"fromZones": "any"` — honoured for
foundation providers only — and the pinhole is still per consumer VM (its own alias to
`tm_logging`) and to 3101 alone. A consumer outside mgmt needs `network:rules` to carry it.

The fragment also runs `tappaas-log-heartbeat.timer`: one line every 5 minutes, so a
healthy VM is never silent and HostSilent (no line for 15 minutes) means the VM is down or
not shipping. Without it, near-idle VMs that log only on the hour raised HostSilent and its
resolve every hour.

No file, no Alloy: a module that does not declare `logging:logs`, or a site without
logging, ships nothing. NixOS guests only for now.

## Metrics — `logging:metrics`

Numbers over time — CPU, memory, disk, network, pressure — beside the logs, in
Prometheus on this VM. What is collected is the site's choice: `site.json`
`performance.level` (`off` on a small site, `basic` on a medium or large one) and
`performance.retentionDays` (7, 15 or 30 days by size).

```
 Proxmox cluster ─ metric server (OTLP/HTTPS, cluster credential) ─┐
 nodes' sampler  ─ OTLP/HTTPS (cluster credential) ────────────────┤  nginx :3120
 PBS             ─ metric server (InfluxDB v2, its token) ─────────┘  user → X-Tappaas-Host
                                                                      │
   Alloy: otlp / influxdb receiver → host := the user → prometheus exporter
          → identity.stamp (from the CMDB) → remote_write
                                                                      │
   Prometheus :3122 (retention by site) ── 5-min recording rules ──► Prometheus :3123 (90 days)
```

- **Who pushes.** The cluster's *external metric server* (`/etc/pve/status.cfg`,
  type `opentelemetry`, id `tappaas`) sends every node's and every guest's CPU,
  memory, disk and network every 10 seconds, as `proxmox_node_*`, `proxmox_vm_*`,
  `proxmox_storage_*`. The nodes' `tappaas-guest-memory` sampler (already there for
  the logs) also pushes, once a minute, each guest's working set and pressure
  (`tappaas_guest_memory_*`, `tappaas_guest_*_total`), the node's PSI
  (`tappaas_node_psi_{some,full}_avg60{resource}`) and its ZFS pools' wait
  (`tappaas_zpool_{read,write}_wait_seconds{pool}`); its config is
  `/etc/pve/priv/tappaas-metrics.conf`, and without it the sampler only logs. PBS's
  InfluxDB metric server (id `tappaas`) sends its host and datastore numbers.
  `lib/metrics-shipping.sh` sets all three; `tappaas-metrics-target.sh <pve|pbs|all>
  <status|apply>` is how logging's update, site-manager's reconcile (the cluster) and
  backup-manager's reconcile (PBS) converge them, and level `off` removes them.
- **Identity.** nginx passes the authenticated user on; Alloy writes it as `host`
  over anything the sender said. Then a module the mothership renders from the CMDB
  (`/etc/alloy-identity/identity.alloy`, re-read by Alloy when it changes) drops
  whatever identity labels the sender wrote and sets `tappaas_ci_id`,
  `service_instance_id` (both the CI id), `service_name` (the CI's name),
  `service_namespace` and `deployment_environment_name` (its environment): by `host`
  for what a host says about itself, by `vmid` for what a node says about a guest.
  The cluster's credential (`pvecluster`) speaks for its nodes — the cluster is one
  trust domain, each node root on the others, and its metric server is one setting
  for all — so its series take `host` from their `node` label, only among the nodes
  the CMDB knows; anything else it sends is dropped. Only a node may send series with
  a `vmid`. A host the CMDB does not know keeps its `host` and no CI id.
- **Credentials** are the logs' store (`~tappaas/.loki-push/<user>`, nginx's
  `push.htpasswd`): one per pushing host, for both. PBS cannot send basic auth, so
  its token (`<instance>:<secret>`) is matched by nginx against
  `/etc/loki-auth/influx-tokens.map`, which therefore holds that one secret in clear
  (root:nginx 0640, push only).
- **Resolution.** Stored as sent: Proxmox every 10 s, the sampler every minute.
- **Trends.** Recording rules every 5 minutes (`trend5m:<metric>:avg` for gauges,
  `:rate` for counters, the list in `logging.nix`) go by remote_write to a second
  Prometheus that keeps 90 days and nothing else.
- **Retention** is a flag of Prometheus's: the mothership writes
  `/etc/tappaas-metrics/prometheus.env` and restarts Prometheus when it changes, so
  no rebuild is needed for it.
- **The level, per module.** `performance.level` (`off`, `basic`, `service`) and
  `performance.resolution` (`normal`, `fine`) are set at three scopes, most specific
  wins: `site.json` (`site-manager site modify --set performance.level=…`),
  `config/environments/<env>.json` (`environment-manager modify <env> --set …`) and
  the instance (`module-manager module modify <m> --set performance.level=…`,
  `--unset performance.level` to inherit). On top, one CI can be raised for a time:
  `health-manager perf <ci> --level basic|service|trace --until 2h` (`--until` is
  required; `trace` exists only this way and reads as `service` until traces are
  collected), `perf stop <ci> [--purge]`, `perf list [--json]`. Raises are kept in
  `config/performance-raises.json` and recorded on the CI (`investigation`, set and
  unset, each a CMDB change); `health-manager emit`, after every assess, ends those
  past their time. `tappaas-metrics-target.sh guest <m> status` prints a module's
  effective level and where it comes from.
- **A guest's own view.** Every guest that ships its journal (`logging:logs`) runs
  Alloy; its static config imports `/var/lib/alloy-perf/perf.alloy`, a runtime file
  the mothership renders for the guest's effective level (`render_metrics_alloy`)
  and Alloy re-reads when it changes. So adding the import is one OS rebuild per
  guest; every level change after it is a file write, no rebuild. `off` is an empty
  pipeline. `basic`: `prometheus.exporter.unix` (cpu, load, memory, pressure,
  filesystems, disks, NICs) through a keep-list, every minute (15 s at `fine`),
  pushed as OTLP to :3120 with the guest's own logs credential, so the store sets its
  identity as for everything else. `service` adds TCP, socket, vmstat and file
  handle counters. A container drops its node's pressure and boot time, which its
  /proc shows. A guest that ships no logs has no Alloy and collects nothing of its
  own; its node still reports its outside view. Deleting a guest's `logging:logs`
  stops its own numbers with its client, and says so; its outside view stays.
- **Purge.** `health-manager perf purge <ci>` (or `perf stop <ci> --purge`) deletes
  the CI's series from both instances (`delete_series`, `clean_tombstones`; the admin
  API is on, reached only through :3121 with the admin credential).
- **PBS** names its measurements without a prefix; on their own path through Alloy
  they become `pbs_*` (`pbs_cpustat_total`, `pbs_datastore_used`, …).
- **Cost.** `tappaas-metrics-target.sh cost` estimates the series, disk a day and
  store RAM of the levels in force, from hrossen's measurements; logging's update
  warns when they do not fit the VM's memory or half its free disk over the
  retention. Removing logging (`delete.sh`) removes the Proxmox and PBS targets.
- **Traces (`logging:traces`).** Grafana Tempo on this VM, local filesystem, 72
  hours, localhost only (3200 API, 4317 OTLP from this VM's Alloy). **Idle**: no
  unit wants it; the mothership starts it while some CI is raised to trace
  (`health-manager perf <ci> --level trace --until <time>`; `--until` is required
  and trace exists only this way) and stops it when the last such raise ends
  (`tappaas-metrics-target.sh traces status|apply`, also run by every raise, its
  expiry and `site apply`). Spans come in on the push port, `/v1/traces` on :3120,
  with the same credential per host as metrics; Alloy writes the authenticated user
  as `tappaas.host` (this VM's own, over the local gRPC receiver on 3127, are
  `logging`), lifts it onto the resource, and the mothership's identity module
  (`stamp_traces`) deletes what the sender said about `tappaas.ci.id`,
  `deployment.environment.name`, `service.namespace`, `host.id` and sets them, and
  `host.name`, from the CMDB; `service.name` stays the sender's software. Tail
  sampling keeps every trace with an error, every one slower than a second, and a
  tenth of the rest. Grafana's own spans are the switchable sender today: on while
  the logging CI is raised to trace (`/etc/tappaas-metrics/grafana-otlp-address`,
  Grafana restarted on a change), and its log lines then carry `traceID=`.
- **Metric → trace → log.** Prometheus keeps exemplars (`exemplar-storage`) and
  the Prometheus data source opens an exemplar's trace in Tempo; a Loki line with
  `traceID=`/`"trace_id":` opens its trace (a derived field); a span opens its
  host's logs around it and the CI's metrics (`tracesToLogsV2`, `tracesToMetrics`).
  The console's CI panel links a CI at trace to Grafana's Explore on Tempo,
  searching `{ resource.tappaas.ci.id = "<id>" }`.
- **What cannot trace yet.** Caddy on OPNsense has the `tracing` handler, but
  `os-caddy` generates every published site and has no option for it, and its
  `caddy.d` extension adds only global options and sites of its own; authentik
  (2026.8) ships no OpenTelemetry exporter, only Sentry. A trace raise on them is
  recorded and starts Tempo, and nothing of theirs arrives; identity's
  `traces.otlp` declaration waits for an authentik that exports OTLP.
- **In Grafana:** data sources *Prometheus* and *Prometheus trends*, e.g.
  `proxmox_vm_cpu{service_name="nextcloud"}`,
  `tappaas_guest_memory_used_bytes{service_namespace="rossen"}`,
  `tappaas_node_psi_some_avg60{resource="io"}`.

### The `service` level (ADR-046 P3)

What `service` adds, each only while the object's module is at `service` (or traced):

- **Published services, from Caddy.** OPNsense's Caddy has no metrics setting; two files in
  its documented extension directory (`/usr/local/etc/caddy/caddy.d/tappaas-metrics.{global,conf}`)
  turn on per-host counting and serve the numbers on the firewall's mgmt address, port 9180, to
  the mothership only (`lib/service-metrics.sh`, `tappaas-metrics-target.sh caddy apply`; a
  Caddyfile that does not validate with them takes them out again). The mothership's Alloy
  scrapes them, keeps `caddy_http_request_duration_seconds_{bucket,count,sum}` for the routes at
  `service`, moves the host to `tappaas_route`, buckets the status code (`5xx`) and drops every
  other label.
- **Black-box probes**: the same Alloy probes each of those routes over HTTPS once a minute
  (`probe_success`, `probe_duration_seconds`, `probe_http_status_code`,
  `probe_ssl_earliest_cert_expiry`); a redirect, 401 or 403 counts as answering.
- **A module's own exporters**, as a foundation module declares them under `performance.exporters`
  (`name`, `port`, `path`, `level`, `keep`): its guest's Alloy scrapes them on localhost and keeps
  the listed names only. A module from any other source may not declare them (module-manager
  refuses it). This VM's own exporters (Grafana, Loki, Alloy, both Prometheus) are scraped by its
  receiver Alloy from `/etc/alloy-identity/self.alloy`, a module the mothership renders.
- **Identity.** The controller's series about a route carry `tappaas_route`; the identity module
  gives them the proxy-route CI's identity and `tappaas_module`, only when the mothership sent them.
- **Dashboards.** Grafana provisions one dashboard per class from `dashboards.nix`
  (`tappaas-node`, `tappaas-guest`, `tappaas-pool`, `tappaas-datastore`, `tappaas-service`; the
  CI in the `ci` variable, a pool by `node` and `pool`), and one per declaring module
  (`tappaas-mod-<module>`) from `/var/lib/grafana-tappaas/dashboards`, written by the mothership.
  The console's Grafana link opens the class's dashboard at the CI.

## Useful Loki queries

In Grafana's Explore tab, pick the **Loki** datasource:

| What you want to see | LogQL |
|---|---|
| Everything from one VM | `{host="tappaas-cicd"}` |
| Last update-tappaas run | `{host="tappaas-cicd", unit="update-tappaas.service"}` |
| Errors across the cluster | `{job="systemd-journal"} \|= "error"` |
| OPNsense events | `{source="opnsense"}` |
| OPNsense firewall block/pass | `{source="opnsense", unit="filterlog"}` |
| All Proxmox node activity | `{source="proxmox"}` |
| One node's PVE web UI access | `{source="proxmox", host="tappaas1", unit="pveproxy"}` |
| PVE cluster events on all nodes | `{source="proxmox", unit=~"pve-cluster.*\|corosync.*"}` |
| Auth failures cluster-wide | `{} \|= "Failed password"` |

`logcli` is also installed on the VM if you prefer the CLI.

## Alerting from the logs (#126)

Every host's logs arriving here are only useful if something reads them. Grafana's
alerting evaluates LogQL rules over them and posts what fires to
**`tappaas-alert-receiver`** on the mothership (TCP 9095, bearer token).

**Where the rules live.** Each module ships its own rules in `<module>-alerts.json`
beside its module JSON: it names a line pattern, a window and a kind, never LogQL, and
the mothership builds the query over that module's own hosts
(`tappaas-cicd/scripts/tappaas-alert-rules.py`). The rules go into Grafana through its
provisioning API, one group per module in the folder *TAPPaaS modules*, when the module's
`logging:logs` service is installed or updated, and all of them again on this module's
update (a rebuilt Grafana gets them back). The foundation's own rules are in the module
they belong to: `pvehost` (DiskErrors, LanLegDown), `cluster` (QuorumLost, HaFencing,
ReplicationFailed, RootKeyChanged, HaStuck), `network` (FirewallCertChanged), `backup`
(BackupFailed) and this module (OomKill, HostSilent). Only the Heartbeat, the contact
point and the policy are built in `logging.nix`. A rule's host list comes from `config/`,
so a deleted instance raises no HostSilent. A rule may carry its own mail (templates),
the support bundle, and up to 20 anonymized log lines where `site.json`
`alerts.includeLines` is on.
The receiver mails through `site-notify.sh`, the path a failed sweep uses (#651), so
the subject reads `[TAPPaaS <site>] ALERT: <rule> on <host>`. Every notice is a line
in `config/alerts.log` on the mothership.

| Rule | Kind | Fires on |
|---|---|---|
| `QuorumLost` | event | corosync "non-primary component", pmxcfs "node lost quorum" |
| `HaFencing` | event | watchdog expiry, a node being fenced |
| `HostSilent` | state | a host that logged in the hour before and not in the last 15 minutes |
| `DiskErrors` | state, daily | ZED pool events (`class=checksum\|io…`), smartd sector warnings, kernel I/O errors — last 24 h, mailed once a day |
| `BackupFailed` | event | vzdump "Backup of VM … failed" |
| `OomKill` | event | the kernel's "Out of memory: Killed process" (subject: *Out of Memory Kill*) |
| `RootKeyChanged` | event | a key added to or removed from root's `authorized_keys` on the nodes — the nodes' `tappaas-rootkeys-check` (5-minute timer) compares key fingerprints and names each one; one alert for the cluster-wide file. Rewrites with the same keys (Proxmox's `pvecm updatecerts`) do not alert; the audit trail still records every write |
| `HaStuck` | state | the mothership's `check-ha-health` (5-minute timer) logging `tappaas-ha-stuck:`: a node in HA maintenance past 30 minutes, or an HA service in a transitional state past 10; `ha_stuck` names it |
| `FirewallCertChanged` | event | the mothership's `check-firewall-cert` (hourly) logging that the firewall's API certificate changed — a rebuild, a renewal, or something answering as the firewall — or expires within 30 days (once a day). Controllers skip verifying that certificate (#310) |
| `LanLegDown` | event | a leg of a node's bonded lan uplink (`lanbond`) the kernel's bonding driver took out more often than it took back within five minutes — a leg lost, not a flap that recovers (a node's boot flaps a DAC leg up, down and up within a second, and those lines arrive with one timestamp, so the rule counts per leg rather than reading their order). The node keeps running on the other leg(s), so nothing else shows it; `site-manager node network show <node>` says which port and what it reaches |
| `ReplicationFailed` | state | a storage replication job failed in two runs within the hour (one failed run while a node reboots does not mail). The mail names the job (`replication_job`, `<vmid>-<n>`); it clears after an hour without the error |
| `Heartbeat` | heartbeat | logs arriving at all — never mailed, see below |

- **event** — something happened. It "resolves" only because its window moved on,
  so a resolve is not mailed. **state** — something is so; its resolve is mailed, as a
  reply to the alert (the condition `grafana:<rule>:<host>`, #883), and only if that
  alert was mailed.
- **A node down is one mail.** A node that dies silences every guest on it that ships
  logs, and each would be its own HostSilent ALERT and RESOLVED. Before a HostSilent is
  mailed, the receiver asks the cluster (`tappaas-cluster-state.sh`: nodes, guests, the HA
  manager's journal) whether its host is an offline node or a guest on one. If so, the
  first such alert mails `ALERT: node <node> is down (…)`, listing the guests down with
  it, the HA-protected guests the HA manager moved and to which node, and those it has
  not moved (yet). Later HostSilents of that node are recorded in its incident
  (`/var/lib/tappaas/node-down/<node>.json`) and in `alerts.log`, not mailed. The mail
  repeats every 4 h while the node stays down. When the node is back, one `RESOLVED: node
  <node> is back` answers it, naming any guest that is not running again. Such a guest
  keeps its own HostSilent, which then mails as usual. If the cluster cannot be asked,
  every HostSilent is mailed on its own.
- **Many hosts silent at once is one mail.** When the nodes are up, a shared cause (the
  firewall restarting, its rules, the logging VM) still silences every guest that ships
  logs through it. So a HostSilent waits 2½ minutes before it is mailed. When three hosts
  have gone silent within ten minutes, one `ALERT: N hosts stopped logging at once` goes
  out naming them, and the held ones and the ones after fold into it
  (`/var/lib/tappaas/silent-burst.json`). When they all log again, one `RESOLVED: N hosts
  log again` answers it. A host mailed on its own before that keeps its own ALERT and
  RESOLVED.
- **A planned restart is quiet.** An update that is allowed to restart a guest opens a
  maintenance window first (`tappaas-maintenance.sh`): an hour, for the guest's own host,
  or for the whole site when it restarts the firewall. The cluster update opens one for a
  node, for ten minutes, before it upgrades packages that restart the cluster service
  (corosync, knet, pve-cluster, the HA services): the restart takes the node out of quorum
  for a few seconds while the others keep it. A HostSilent or QuorumLost from inside a
  window is recorded, not mailed, and so is its RESOLVED.
- **The VMs' log shippers reconnect.** Alloy pushes over HTTP/1.1, so a push that times
  out closes its connection and the retry opens a new one. Over HTTP/2 the shippers kept
  waiting on connections a restarted firewall had dropped, and their logs stalled for
  half an hour.
- A rule declared with `bundle = true` — QuorumLost, HaFencing, HostSilent, BackupFailed,
  OomKill, ReplicationFailed, HaStuck, LanLegDown — carries a support bundle: the
  cluster's state and the site's anonymized configuration from half an hour before it
  fired (`tappaas-support-bundle.sh`, see the tappaas-cicd scripts README). The mail
  says to forward it to `site.json` `supportEmail`.
- Grafana groups per rule and host and repeats a firing alert every 4 h (DiskErrors
  every 24 h). Rules match `{source="proxmox"}` where they can: this VM's own journal
  carries Loki's and Grafana's logged query texts, which an unanchored all-hosts rule
  matches (OomKill did, until it was anchored).
- **The alerting watches itself.** `Heartbeat` fires while logs arrive and rules run;
  its webhook, every 10 minutes, proves the whole path to the mothership. The receiver
  records it in `/var/lib/tappaas/alert-heartbeat` and mails nothing. A timer on the
  mothership, `tappaas-alert-watchdog` (every 5 minutes), mails "log alerting is down"
  when the heartbeat is 35 minutes old — so a dead logging VM, Grafana, Loki or a token
  mismatch does not leave the site silently unwatched. Before it mails it asks the
  logging VM for Loki's `/ready` and Grafana's `/api/health`, and the subject names
  which part does not answer.
- **A query that cannot run is not an alert of the rule's own (#905).** Every rule has
  `execErrState = KeepLast`: when Loki or Grafana's own database cannot answer (the
  logging VM's backup stalls its disk for minutes), the rule keeps its last state — no
  "DatasourceError" mail under, say, LanLegDown's name, and a firing DiskErrors does not
  resolve. The Heartbeat alone has `OK`, so a Loki that stays down stops it and the
  watchdog's one mail names Loki. The receiver counts only a firing `Heartbeat` as a
  heartbeat, never a Grafana error alert that carries its labels.
- The token: generated on the mothership (`/etc/secrets/tappaas-alert-token`),
  copied here by `update.sh` (`/etc/secrets/grafana-alert-webhook-token`), read by the
  contact point with `$__file{…}`. `test.sh` Check 9 asserts the rules and contact
  point are provisioned, Check 10 that the receiver accepts the token.
- **Coverage:** only hosts that ship logs here are watched — the Proxmox nodes, the
  firewall, the mothership, this VM, and every NixOS VM declaring `logging:logs` (#770).
- **The only channel.** Proxmox's own notification mails (smartd and ZED system mail,
  backup jobs, replication, fencing, updates) are switched off by `cluster/update.sh`
  Step 5c, which disables PVE's built-in `default-matcher`, so one condition does not
  arrive twice from two systems. Verified: a mail to root on a node reaches
  `proxmox-mail-forward`, which logs "skipping disabled matcher" and sends nothing on.

## Retention & sizing

- Default retention: **30 days** (configured in `logging.nix` as `retentionHours`).
- 32 GB disk is comfortable for the mothership + OPNsense alone.
- When you add more clients, either grow the disk (`pvesm`/`qm resize`) or shorten
  retention.
- Loki only stores compressed chunks; sizing rule of thumb: ~1–5 GB / VM / 30 days for
  typical syslog volume.

## Backups

Covered by the standard `backup:vm` dependency (PBS snapshot). Loki state under
`/var/lib/loki` is captured as part of the VM image. Log gaps during a restore are
expected and acceptable.

## Trust model

- Loki and Alloy's receiver listen on localhost only; nginx is the way in (#165 §1).
- tcp/3100 (query, delete, everything) needs the admin credential, which only the
  mothership holds. Without it a mgmt-zone VM gets 401.
- tcp/3101 needs the pushing VM's own credential and accepts pushes only. A VM can write
  lines under its own `host` and no other — the label is set from the credential — and
  cannot read or delete anything. A stolen credential lets its holder write as that VM.
- tcp/3120 (metrics) needs a pushing host's credential, over TLS only, and accepts
  pushes only; the series' identity is set from the credential and the CMDB (see
  Metrics). tcp/3121 (metrics query) needs the admin credential, as 3100.
- Credentials are HTTP basic auth over plain HTTP inside the site network: someone who
  can read traffic on the path can lift them. TLS would close that; it needs the TAPPaaS
  CA (the syslog-over-TLS issue).
- Alloy accepts unauthenticated RFC 5424 syslog on tcp/1514 from anywhere routable
  in mgmt.
- Grafana web UI is on tcp/3000; the only intended access path is through Caddy in the
  firewall VM at `logging.<tappaas.domain>`.

Mitigations in place:

- The journal scrapes on both `tappaas-cicd` and `logging` **drop** log lines from
  credential-handling units (`opnsense-controller.*`, `setup-caddy.*`,
  `generate-*-secrets.*`) and **scrub** common secret patterns (`token=`, `password=`,
  `Authorization:`, `curl -u`) before shipping to Loki. The scrub stages replace only
  their capture group, which must be the secret itself — a `replace` value is taken
  literally and `$1` is **not** expanded. Writing them the other way round is what made
  them silently useless from their introduction until #724; the regression test for that
  is a `logger` line with a known value, checked for by querying Loki.
- Grafana admin password is generated to a root-only one-shot file, never to the journal.
- Grafana's `secret_key` — which encrypts Grafana's own database secrets — is generated
  per site into `/etc/secrets/grafana-secret-key` (0600 `grafana:grafana`) and read through
  a `$__file{}` provider. 26.05 removed this option's default, which was one constant
  shared by every NixOS install (#722). **It cannot be rotated**: a new key makes anything
  already encrypted under the old one unreadable, and 26.05 ships no supported rotation
  path. The module's `backup:vm` snapshot covers it.
- Loki/Grafana/Alloy metrics endpoints bind to localhost where possible.

## Known limitations / v2 backlog

- **Loki authentication**: ✅ done (#165 §1) — nginx with a credential per pushing VM on
  3101 and an admin credential on 3100; `host` is set from the credential. Not TLS yet.
- **Grafana auth**: ✅ OIDC against `identity:identity` is wired (from AndreasJe's work
  on pr-513, adapted). `logging.json` declares the contract — `providesAdminRole`, the
  `/login/generic_oauth` redirect path, `secretsEnv` and `configureService`; Authentik
  mints the client, `logging-configure-oidc.service` resolves the endpoints from the
  provider's own discovery document, and Grafana reads all five values through its
  `$__file{}` substitution. Members of `logging-admins` land in `GrafanaAdmin`, everyone
  else who can sign in gets `Viewer`.

  identity is an optional integration (`integratesWith`, #701): a site without it installs
  logging and signs in to Grafana with its local admin. Grafana's OIDC switch is the file
  `/etc/secrets/logging-oidc-enabled` — `false` until `logging-configure-oidc` has real
  credentials, then `true` — so SSO, and its auto-login, come on only when there is an
  Authentik behind them.

  Two things follow from the public domain rather than being set independently: the
  provider only exists where the site publishes Grafana (no `proxyDomain`, no redirect
  URI for Authentik to call back to), and `cookie_secure` moves with it — a secure
  cookie over plain `http://logging.<zone>.internal:3000` is never stored, and the login
  bounces back to `/login` looking exactly like bad credentials.

  Still open: the local `admin` user remains. Removing it is a separate step, and wants
  a way back in when Authentik is the thing that is down.
- **Syslog over TLS**: wire Alloy's `loki.source.syslog` listener with `tls_config` and expose
  6514/tcp; deprecate 1514/tcp once OPNsense is moved over.
- **Automate OPNsense syslog target**: ✅ done in v1 — `syslog-manager` is wired into
  `update.sh` and runs on every install/update.
- **Metrics**: ✅ Prometheus (`logging:metrics`, see Metrics), levels per site,
  environment and module, timed raises, the guests' own view. Still open: the
  published services' numbers and module exporters (`service`), traces, thresholds
  and alerting on metrics, a remote_write path with an identity (guests push OTLP).
- **A consumable logging service**: ✅ done — `logging:logs` (#770), see "Journal
  shipping from other VMs" above. Still open: Debian, HAOS, LXC and Windows guests.
