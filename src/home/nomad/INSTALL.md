# Project N.O.M.A.D. — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

- The foundation installed.
- Disk for the libraries you want (see *Choosing content* below); the default 128 GB holds a
  local-language and the English Wikipedia.

## Who reaches the Command Center

The Command Center has no sign-in of its own, and it starts any container it is given through
Docker's socket: whoever uses it controls the NOMAD VM. So TAPPaaS puts it behind the identity
gate:

- **At `https://nomad.<domain>`, signed in, members of `admin` only** (the admin role). It is
  reached from the home network, the management network and the admin VPN; not from the
  internet.
- **Not around the gate.** The VM accepts port 8080 only from Caddy; a direct connection, from
  the home network or from another machine in the `dmz`, is refused.
- **The apps it installs** (the library, courses, notes, the Supply Depot tools) open without a
  sign-in, from the home network, at `http://nomad.dmz.internal:<port>`; the Command Center's
  tiles link there. The other machines in the `dmz` cannot reach them. An app with accounts of its
  own (File Browser, Calibre Web, Vaultwarden) has its own login.

Give someone the Command Center with `identity-manager user modify <name> --add-roles admin`.

## Install

```bash
module-manager module add nomad
```

This creates the VM, applies its NixOS configuration (Docker and NOMAD's stack), publishes the
Command Center at `https://nomad.<domain>` behind the identity gate, and lets the home network
reach the apps. The first start pulls the container images, which takes a few minutes.

## Post-install

1. Open `https://nomad.<domain>` and sign in (a member of `admin`).
2. In the Command Center, run its **Easy Setup**, or install apps and content under *Settings*.
3. The apps open at `http://nomad.dmz.internal:<port>`, from the Command Center's tiles. A newly
   installed app's tile points there within two minutes (`nomad-links` on the VM).

### Choosing content

The Information Library is Kiwix: it serves ZIM files from the Kiwix catalogue, which has
Wikipedia in every language it is written in, not only English — pick the language in the
Command Center's library browser. Sizes vary a lot; *nopic* and *mini* editions are a fraction of
the full ones.

| Selection | What | About |
|-----------|------|-------|
| **Minimal** | Wikipedia in the site's language (*nopic*), Notes | 1–10 GB |
| **Full** | Wikipedia in the site's language and in English (with pictures), Wiktionary, a course collection in the Education Platform, the Supply Depot tools you use | 150 GB and more |

Grow the disk before a large download:

```bash
module-manager module modify nomad --set diskSize=256G
```

Leave out the **AI Assistant**: the site's AI stack (Open WebUI) is the one to use.

## Verification

```bash
module-manager module test nomad
```

| Check | Expected |
|-------|----------|
| `docker`, `project-nomad.service` | active |
| containers `nomad_admin`, `nomad_mysql`, `nomad_redis`, `nomad_disk_collector` | running |
| `http://localhost:8080/api/health` on the VM | 200 |
| images | pinned tags, none `:latest` |
| `nomad-fence` | active: 8080 only from Caddy, no published port from a `dmz` neighbour |
| `http://nomad.dmz.internal:8080` from the mothership | refused |
| NOMAD's URL | `https://nomad.<domain>`, which asks for the sign-in |
| the installed apps' tiles | open at `http://nomad.dmz.internal:<port>` |

## Troubleshooting

**The stack does not start.** `journalctl -u project-nomad` on the VM shows the compose output;
`sudo docker ps -a` which container stopped.

**An app does not open.** From outside the home network it is not reachable, by design. From inside it,
check that the app's port is in the module's ingress rules (`nomad.json`): a port outside them is
blocked by the site firewall. A tile that opens `nomad.<domain>:<port>` has no internal URL yet:
`sudo systemctl start nomad-links` on the VM.

**Signed in but refused.** The Command Center is for members of `admin`; others get Authentik's
"access denied".
