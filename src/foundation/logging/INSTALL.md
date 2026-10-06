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

On a published site Grafana's login page goes straight to Authentik
(`auto_login`), and Authentik's application list opens it at
`/login/generic_oauth`. The local `admin` account below signs in at
`https://logging.<domain>/login?disableAutoLogin`.

Retrieve the auto-generated Grafana admin password, change it in the UI, then delete the
one-shot file:

    ssh tappaas@logging.mgmt.internal -- sudo cat /root/grafana-admin-password.initial
    # log in to https://logging.<your-domain>/, change the password, then:
    ssh tappaas@logging.mgmt.internal -- sudo rm /root/grafana-admin-password.initial

Modules that declare `integratesWith: ["logging:logs"]` start shipping their journal
at their next update (`update-module.sh <module>`) — see
[services/logs](services/logs/README.md).

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
verify ingest: `sudo journalctl -u alloy -f` on the VM, then `logger -t test hi` on
the firewall.

**No Proxmox logs (`{source="proxmox"}` empty)**
`update.sh` installs rsyslog on each node and writes
`/etc/rsyslog.d/99-tappaas-loki.conf` (omfwd → `logging.mgmt.internal:1515`). Check
`systemctl status rsyslog` on the node; re-run `update-module.sh logging`. To retire a
node's forwarder: remove that file and restart rsyslog.

**A module's journal is not in Loki**
`test-module.sh <module>` runs the `logging:logs` check. The module must declare
`logging:logs` and have had an update since logging was installed (that writes
`/etc/nixos/tappaas-logging.nix`); outside mgmt it also needs `network:rules`, whose
pinhole opens tcp/3101 from it to logging (`rules-manager reconcile <module>` shows it).

**Disk filling up**
Default retention is 30 days (`retentionHours` in `logging.nix`); rule of thumb
~1–5 GB per VM per 30 days. Grow the disk (`qm resize`) or shorten retention.

**Lost the initial Grafana password**
It is only in `/root/grafana-admin-password.initial` (if not yet deleted) and in
`/etc/secrets/grafana-admin-password` (0600 `grafana:grafana`) on the VM.
