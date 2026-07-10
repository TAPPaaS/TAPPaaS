# euro-office

Primary audience: Nextcloud users who edit office documents; TAPPaaS admin.

Collaborative document editing for Nextcloud — real-time co-authoring of Word, Excel and
PowerPoint files in the browser, powered by
[Euro-Office DocumentServer](https://github.com/Euro-Office/DocumentServer)
(an OnlyOffice-compatible server).

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Edit `.docx`/`.xlsx`/`.pptx` | Nextcloud users | Open a document in Nextcloud Files |
| Real-time co-authoring | Nextcloud users | Multiple users in one document |
| Desktop and mobile editing | OnlyOffice desktop/mobile clients | Connect the client to Nextcloud |
| OnlyOffice-compatible API | `srv` zone | `http://euro-office.srv.internal` (port 80) |
| Public editor endpoint | Internet, via reverse proxy | `https://euro-office.<domain>` |

## What is not included

- Standalone access — the editor is reached through Nextcloud, not directly. The built-in
  `/example/` test app is disabled (`EXAMPLE_ENABLED=false`).
- Authentication of its own — trust is established with Nextcloud via a shared JWT secret
  (auto-generated, never leaves the VM).
- The Nextcloud connector app — shipped by the `nextcloud` module (`eurooffice-nextcloud`,
  app id `onlyoffice`).
- Euro-Office-branded client apps — the desktop/mobile clients are OnlyOffice's official
  products (free download: <https://www.onlyoffice.com/download-desktop.aspx>);
  compatibility is via the Nextcloud integration, not a Euro-Office build.

## Requirements

- `srv` zone (VLAN 210).
- `nextcloud` deployed and reachable (`nextcloud:fileservice` dependency) — install it
  first.
- NixOS template (`templates:nixos`).

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Daily document backups (PBS) |
| `network:proxy` | HTTPS reverse proxy for the public editor endpoint |
| `network:rules` | Firewall pass rules, incl. the callback egress to Nextcloud (443) |
| `nextcloud:fileservice` | The Nextcloud instance served (connector `onlyoffice`) |

For installation steps see [INSTALL.md](./INSTALL.md).
