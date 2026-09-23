# logging — Design notes

Implementation and reference detail for the logging module (Loki + Grafana + Alloy).
For the catalog entry see [README.md](./README.md); for installation see
[INSTALL.md](./INSTALL.md); for test coverage see [TEST.md](./TEST.md).

## Architecture

- **Grafana Loki** — log store, single-binary mode, filesystem-backed, 30-day retention.
- **Grafana** — web UI, port 3000, fronted by Caddy at `logging.<tappaas.domain>`.
- **Grafana Alloy** (on this VM) — tails the local journal **and** receives syslog from
  OPNsense on tcp/1514 and from the Proxmox nodes on tcp/1515.
- **Alloy clients** (on every other VM) — push their journal to
  `http://logging.mgmt.internal:3100`.

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
| 3100 | TCP | Loki HTTP push/query | Alloy clients on other VMs |
| 1514 | TCP | Syslog ingest (RFC 5424) → `source=opnsense` | OPNsense firewall |
| 1515 | TCP | Syslog ingest (RFC 5424) → `source=proxmox` | Proxmox nodes (rsyslog) |
| 9080 | TCP | Alloy metrics and component UI (localhost only) | local |

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

> **Security note:** OPNsense and Proxmox syslog streams include filter logs, VPN auth
> events, sshd auth attempts, and other sensitive data. Today both use plain TCP, which
> is acceptable inside the `mgmt` zone with no rogue switches. Moving to RFC 5425 over
> TLS on tcp/6514 is in the v2 backlog (needs a TLS cert on `logging.mgmt.internal` and
> a `tls_config` block on Alloy's `loki.source.syslog` listener).

## Setting up an Alloy client on another VM

Add to that VM's NixOS config. Alloy's NixOS module is deliberately thin — it enables the
service and points it at a config directory — so the pipeline itself is written in Alloy's
own configuration language and placed in `/etc` (not the store), which lets Alloy reload it
in place on a `nixos-rebuild switch`:

```nix
services.alloy = {
  enable = true;
  # Localhost only: Alloy's HTTP server carries metrics and the component UI.
  extraFlags = [
    "--server.http.listen-addr=127.0.0.1:9080"
    "--disable-reporting"
  ];
};

environment.etc."alloy/config.alloy".text = ''
  discovery.relabel "journal" {
    targets = []

    rule {
      source_labels = ["__journal__systemd_unit"]
      target_label  = "unit"
    }
  }

  loki.source.journal "journal" {
    max_age       = "12h0m0s"
    relabel_rules = discovery.relabel.journal.rules
    forward_to    = [loki.write.default.receiver]
    labels        = {
      host = "<this-vm-hostname>",
      job  = "systemd-journal",
    }
  }

  loki.write "default" {
    endpoint {
      url = "http://logging.mgmt.internal:3100/loki/api/v1/push"
    }
  }
'';
```

The service reads the journal through the module's `SupplementaryGroups = [ "systemd-journal" ]`
and keeps its read positions under its systemd `StateDirectory` (`/var/lib/alloy`) — there is
no positions file to declare, as there was with promtail.

**Shipping credentials-handling units?** Add a `loki.process` between the source and the
write, with `stage.match { action = "drop" }` for those units and `stage.replace` stages for
secret patterns — see the blocks in `logging.nix` and `tappaas-cicd.nix`. Check any config
before deploying it: `alloy validate /etc/alloy/config.alloy`.

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
- When you add more clients, either grow the disk (`pvesm`/`qm resize`) or shorten
  retention.
- Loki only stores compressed chunks; sizing rule of thumb: ~1–5 GB / VM / 30 days for
  typical syslog volume.

## Backups

Covered by the standard `backup:vm` dependency (PBS snapshot). Loki state under
`/var/lib/loki` is captured as part of the VM image. Log gaps during a restore are
expected and acceptable.

## Trust model (v1)

The mgmt zone is the trust boundary for the logging stack:

- Loki accepts unauthenticated pushes on tcp/3100 from anything routable in the mgmt
  zone. A compromised mgmt-zone VM could write spoofed-label logs or query/delete
  arbitrary log history.
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

- **Loki authentication**: turn on `auth_enabled = true` with per-tenant `X-Scope-OrgID`
  and either basic-auth or mTLS on tcp/3100. Alloy clients on each VM ship a tenant
  ID so spoofed-host labels are rejected.
- **Grafana auth**: ✅ OIDC against `identity:identity` is wired (from AndreasJe's work
  on pr-513, adapted). `logging.json` declares the contract — `providesAdminRole`, the
  `/login/generic_oauth` redirect path, `secretsEnv` and `configureService`; Authentik
  mints the client, `logging-configure-oidc.service` resolves the endpoints from the
  provider's own discovery document, and Grafana reads all five values through its
  `$__file{}` substitution. Members of `logging-admins` land in `GrafanaAdmin`, everyone
  else who can sign in gets `Viewer`.

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
- **No Prometheus / Alertmanager yet**: the same VM can host them when metrics-side
  alerting is added.
- **`provides` is empty in v1**: the module does not yet expose a consumable logging
  service. v2 adds `provides: ["logging"]` alongside the service-hook scripts so other
  modules can `dependsOn: ["logging:logging"]` and receive an Alloy client
  automatically.
- **Service-hook scripts not yet written**: `services/logging/install-service.sh`,
  `update-service.sh`, `test-service.sh`, and `delete-service.sh` need to be authored so
  consumers declaring `dependsOn: ["logging:logging"]` get the Alloy client installed
  and verified automatically (same drop/scrub pipeline, per-consumer `host=` label).
- **Service hooks must open firewall pinholes**: a consumer in a non-mgmt zone (e.g.
  `srv`, `dmz`) cannot reach `logging:3100` until an OPNsense rule permits it. The
  `install-service.sh` hook should call into `opnsense-controller` to add a
  per-source-zone pinhole to `logging` on tcp/3100, and the corresponding
  `delete-service.sh` should tear it down. Without this, declaring the dependency from
  anywhere outside mgmt produces silently-dropped logs.
