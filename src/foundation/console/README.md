# console

Primary audience: TAPPaaS operators (the `installer` group).

The site's web UI: its health at a glance, the site drawn as it is cabled, the modules, what
the sweep did, and every change to the site as a job that runs a manager verb with its preview ([ADR-034](../../../docs/ADR/ADR-034%20-%20TAPPaaS%20User%20Interface.md)).

**Who gets it: members of the Authentik group `installer`, and nobody else.** An installer may
do everything, destructive verbs included (each behind the object's name typed). The gate
refuses anyone outside the group at the login, and the console answers 403 if one gets past it.
Being an `admin` (an admin of the apps) or in `users` (everyone with an account) gives no
access. Make someone an installer with `identity-manager user modify <user> --add-groups
installer` (INSTALL.md, *Who may log in*).

## Two parts, two owners

The console is two things. **The code and the running service are part of the
mothership:** `tappaas-cicd/ui` holds the TypeScript backend and the React front end,
the control-plane refresh builds it like a manager and links it as `~/bin/console`, and
the mothership runs it as `tappaas-console.service` (port 9097, as the `tappaas` user),
restarted when a new build lands. It has to be there before any module is installed,
because the Setup wizard runs on it right after `bootstrap.sh`, and because every change
it makes is a manager verb run on the mothership. So a change to the console's code
reaches a site with the control-plane refresh, like a change to a manager.

**This module is the console's published face.** Registering it installs nothing: it
gives the running service its route `console.<domain>` through Caddy (network:proxy),
puts the Authentik gate in front of it bound to the `installer` group
(identity:accessControl), opens its firewall rules, hands it the assistant's LiteLLM key
when the AI stack is there, and carries the operator's settings (`proxyDomain`,
`assistantModel`, `gateGroups`). A change to how the console is published or configured
is a module change: `module-manager module update console`.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Overview: the health strip and Attention, every FAIL and WARN with where to look | `mgmt`, the admin VPN | `https://console.<domain>` behind the Authentik gate |
| Physical: the nodes, switch ports, LAGs, APs, the WAN path and the buddies, laid out from `network-manager topology` | `mgmt`, the admin VPN | the same |
| Modules: every module with its badges; a page per module with its config, drift, services, backup and activity | `mgmt`, the admin VPN | the same |
| Operate: every manager verb on its page as Change → Preview → Apply → Result; destructive verbs behind the object's name typed | `mgmt`, the admin VPN | the same |
| Setup: the rest of the install after `bootstrap.sh`, derived from the records; add a node, an environment, a stack; enrol a device | `mgmt`, the admin VPN (before identity: with the setup token) | `/setup` |
| Activity: the console's jobs, the sweep's runs and failures | `mgmt`, the admin VPN | the same |
| The assistant: ask about the site, a module, a finding; it reads the console's records and logs and proposes a change as a card you preview and run (it never runs one) | `mgmt`, the admin VPN; `tappaas ask` on the mothership | the Assistant drawer, when the AI stack is installed |
| "Open in" Proxmox, OPNsense, Grafana, PBS, Authentik, UniFi at the object in view | `mgmt`, the admin VPN | links that open a new tab |
| The console before identity exists | `mgmt`, the admin VPN — the bootstrap makes a first peer (`/root/tappaas-admin-vpn.conf` on the node) — and, on a private WAN, the install LAN | `http://<tappaas-cicd>:9097/`, or `http://<firewall WAN>:9097/` from the install LAN — asks for the setup token, which is in `~/config/console-setup-token` on the mothership (the install summary names the file, never the token). Installing this module closes the install-LAN way in (`install-access.sh close`) |

## What is not included

- Agents through the gate and the SIEM (P4).
- An assistant that changes anything: it proposes, the operator's Run applies (ADR-034 D7).
- The assistant without the AI stack: with no `litellm` module the drawer is absent and
  `tappaas ask` says so; nothing is sent anywhere else.
- Anything for people outside `installer`: no read-only view and no status page for the
  household. Those come with differentiated roles, a later step; until then a request for
  `status.<domain>` is refused (403) whoever sends it.

## Requirements

- The mothership (`tappaas-cicd`), which runs the service: `tappaas-console.service`, built
  from [`tappaas-cicd/ui`](../tappaas-cicd/ui/README.md).
- `network:proxy` and `identity:accessControl` for the route and the gate.
- A public A and AAAA record for `console.<domain>` to the WAN (the certificate is HTTP-01).
- From the admin VPN, a tunnel config that carries the site's DNS and the routes to the DMZ
  gateway (config v2, `network-manager wgvpn list`; [ADMIN-VPN.md](../tappaas-cicd/manager/network-manager/ADMIN-VPN.md) §6).

## Alternatives considered

- homelable as the product, Backstage, Grafana as the UI, a web terminal — see ADR-034, Alternatives.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `network:proxy` | `console.<domain>` through Caddy, from `mgmt` and `admin` only, upstream `tappaas-cicd.mgmt.internal:9097`; `check-config.sh` refuses `internet` and `all` in the zone list |
| `identity:accessControl` | The Authentik gate, bound to `installer` only (`gateGroups`): no login code in the console; the user and groups arrive in the gate's signed token |
| `network:rules` | The reach to what the console integrates with (none needed today: mgmt reaches every zone) |

| Integrates with (optional) | Purpose |
|------------|---------|
| `litellm:models` | The assistant's LiteLLM key, `/etc/secrets/litellm-svckey.env` on the mothership; `assistantModel` (fields.json) pins a model |

The module installs nothing: the service belongs to the mothership's NixOS configuration, and
the backend accepts the firewall's address (where Caddy and the gate run) and loopback only.
From a zone outside the route's list, the internet included, an anonymous request is redirected
to the Authentik login (public anyway) and a signed-in one gets 403 from the access list; the
console itself is never reached from there.

For installation steps see [INSTALL.md](./INSTALL.md).
