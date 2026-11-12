# logging:metrics service

A module's numbers — CPU, memory, disk and network over time — in the site's metrics
store (Prometheus on the logging VM), seen in Grafana's *Prometheus* data source and,
as 5-minute means for 90 days, in *Prometheus trends*.

## What a consumer gets

- **Proxmox nodes (`pvehost`)**: the cluster's external metric server (OpenTelemetry
  over HTTPS to `logging.mgmt.internal:3120`) carries each node's and each guest's
  CPU, memory, disk and network; the nodes' guest-memory sampler adds each guest's
  working set and pressure, the node's own pressure (PSI) and its ZFS pools' wait
  times. One setting for the whole cluster, with one credential for the cluster.
- **PBS (`backup`)**: its InfluxDB HTTP metric server, with the instance's own token.
- **Other modules**: a push credential and an identity now; their own pipeline comes
  with the per-module performance levels.
- **Identity**: every series carries `host` (from the credential) and the CI's
  `tappaas_ci_id`, `service_instance_id`, `service_name`, `service_namespace` and
  `deployment_environment_name`, set on the logging VM from the CMDB — never taken from
  the sender. A node's series about a guest carry the guest's identity.
- **The switch**: `site.json` `performance.level` — `off` (the default on a small site)
  removes the metric servers and stops the pushes; `basic` (medium and large) collects.
  `performance.retentionDays` sets how long the store keeps them (7, 15 or 30 days by
  site size).
- **Network access**: `pinhole.json` opens TCP 3120 from a consumer's VM to logging —
  push only. The query port 3121 stays mgmt-only and wants the admin credential.

## Checking it

```bash
tappaas-metrics-target.sh all status
```
