# Project N.O.M.A.D. — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

- The foundation installed, identity included.
- Disk for the libraries you want (see *Choosing content* below); the default 128 GB holds a
  local-language and the English Wikipedia.

## Install

```bash
module-manager module add nomad
```

This creates the VM, applies its NixOS configuration (Docker and NOMAD's stack), publishes the
Command Center behind the site's sign-in and sets where its apps open from. The first start pulls
the container images, which takes a few minutes.

## Post-install

1. Open `https://nomad.<domain>` from the home network and sign in with your site account.
2. In the Command Center, run its **Easy Setup**, or install apps and content under *Settings*.
3. Apps open from the home network at `http://nomad.<zone>.internal:<port>`. An app installed
   after the module's install gets its link set by the next update
   (`module-manager module update nomad`); until then it opens at the public name, which the
   proxy does not serve.

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
| `https://nomad.<domain>/` without a session | a redirect to the sign-in |
| app links | every app opens at `nomad.<zone>.internal:<port>` |

## Troubleshooting

**The stack does not start.** `journalctl -u project-nomad` on the VM shows the compose output;
`sudo docker ps -a` which container stopped.

**An app does not open.** Its link points at the public name: run
`module-manager module update nomad`, which sets it to the VM's address. From outside the home
network the apps are not reachable.
