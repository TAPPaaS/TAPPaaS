# Nextcloud

Primary audience: end users and teams who need self-hosted file sync, sharing and collaboration.

Your own private cloud — files, document editing, calls and chat, with single sign-on.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Files & collaboration | Web, desktop and mobile apps | Sync and share files; group folders and guest shares for external collaborators; Notes, Tables, Deck (kanban boards), Collectives (shared team pages) |
| Office documents | Nextcloud Files | Real-time document editing (needs the `euro-office` module) and a shared Whiteboard |
| Calls & chat | Nextcloud UI, mobile apps | Talk: chat, audio and video calls; instant browser notifications; call and chat push notifications on phones |
| Productivity | Nextcloud UI | Calendar, Contacts, Tasks, Forms, Polls, News (RSS reader), AI integration |
| Mail | Nextcloud UI | Webmail client; Microsoft 365 sign-in when your admin sets it up |
| Single sign-on | Login page | You sign in through Authentik; a local account can still sign in directly at `/login?direct=1` |
| Backups | — | Automatic: the whole server, nightly, to the platform's backup server |

## What is not included

- **Document editor** — installed and wired in automatically when you add the `euro-office`
  module.
- **TURN relay for calls made from outside your network** — installed and wired in
  automatically when you add the `coturn` module.
- **Group call scaling** (more participants in one Talk call) — installed and wired in
  automatically when you add the `nextcloud-hpb` module.
- **Outbound system email** (password resets, share notifications) — Nextcloud does not run its
  own mail server; it sends this mail through SMTP credentials you supply.

## Requirements

- An Authentik account, or a local Nextcloud account for the emergency `/login?direct=1` path.
- Reachable from your site's internal networks; your admin can additionally open it to the
  internet.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | VM included in the platform's backup job |
| `network:proxy` | HTTPS access via the reverse proxy |
| `network:rules` | Firewall pass rules |
| `identity:identity` | Sign-in (required) — Authentik is the login backend, not an optional add-on |

For installation steps see [INSTALL.md](./INSTALL.md).
