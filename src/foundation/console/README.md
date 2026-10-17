# console

Primary audience: TAPPaaS operators (the Installer and Admin groups); later the site owner, read-only.

The site's web UI: its health at a glance, the site drawn as it is cabled, the modules, and
what the sweep did ([ADR-034](../../../docs/ADR/ADR-034%20-%20TAPPaaS%20User%20Interface.md)).

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Overview: the health strip and Attention, every FAIL and WARN with where to look | `mgmt`, the admin VPN | `https://console.<domain>` behind the Authentik gate |
| Physical: the nodes, switch ports, LAGs, APs, the WAN path and the buddies, laid out from `network-manager topology` | `mgmt`, the admin VPN | the same |
| Modules: every module with its badges; a page per module with its config, drift, services, backup and activity | `mgmt`, the admin VPN | the same |
| Activity: the sweep's runs and failures | `mgmt`, the admin VPN | the same |
| "Open in" Proxmox, OPNsense, Grafana, PBS, Authentik, UniFi at the object in view | `mgmt`, the admin VPN | links that open a new tab |
| The console before identity exists | `mgmt`, the admin VPN | `http://<tappaas-cicd>:9097/?token=…` — the setup token printed by the install summary |

## What is not included

- Changes: this is phase P1, read-only. Operating the site from the console (the job model,
  previews, the Setup wizard) is P2; the assistant P3; agents and the SIEM P4.
- The read-only `status.<domain>` route for the site owner (P2).

## Requirements

- The mothership (`tappaas-cicd`), which runs the service: `tappaas-console.service`, built
  from [`tappaas-cicd/ui`](../tappaas-cicd/ui/README.md).
- `network:proxy` and `identity:accessControl` for the route and the gate.

## Alternatives considered

- homelable as the product, Backstage, Grafana as the UI, a web terminal — see ADR-034, Alternatives.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `network:proxy` | `console.<domain>` through Caddy, from `mgmt` and `admin` only, upstream `tappaas-cicd.mgmt.internal:9097` |
| `identity:accessControl` | The Authentik gate: no login code in the console; the groups arrive in `X-Authentik-Groups` |

The module installs nothing: the service belongs to the mothership's NixOS configuration, and
the backend accepts the firewall's address (where Caddy and the gate run) and loopback only.

For installation steps see [INSTALL.md](./INSTALL.md).
