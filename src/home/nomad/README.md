# nomad — Project N.O.M.A.D.

Primary audience: TAPPaaS admin.

[Project N.O.M.A.D.](https://www.projectnomad.us/) (Apache-2.0, Crosstalk Solutions) is an
offline-first knowledge and education server: Wikipedia and other libraries, thousands of books,
courses and tools, running on hardware you own and usable with no internet.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| The Command Center — installs the apps, downloads libraries and courses | home, netbird (via Caddy) | `https://nomad.<domain>`, signed in through the site's identity (Authentik); a tile on the start page |
| The content apps the Command Center installs: the Information Library (Kiwix: Wikipedia and other ZIM libraries), the Education Platform (Kolibri), Notes, Data Tools, and the Supply Depot (Stirling PDF, File Browser, Calibre Web, IT Tools, Excalidraw, …) | home | `http://nomad.<zone>.internal:<port>`, linked from the Command Center |
| Backups of the VM, its content included | — | `backup:vm` |

## How it is built

- A NixOS VM with Docker. The NixOS configuration (`nomad.nix`) writes NOMAD's compose stack —
  the Command Center, MySQL, Redis and the disk collector — with the images **pinned** to release
  tags (`src/image-pins.json`). A pin bump is how NOMAD is upgraded; its own updater sidecar is not
  installed, and neither is Dozzle (an unauthenticated log viewer).
- Secrets (the app key, the database passwords) are generated on the VM the first time and kept in
  `/var/lib/project-nomad/.env`; they are in no config file.
- The Command Center has no login of its own. It is published through the proxy and gated by
  `identity:accessControl`, and its port is open to the proxy only.
- The content apps are containers the Command Center starts, each on its own port. NOMAD links
  them as *current host + port*; behind the proxy the current host is the public name, so
  `update.sh` sets each app's link to the VM's own address, which the home network reaches (the
  module's ingress rules). The apps are not behind the sign-in.

## What is not included

- **The AI assistant** (Ollama) is not part of this module: the AI stack (Open WebUI, LiteLLM) is
  TAPPaaS's. NOMAD's Command Center still offers it; installing it there runs it on this VM.
- **Content** — which libraries, which languages, which courses — is chosen in the Command Center
  after the install. A minimal and a full selection are described in [INSTALL.md](INSTALL.md).
- **The apps behind the sign-in, or on their own public names.** They are reached inside the site.

## Requirements

- Defaults (from `nomad.json`): VM 370, 2 cores, 4 GB RAM, 128 GB disk on `tanka1` — enough for a
  local-language Wikipedia and the English one. Larger selections need more
  (`module-manager module modify nomad --set diskSize=…`); automatic disk growth also extends it.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm`, `templates:nixos` | the VM, from the NixOS template, and its configuration |
| `network:proxy`, `identity:accessControl`, `identity:identity` | the Command Center published behind the site's sign-in, with its start-page tile |
| `network:rules` | the home network reaching the content apps |
| `backup:vm` | backups |

For installation steps see [INSTALL.md](./INSTALL.md).
