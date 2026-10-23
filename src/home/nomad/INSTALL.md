# Project N.O.M.A.D. — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

- The foundation installed.
- Disk for the libraries you want (see *Choosing content* below); the default 128 GB holds a
  local-language and the English Wikipedia.

## Security risk: the Command Center has no sign-in

Read this before you install NOMAD.

- **Whoever reaches the Command Center controls the NOMAD VM.** It has no sign-in, and it runs
  its apps through Docker's socket. So anyone who can open port 8080 can start any container
  with any mount. In effect, that is root on the VM.
- **Who can reach it:**
  - every device on the home network, through the module's ingress rule;
  - the other machines in the `dmz` zone (coturn, lazysite and vaultwarden, when installed). The
    site firewall does not filter between machines in the same zone, and the ports Docker
    publishes bypass the VM's own firewall.
- **What a takeover reaches:** the internet, and the other machines in the `dmz`. It does not
  reach the site's other zones. NOMAD keeps no user data.

So install NOMAD only on a site where you trust every device on the home network. Pause it when
nobody is using it:

```bash
module-manager module suspend nomad     # the VM stops and stays stopped
module-manager module resume nomad
```

## Install

```bash
module-manager module add nomad
```

This creates the VM, applies its NixOS configuration (Docker and NOMAD's stack) and lets the home
network reach it. The first start pulls the container images, which takes a few minutes.

## Post-install

1. Open `http://nomad.<zone>.internal:8080` from the home network.
2. In the Command Center, run its **Easy Setup**, or install apps and content under *Settings*.
3. The apps open at `http://nomad.<zone>.internal:<port>`, from the Command Center's tiles.

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
| `http://nomad.<zone>.internal:8080` | answers |
| NOMAD's URL | `http://nomad.<zone>.internal:8080`, so its apps open at that name |

## Troubleshooting

**The stack does not start.** `journalctl -u project-nomad` on the VM shows the compose output;
`sudo docker ps -a` which container stopped.

**An app does not open.** From outside the home network it is not reachable, by design. From inside it,
check that the app's port is in the module's ingress rules (`nomad.json`): a port outside them is
blocked by the site firewall.
