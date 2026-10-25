# nomad — Project N.O.M.A.D.

Primary audience: TAPPaaS admin.

[Project N.O.M.A.D.](https://www.projectnomad.us/) (Apache-2.0, Crosstalk Solutions) is an
offline-first knowledge and education server: Wikipedia and other libraries, thousands of books,
courses and tools, running on hardware you own and usable with no internet.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| The Command Center — installs the apps, downloads libraries and courses | home, mgmt, admin VPN; signed in, members of `admin` | `https://nomad.<domain>` |
| The content apps the Command Center installs: the Information Library (Kiwix: Wikipedia and other ZIM libraries), the Education Platform (Kolibri), Notes, Data Tools, and the Supply Depot (Stirling PDF, File Browser, Calibre Web, IT Tools, Excalidraw, …) | home | `http://nomad.dmz.internal:<port>`, linked from the Command Center |
| Backups of the VM, its content included | — | `backup:vm` |

## How it is built

- A NixOS VM with Docker. The NixOS configuration (`nomad.nix`) writes NOMAD's compose stack —
  the Command Center, MySQL, Redis and the disk collector — with the images **pinned** to release
  tags (`src/image-pins.json`). A pin bump is how NOMAD is upgraded; its own updater sidecar is not
  installed, and neither is Dozzle (an unauthenticated log viewer).
- Secrets (the app key, the database passwords) are generated on the VM the first time and kept in
  `/var/lib/project-nomad/.env`; they are in no config file.
- **The Command Center behind the gate.** It has no sign-in of its own and starts any container
  through Docker's socket, so it is published through the proxy at `https://nomad.<domain>` behind
  the identity gate for members of `admin` (`gateGroups`), from the home network, mgmt and the
  admin VPN, never the internet. On the VM, `nomad-fence` accepts port 8080 only from Caddy:
  Docker's published ports pass the VM's own firewall by, and the site firewall does not filter
  between machines in one zone.
- **The apps on their own ports.** Each app the Command Center starts is a container on its own
  port, reached from the home network at `http://nomad.dmz.internal:<port>` through the module's
  ingress rules, without a sign-in; `nomad-fence` keeps the other `dmz` machines off them. The
  Command Center links an app at the host in the browser's address bar, which behind the proxy is
  the public name, so `nomad-links` gives every installed app its internal address as its custom
  URL (one set by hand is kept).
- **In the DMZ.** NOMAD runs public containers it installs and updates on its own, and it keeps no
  user data. It lives in the `dmz` zone, so a compromised NOMAD reaches only the internet (for its
  downloads), never the site's other zones.

## What is not included

- **The AI assistant** (Ollama) is not part of this module: the AI stack (Open WebUI, LiteLLM) is
  TAPPaaS's. NOMAD's Command Center still offers it; installing it there runs it on this VM.
- **Content** — which libraries, which languages, which courses — is chosen in the Command Center
  after the install. A minimal and a full selection are described in [INSTALL.md](INSTALL.md).
- **Access from outside the site.** Neither the Command Center nor the apps are reachable from
  the internet; an app with accounts of its own (File Browser, Calibre Web) has its own login.

## Requirements

- Defaults (from `nomad.json`): VM 370, 2 cores, 4 GB RAM, 128 GB disk on `tanka1` — enough for a
  local-language Wikipedia and the English one. Larger selections need more
  (`module-manager module modify nomad --set diskSize=…`); automatic disk growth also extends it.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm`, `templates:nixos` | the VM, from the NixOS template, and its configuration |
| `network:proxy` | the Command Center at `https://nomad.<domain>`, from home, mgmt and the admin VPN |
| `identity:accessControl` | the sign-in in front of it, members of `admin` |
| `network:rules` | the home network reaching the content apps |
| `backup:vm` | backups |

For installation steps see [INSTALL.md](./INSTALL.md).
