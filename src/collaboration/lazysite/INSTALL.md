# lazysite — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. The foundation: `cluster:vm`, `templates:nixos`, `network:proxy`, `network:rules`, and the
   DMZ zone active.
2. Forgejo (`src/devops/forgejo`) installed.
3. A DNS name for the site under the environment's domain (`lazysite.<domain>` by default, or set
   `network:proxy.proxyDomain`), resolving publicly to the site.

## Install

```bash
cd "${TAPPAAS_REPO:-/home/tappaas/TAPPaaS}"/src/collaboration/lazysite
install-module.sh lazysite
```

This creates the VM, applies its NixOS configuration, creates the repository `websites/lazysite`
in Forgejo with a starter page and gives the VM a read-only deploy key, publishes the site, and
brings the first commit.

## Post-install

1. Open `https://lazysite.<domain>`: the starter page.
2. Give the people who write the site access (they sign in to Forgejo once first):
   `module-manager module modify lazysite --set 'repoEditors=["<forgejo username>"]'`.
3. Edit `index.md` in Forgejo (`websites/lazysite`), commit, and reload the site within a minute.

## Verification

```bash
./test.sh lazysite
```

| Check | Expect |
|---|---|
| `lazysite.socket`, `lazysite.service`, nginx, `lazysite-pull.timer` | active; the renderer runs as `lazysite` |
| the deployed commit | the repository's latest |
| `/` | 200, rendered HTML; `/index.md` is not handed out |
| manager, sign-in, WebDAV, CGI, engine files, `/.git` | 404 |
| an `X-Remote-User` header | signs no one in |
| `https://lazysite.<domain>/` | 200 through Caddy |

## Troubleshooting

**A commit does not show.** `journalctl -u lazysite-pull` on the VM says what the last pull did.
"no repository yet" means forgejo:repo has not run: `module-manager module update lazysite`. A host-key
or permission error means the deploy key or the pinhole to Forgejo's port 22 is missing; the
same update puts both back.

**A page shows old text.** Every new commit clears the rendered copies; a page rendered from a
`.url` source (fetched from elsewhere) is refetched after an hour.

**The site answers 502.** The renderer is not running: `journalctl -u lazysite` on the VM.
