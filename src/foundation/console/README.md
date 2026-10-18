# console

Primary audience: TAPPaaS operators (the `installer` group and the `admin` role); the site owner, read-only.

The site's web UI: its health at a glance, the site drawn as it is cabled, the modules, what
the sweep did, and every change to the site as a job that runs a manager verb with its preview ([ADR-034](../../../docs/ADR/ADR-034%20-%20TAPPaaS%20User%20Interface.md)).

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Overview: the health strip and Attention, every FAIL and WARN with where to look | `mgmt`, the admin VPN | `https://console.<domain>` behind the Authentik gate |
| Physical: the nodes, switch ports, LAGs, APs, the WAN path and the buddies, laid out from `network-manager topology` | `mgmt`, the admin VPN | the same |
| Modules: every module with its badges; a page per module with its config, drift, services, backup and activity | `mgmt`, the admin VPN | the same |
| Operate: every manager verb on its page as Change → Preview → Apply → Result; destructive verbs behind a typed name and Installer | `mgmt`, the admin VPN | the same |
| Setup: the rest of the install after `bootstrap.sh`, derived from the records; add a node, an environment, a stack; enrol a device | `mgmt`, the admin VPN (before identity: with the setup token) | `/setup` |
| Activity: the console's jobs, the sweep's runs and failures | `mgmt`, the admin VPN | the same |
| The owner's view: the services in plain words, the site in numbers, the physical view; nothing to change | the trusted client zones | `https://status.<domain>` — not yet published, see below |
| The assistant: ask about the site, a module, a finding; it reads the console's records and logs and proposes a change as a card you preview and run (it never runs one) | `mgmt`, the admin VPN; `tappaas ask` on the mothership | the Assistant drawer, when the AI stack is installed |
| "Open in" Proxmox, OPNsense, Grafana, PBS, Authentik, UniFi at the object in view | `mgmt`, the admin VPN | links that open a new tab |
| The console before identity exists | `mgmt`, the admin VPN | `http://<tappaas-cicd>:9097/` — asks for the setup token, which is in `~/config/console-setup-token` on the mothership (the install summary names the file, never the token) |

## What is not included

- Agents through the gate and the SIEM (P4).
- An assistant that changes anything: it proposes, the operator's Run applies (ADR-034 D7).
- The assistant without the AI stack: with no `litellm` module the drawer is absent and
  `tappaas ask` says so; nothing is sent anywhere else.
- The `status.<domain>` route published by this module: the backend serves the owner's view
  on it (a request whose host is `status.…` is read-only whatever its groups), but the
  route's declaration waits for gated `proxyRoutes` — see INSTALL.md, *The owner's route*.

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
| `network:rules` | The reach to what the console integrates with (none needed today: mgmt reaches every zone) |

| Integrates with (optional) | Purpose |
|------------|---------|
| `litellm:models` | The assistant's LiteLLM key, `/etc/secrets/litellm-svckey.env` on the mothership; `assistantModel` (fields.json) pins a model |

The module installs nothing: the service belongs to the mothership's NixOS configuration, and
the backend accepts the firewall's address (where Caddy and the gate run) and loopback only.

For installation steps see [INSTALL.md](./INSTALL.md).
