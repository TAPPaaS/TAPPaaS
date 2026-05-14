# logging — Centralized Logging for TAPPaaS

Loki + Grafana + Promtail stack. Acts as the central log sink for every TAPPaaS
VM and for the OPNsense firewall.

## Architecture

- **Grafana Loki** — log store, single-binary mode, filesystem-backed, 30-day retention.
- **Grafana** — web UI, port 3000, fronted by Caddy at `logging.<tappaas.domain>`.
- **Promtail** (on this VM) — tails the local journal **and** receives syslog from OPNsense on tcp/1514.
- **Promtail clients** (on every other VM) — push their journal to `http://logging.mgmt.internal:3100`.

```
   ┌──────────────┐   journal     ┌────────────────────────────────┐
   │ tappaas-cicd │──Promtail────►│                                │
   ├──────────────┤               │   logging (this VM)    │
   │ identity     │──Promtail────►│   ┌──────────┐    ┌─────────┐  │
   ├──────────────┤               │   │ Promtail │───►│  Loki   │  │
   │ <app VMs>    │──Promtail────►│   └──────────┘    └────┬────┘  │
   ├──────────────┤               │                        ▼       │
   │ OPNsense     │──syslog 1514─►│                   ┌─────────┐  │
   │ (firewall)   │  RFC 5424 TCP │                   │ Grafana │◄─┼── admin
   └──────────────┘               │                   └─────────┘  │
                                  └────────────────────────────────┘
```

## VM facts

| Field | Value |
|---|---|
| VMID | 150 |
| Zone | `mgmt` |
| Cores / RAM / Disk | 2 / 2 GB / 32 GB |
| Storage | `tanka1` |
| `provides` | `logging` |
| Public URL | `https://logging.<tappaas.domain>` (via Caddy) |

## Ports

| Port | Proto | Purpose | Source |
|---|---|---|---|
| 22 | TCP | SSH | mgmt admins |
| 3000 | TCP | Grafana UI | Caddy on the firewall |
| 3100 | TCP | Loki HTTP push/query | Promtail clients on other VMs |
| 1514 | TCP | Syslog ingest (RFC 5424) → `source=opnsense` | OPNsense firewall |
| 1515 | TCP | Syslog ingest (RFC 5424) → `source=proxmox` | Proxmox nodes (rsyslog) |
| 9080 | TCP | Promtail metrics (localhost only) | local |

## Label scheme

Every log line in Loki carries at least these labels:

| Label | Values | Meaning |
|---|---|---|
| `job` | `systemd-journal` \| `syslog` | how it was ingested |
| `host` | `logging`, `tappaas-cicd`, `tappaas1`, `OPNsense.internal`, … | source machine |
| `source` | `opnsense`, `proxmox` | only on `job=syslog`; identifies the syslog sender |
| `unit` | `pveproxy.service`, `filterlog`, `sshd`, … | systemd unit or syslog program |
| `severity` | `info`, `warn`, `err`, `crit`, … | syslog severity |
| `facility` | `daemon`, `auth`, `kern`, … | syslog facility (only on `job=syslog`) |

## First-boot secrets

The Grafana admin password is auto-generated on first boot. The cleartext is
**never** echoed to the journal — instead it is written to a root-only one-shot
file. The journal-scrape pipeline also drops `generate-*-secrets` units as
belt-and-braces protection.

Retrieve the initial password, change it in the UI, then delete the file:

```
ssh tappaas@logging.mgmt.internal -- sudo cat /root/grafana-admin-password.initial
# log in to https://logging.<your-domain>/, change the password, then:
ssh tappaas@logging.mgmt.internal -- sudo rm /root/grafana-admin-password.initial
```

Grafana reads the password from `/etc/secrets/grafana-admin-password`
(`0600 grafana:grafana`).

## Syslog forwarding setup (automatic)

`update.sh` configures two syslog forwarders automatically on every
install/update — both are idempotent:

### OPNsense → `:1514` (source=opnsense)

`syslog-manager add-destination` creates/updates the OPNsense destination
matching the description `tappaas-logging`. Skipped when `firewallType=NONE`
in the module config (e.g. you're using pfSense/UniFi/etc.).

The destination is matched by description (`tappaas-logging`) for idempotency
— re-running the install or update updates the existing entry rather than
creating duplicates.

Inspect or manage the destination:

```
syslog-manager list --no-ssl-verify
syslog-manager delete-destination --description tappaas-logging --no-ssl-verify
syslog-manager reconfigure --no-ssl-verify
```

To verify, on `logging`:

```
sudo journalctl -u promtail -f
# then trigger an OPNsense event (e.g. ssh into the firewall and `logger -t test hi`)
# you should see Promtail accept the line and ship it to Loki
```

In Grafana, query `{job="syslog"}` or `{job="syslog", source="opnsense"}`.

### Proxmox nodes → `:1515` (source=proxmox)

For each node in `tappaas-nodes` from `configuration.json`, `update.sh`:

1. Installs `rsyslog` via `apt-get` if missing (Proxmox 9 / Debian 13 ships
   journald-only by default — no rsyslog).
2. Writes `/etc/rsyslog.d/99-tappaas-loki.conf` with an `omfwd` forwarder
   pointing at `logging.mgmt.internal:1515` (RFC 5424, octet-counted framing).
3. `systemctl enable --now rsyslog && systemctl restart rsyslog`.

rsyslog's default config wires `imjournal` to read systemd-journal, so all
journal entries flow through to Loki: PVE services (`pveproxy`, `pve-cluster`,
`pve-firewall`, `qemu-server`, `watchdog`), kernel messages, sshd, cron, etc.

To remove the rsyslog forwarder from a node (e.g. when retiring it):

```
ssh root@<node>.mgmt.internal "rm /etc/rsyslog.d/99-tappaas-loki.conf && systemctl restart rsyslog"
```

> **Security note:** OPNsense and Proxmox syslog streams include filter logs,
> VPN auth events, sshd auth attempts, and other sensitive data. Today both
> use plain TCP, which is acceptable inside the `mgmt` zone with no rogue
> switches. Moving to RFC 5425 over TLS on tcp/6514 is in the v2 backlog
> (needs a TLS cert on `logging.mgmt.internal` and a `tls_config` block in
> Promtail's syslog receiver).

## Setting up a Promtail client on another VM

Add to that VM's NixOS config:

```nix
services.promtail = {
  enable = true;
  configuration = {
    server = { http_listen_port = 9080; grpc_listen_port = 0; };
    positions.filename = "/var/lib/promtail/positions.yaml";
    clients = [{
      url = "http://logging.mgmt.internal:3100/loki/api/v1/push";
    }];
    scrape_configs = [{
      job_name = "journal";
      journal = {
        max_age = "12h";
        labels = { job = "systemd-journal"; host = "<this-vm-hostname>"; };
      };
      relabel_configs = [{
        source_labels = [ "__journal__systemd_unit" ];
        target_label = "unit";
      }];
    }];
  };
};
```

The `tappaas-cicd` mothership ships with this block pre-installed.

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

## Retention & sizing

- Default retention: **30 days** (configured in `logging.nix` as `retentionHours`).
- 32 GB disk is comfortable for the mothership + OPNsense alone.
- When you add more clients, either grow the disk (`pvesm`/`qm resize`) or shorten retention.
- Loki only stores compressed chunks; sizing rule of thumb: ~1–5 GB / VM / 30 days for typical syslog volume.

## Backups

Covered by the standard `backup:vm` dependency (PBS snapshot). Loki state under
`/var/lib/loki` is captured as part of the VM image. Log gaps during a restore
are expected and acceptable.

## Trust model (v1)

The mgmt zone is the trust boundary for the logging stack:

- Loki accepts unauthenticated pushes on tcp/3100 from anything routable in the
  mgmt zone. A compromised mgmt-zone VM could write spoofed-label logs or
  query/delete arbitrary log history.
- Promtail accepts unauthenticated RFC 5424 syslog on tcp/1514 from anywhere
  routable in mgmt.
- Grafana web UI is on tcp/3000; the only intended access path is through Caddy
  in the firewall VM at `logging.<tappaas.domain>`.

Mitigations in place:

- Promtail journal scrapes on both `tappaas-cicd` and `logging` **drop**
  log lines from credential-handling units (`opnsense-controller.*`,
  `setup-caddy.*`, `generate-*-secrets.*`) and **scrub** common secret patterns
  (`token=`, `password=`, `Authorization:`, `curl -u`) before shipping to Loki.
- Grafana admin password is generated to a root-only one-shot file, never to
  the journal.
- Loki/Grafana/Promtail metrics endpoints bind to localhost where possible.

## Known limitations / v2 backlog

- **Loki authentication**: turn on `auth_enabled = true` with per-tenant
  `X-Scope-OrgID` and either basic-auth or mTLS on tcp/3100. Promtail clients
  on each VM ship a tenant ID so spoofed-host labels are rejected.
- **Grafana auth**: integrate OIDC against the `identity` module so admins use
  their TAPPaaS SSO account; remove the local admin user.
- **Syslog over TLS**: wire Promtail's syslog receiver with `tls_config` and
  expose 6514/tcp; deprecate 1514/tcp once OPNsense is moved over.
- **Automate OPNsense syslog target**: ~~v1 ships `syslog-manager` and wires
  it into `update.sh` — automated on every install/update.~~ ✅ Done in v1.
- **No Prometheus / Alertmanager yet**: the same VM can host them when
  metrics-side alerting is added.
- **`provides` is empty in v1**: the module does not yet expose a consumable
  logging service. v2 adds `provides: ["logging"]` alongside the service-hook
  scripts so other modules can `dependsOn: ["logging:logging"]` and receive a
  Promtail client automatically.
- **Service-hook scripts not yet written**: `services/logging/install-service.sh`,
  `update-service.sh`, `test-service.sh`, and `delete-service.sh` need to be
  authored so consumers declaring `dependsOn: ["logging:logging"]` get the
  Promtail client installed and verified automatically (same drop/scrub
  pipeline, per-consumer `host=` label).
- **Service hooks must open firewall pinholes**: a consumer in a non-mgmt zone
  (e.g. `srv`, `dmz`) cannot reach `logging:3100` until an OPNsense rule
  permits it. The `install-service.sh` hook should call into `opnsense-controller`
  to add a per-source-zone pinhole to `logging` on tcp/3100, and the
  corresponding `delete-service.sh` should tear it down. Without this, declaring
  the dependency from anywhere outside mgmt produces silently-dropped logs.
