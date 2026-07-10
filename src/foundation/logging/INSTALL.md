# logging — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. The foundation bootstrap has finished (cluster, templates, network, tappaas-cicd) and
   the `backup` and `identity` modules are installed — `logging` is the last module of
   the standard foundation sequence.
2. You are on the mothership: `ssh tappaas@tappaas-cicd`.

> To deviate from the defaults in `./logging.json` (target node, storage, zone/VLAN,
> sizing, retention), copy the json to `/home/tappaas/config` and edit it before
> installing.

## Install

Normally installed by the foundation finisher, which runs backup → identity → logging in
order:

    rest-of-foundation.sh

Or by hand (`install-module.sh` reads `./logging.json` from the current directory):

    cd ~/TAPPaaS/src/foundation/logging && install-module.sh logging

VM creation happens via the `cluster:vm` service hook; the module's `install.sh` then
runs the same configuration as `update.sh` (NixOS rebuild plus the two syslog
forwarders — OPNsense via `syslog-manager`, Proxmox nodes via rsyslog — all idempotent).

## Post-install

Retrieve the auto-generated Grafana admin password, change it in the UI, then delete the
one-shot file:

    ssh tappaas@logging.mgmt.internal -- sudo cat /root/grafana-admin-password.initial
    # log in to https://logging.<your-domain>/, change the password, then:
    ssh tappaas@logging.mgmt.internal -- sudo rm /root/grafana-admin-password.initial

Optional: add a Promtail client to any other VM you want shipped to Loki — the NixOS
snippet is in [DESIGN.md](./DESIGN.md#setting-up-a-promtail-client-on-another-vm)
(`tappaas-cicd` ships with it pre-installed).

## Verification

    test-module.sh logging        # equivalently: ./test.sh logging

All eight checks SSH into the VM and probe localhost endpoints (no deep tier — the
standard run is itself live; see [TEST.md](./TEST.md)).

| Check | Expected |
|-------|----------|
| SSH to `tappaas@logging.mgmt.internal` | Succeeds |
| `curl http://127.0.0.1:3100/ready` on the VM | Contains `ready` (Loki up) |
| `http://127.0.0.1:3000/api/health` on the VM | JSON shows `"database": "ok"` (Grafana) |
| `ss -lnt` on the VM | `tcp/1514` in LISTEN (syslog ingest) |
| Grafana Explore: `{job="systemd-journal"}` | Log lines from the local journal |
| Grafana Explore: `{source="opnsense"}` / `{source="proxmox"}` | Firewall / node logs arriving |

## Troubleshooting

**No OPNsense logs (`{source="opnsense"}` empty)**
The forwarder is created by `update.sh` via `syslog-manager add-destination` (matched by
description `tappaas-logging`; skipped entirely when `firewallType=NONE`). Inspect with
`syslog-manager list --no-ssl-verify`, re-apply with `update-module.sh logging`. To
verify ingest: `sudo journalctl -u promtail -f` on the VM, then `logger -t test hi` on
the firewall.

**No Proxmox logs (`{source="proxmox"}` empty)**
`update.sh` installs rsyslog on each node and writes
`/etc/rsyslog.d/99-tappaas-loki.conf` (omfwd → `logging.mgmt.internal:1515`). Check
`systemctl status rsyslog` on the node; re-run `update-module.sh logging`. To retire a
node's forwarder: remove that file and restart rsyslog.

**A client VM outside the mgmt zone ships nothing**
There is no automated firewall pinhole yet — a sender in `srv`/`dmz`/etc. cannot reach
`logging:3100` until an OPNsense rule permits it. Add the pinhole manually (see the
network module's `rules-manager`), or keep senders in mgmt for now.

**Disk filling up**
Default retention is 30 days (`retentionHours` in `logging.nix`); rule of thumb
~1–5 GB per VM per 30 days. Grow the disk (`qm resize`) or shorten retention.

**Lost the initial Grafana password**
It is only in `/root/grafana-admin-password.initial` (if not yet deleted) and in
`/etc/secrets/grafana-admin-password` (0600 `grafana:grafana`) on the VM.
