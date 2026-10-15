# nomad — Project N.O.M.A.D.

Primary audience: TAPPaaS admin.

[Project N.O.M.A.D.](https://www.projectnomad.us/) (Apache-2.0, Crosstalk Solutions) is an
offline-first knowledge and education server: Wikipedia and other libraries, thousands of books,
courses and tools, running on hardware you own and usable with no internet.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| The Command Center — installs the apps, downloads libraries and courses | home | `http://nomad.<zone>.internal:8080` |
| The content apps the Command Center installs: the Information Library (Kiwix: Wikipedia and other ZIM libraries), the Education Platform (Kolibri), Notes, Data Tools, and the Supply Depot (Stirling PDF, File Browser, Calibre Web, IT Tools, Excalidraw, …) | home | `http://nomad.<zone>.internal:<port>`, linked from the Command Center |
| Backups of the VM, its content included | — | `backup:vm` |

## How it is built

- A NixOS VM with Docker. The NixOS configuration (`nomad.nix`) writes NOMAD's compose stack —
  the Command Center, MySQL, Redis and the disk collector — with the images **pinned** to release
  tags (`src/image-pins.json`). A pin bump is how NOMAD is upgraded; its own updater sidecar is not
  installed, and neither is Dozzle (an unauthenticated log viewer).
- Secrets (the app key, the database passwords) are generated on the VM the first time and kept in
  `/var/lib/project-nomad/.env`; they are in no config file.
- **Inside the site only.** NOMAD is not published through the proxy and has no sign-in: anyone
  on the home network reaches the Command Center at `http://nomad.<zone>.internal:8080`, and the
  apps it starts, each a container on its own port, at the same name and that port — which is how
  NOMAD links them. The module's ingress rules admit the home zone to those ports and no other.

## What is not included

- **The AI assistant** (Ollama) is not part of this module: the AI stack (Open WebUI, LiteLLM) is
  TAPPaaS's. NOMAD's Command Center still offers it; installing it there runs it on this VM.
- **Content** — which libraries, which languages, which courses — is chosen in the Command Center
  after the install. A minimal and a full selection are described in [INSTALL.md](INSTALL.md).
- **Access from outside the site** (the proxy) and **a sign-in** (identity). The Command Center
  manages the apps and downloads, so keep it to the home network; an app with accounts of its own
  (File Browser, Calibre Web) has its own login.

## Requirements

- Defaults (from `nomad.json`): VM 370, 2 cores, 4 GB RAM, 128 GB disk on `tanka1` — enough for a
  local-language Wikipedia and the English one. Larger selections need more
  (`module-manager module modify nomad --set diskSize=…`); automatic disk growth also extends it.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm`, `templates:nixos` | the VM, from the NixOS template, and its configuration |
| `network:rules` | the home network reaching the Command Center and the content apps |
| `backup:vm` | backups |

For installation steps see [INSTALL.md](./INSTALL.md).
