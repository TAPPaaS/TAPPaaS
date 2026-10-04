# Forgejo — self-hosted Git service and DevOps platform

Forgejo is a FOSS Git hosting platform (Gitea fork). It provides Git repositories,
a web interface, a REST API, SSH access, and push webhooks — all running on your
own infrastructure with no external dependencies.

## What you get

| Capability | Access from | How |
|---|---|---|
| Git repository hosting | `work`, `mgmt` networks | `https://forgejo.<domain>` via Caddy |
| Web UI (browse, review, settings) | `work`, `mgmt` networks | Same URL as above |
| REST API | `work`, `mgmt` networks | `https://forgejo.<domain>/api/v1` |
| SSH git clone / push | `work` network, LAN | `git@forgejo.<domain>:org/repo.git` |
| Incoming webhooks | Other services on `srvWork` | HTTP POST to `http://forgejo.srvWork.internal:3000` |

## What is not included

- Email notifications (requires SMTP configuration after install — see INSTALL.md §Post-install)
- OAuth2 / SSO integration (configure via Forgejo admin UI after install)
- External SSH NAT (port forwarding from internet to port 22 — architectural decision required)
- CI/CD runner (Forgejo Actions — install separately as a companion module)

## Requirements

- Proxmox node: `tappaas1` with `tanka1` storage pool
- Zone: `srvWork` (VLAN 220)
- Dependencies: `cluster:vm`, `backup:vm`, `network:proxy`, `network:rules`

## Services offered (`provides`)

| Service | Port | Used for |
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
| `network:proxy` | Caddy reverse proxy — HTTPS endpoint on `work`/`mgmt` |
| `network:rules` | Firewall pinholes (dmz → srvWork TCP 3000) |

For installation steps see [INSTALL.md](./INSTALL.md).
