# Forgejo — self-hosted Git service and DevOps platform

Forgejo is a FOSS Git hosting platform (Gitea fork). It provides Git repositories,
a web interface, a REST API, SSH access, and push webhooks — all running on your
own infrastructure with no external dependencies.

## What you get

| Capability | Access from | How |
|---|---|---|
| Git repository hosting | the internet and the `home`, `work`, `mgmt` networks, behind the site's sign-in | `https://forgejo.<domain>` via Caddy |
| Web UI (browse, review, settings) | Same as above | Same URL as above |
| REST API | Same as above | `https://forgejo.<domain>/api/v1` |
| SSH git clone / push | `work` network, LAN | `git@forgejo.<domain>:org/repo.git` |
| Incoming webhooks | Other services on `srvWork` | HTTP POST to `http://forgejo.srvWork.internal:3000` |

## What is not included

- Email notifications (requires SMTP configuration after install — see INSTALL.md §Post-install)
- External SSH NAT (port forwarding from internet to port 22 — architectural decision required)
- CI/CD runner (Forgejo Actions — install separately as a companion module)

## Requirements

- Proxmox node: `tappaas1` with `tanka1` storage pool
- Zone: `srvWork` (VLAN 220)
- Dependencies: `cluster:vm`, `templates:nixos`, `backup:vm`, `network:proxy`, `network:rules`, `identity:identity`

## Services offered (`provides`)

**`forgejo:repo`** — a repository a module's content lives in (`websites/<vmname>`), a read-only deploy key for the module's VM and write access for the people it names. Used by lazysite for its pages. See [services/repo/README.md](services/repo/README.md).

**`forgejo:oauth`** — sign in to a module with Forgejo (and so with Authentik): an OAuth2 application for the module and its client on the module's VM. Used by Woodpecker. See [services/oauth/README.md](services/oauth/README.md).

What Forgejo serves directly, without a service contract:

| What | Port | Used for |
|---|---|---|
| `git:hosting` | TCP 3000 | Repository storage, web browse |
| `ui:web` | TCP 3000 | Browser-based interface |
| `api:rest` | TCP 3000 | Automation, CI/CD integration |
| `git:ssh` | TCP 22 | `git clone/push` over SSH |
| `webhook:push` | TCP 3000 | Outbound push event delivery |

## Known limitations

- SQLite backend by default — sufficient for single-team use. Switch to PostgreSQL for > 50 concurrent users (see INSTALL.md §Customisation).
- SSH git access from outside the `work` VLAN requires an NAT port-forwarding rule (alternative port). Not configured by default.
- Forgejo Actions (CI/CD runners) are not included in this module.

## Dependencies

| Depends on | Purpose |
|---|---|
| `cluster:vm` | Creates and manages the NixOS VM |
| `backup:vm` | PBS backup of the VM (daily snapshot) |
| `network:proxy` | Caddy reverse proxy — HTTPS endpoint for the internet and `home`/`work`/`mgmt` (`proxyAllowedZones`) |
| `network:rules` | Firewall pinholes (dmz → srvWork TCP 3000) |
| `identity:identity` | Single sign-on with the site's Authentik (#282) — see below |

Optional (`integratesWith`): `logging:logs` — the journal to the site's Loki.

## Authentication & SSO

Accounts come from the site's Authentik. `identity:identity` registers Forgejo, and
`forgejo-configure-oidc` keeps one Forgejo login source, `authentik`, in step with that
client. A first SSO login creates the Forgejo account (named after the Authentik username);
local sign-up is off. Members of Authentik's `forgejo-admins` group are Forgejo site admins
(the groups claim carries `admin` for them, nothing for anyone else). Authentik's application
list opens Forgejo at its SSO entry point (`/user/oauth2/authentik`).

There is no standing local admin. When one is needed — Authentik down, the name unpublished,
no `forgejo-admins` member yet — the operator creates it over SSH from tappaas-cicd
([INSTALL.md → Local admin](INSTALL.md#local-admin)) and deletes it afterwards. While
`forgejo.<domain>` has no public DNS record there is no route and no SSO (#778): the source is
removed and only local accounts work.

For installation steps see [INSTALL.md](./INSTALL.md).
