# euro-office

Primary audience: Nextcloud users who edit office documents online.

Edit Word, Excel and PowerPoint documents in your browser, straight from Nextcloud —
together with others, in real time.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Edit Word, Excel and PowerPoint documents | Nextcloud users | Open a document in Nextcloud Files |
| Real-time co-authoring | Nextcloud users | Multiple people can edit the same document at once |
| Desktop and mobile editing | OnlyOffice desktop/mobile apps | Connect the app to your Nextcloud account |

## What is not included

- Standalone access — the editor is reached through Nextcloud, not directly.
- Authentication of its own — trust is established with Nextcloud via a shared secret,
  set up automatically.
- The Nextcloud connector app — shipped by the `nextcloud` module (app ID `eurooffice`,
  settings page "Nextcloud Office").
- Euro-Office-branded client apps — the desktop/mobile clients are OnlyOffice's official
  products (free download: <https://www.onlyoffice.com/download-desktop.aspx>);
  compatibility is via the Nextcloud integration, not a Euro-Office build.

## Requirements

- The `nextcloud` module, installed first.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Full-VM backup (Proxmox Backup Server) |
| `network:proxy` | HTTPS reverse proxy for the public editor endpoint |
| `network:rules` | Firewall pass rules |
| `nextcloud:fileservice` | The Nextcloud instance served (connector `onlyoffice`) |

For installation steps see [INSTALL.md](./INSTALL.md).
