# lazysite — lazysite

Primary audience: TAPPaaS admin.

The site owner's public website. [lazysite](https://lazysite.io/) (MIT) serves Markdown pages as
HTML: each `.md` file is a page, rendered on its first visit and kept as a static file after that.
There is no build step, no database and no CMS. The pages live in a Forgejo repository: commit
there, and the site follows within a minute.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| The website | internet (everyone) | `https://lazysite.<domain>`, or the name you give it |
| Editing the pages | where Forgejo is reachable | the repository `websites/lazysite` in Forgejo: the web editor, or clone and push |
| Layouts, themes, navigation | — | lazysite's own files in `lazysite/` in the repository |
| Sitemap, RSS and Atom feeds, `llms.txt` | internet | made by lazysite from the pages |

## How it is built

- A small NixOS VM in the **DMZ**: it is public, runs third-party code, and holds no data of its
  own — everything is in the repository.
- **nginx** on port 8080, behind the firewall's Caddy, serves files as they are and hands every
  page to the **lazysite renderer**. The renderer is a FastCGI pool on a socket that systemd
  opens; it runs as its own user in a sandbox and writes only the rendered pages.
- **Only the renderer is reachable.** lazysite also has a browser manager, its own sign-in,
  WebDAV publishing, forms with mail, and payments; none of them is wired here. Their URLs answer
  404, and the identity headers lazysite would trust from a front end are always stripped, so no
  visitor can claim to be signed in. Page sources (`/about.md`) are never handed out.
- **The pages come from Forgejo** (`forgejo:repo`). On the first install Forgejo gets a private
  repository `websites/<vmname>` with a starter `index.md`, and the VM a read-only deploy key.
  Every minute the VM asks Forgejo for the latest commit; when there is a new one, it puts the
  pages in place and clears the rendered copies, so the next visit renders the new text.
  Forgejo cannot reach into the DMZ, so the VM asks; one `git ls-remote` a minute on the site's
  own network.
- nginx gives lazysite the **visitor's address** (from Caddy's `X-Forwarded-For`), so lazysite's
  own rate limit counts visitors, not the firewall. CrowdSec on the firewall bans probing in front
  of it.

### Writing pages

A page is Markdown with optional front matter:

```markdown
---
title: About us
---

# About us

Text, [links](/contact), images from `assets/`.
```

`about.md` is `https://<site>/about`; `index.md` is the home page; a folder with an `index.md` is
a section. Images and other files are served as they are. lazysite's own settings —
`lazysite/lazysite.conf`, `lazysite/nav.conf`, layouts and themes under `lazysite/layouts/` —
go in a `lazysite/` folder at the top of the repository; without it, lazysite uses its built-in
layout. See lazysite's [user guide](https://lazysite.io/docs/) for front matter, layouts and the
page features.

### Who may edit

The people in the module's `repoEditors` field get write access to the repository:

```bash
module-manager module modify lazysite --set 'repoEditors=["lars"]'
```

A person signs in to Forgejo once (with Authentik) before they can be added. Forgejo admins
(Authentik group `forgejo-admins`) reach the repository already.

## What is not included

- **The manager, sign-in, WebDAV, forms and payments** of lazysite (see above). Editing is in
  Forgejo.
- **Pages for signed-in visitors only.** The site is public; lazysite's per-page `auth:` needs
  its sign-in, which is not wired.
- **A backup of the VM.** It holds nothing the repository does not; Forgejo's backup keeps the
  pages.

## Requirements

- 1 core, 1 GB RAM, 8G thin disk.
- Forgejo (the devops stack) installed, and an environment with a published domain.

## Dependencies

| Service | Why |
|---|---|
| `cluster:vm`, `templates:nixos` | the VM and its NixOS configuration |
| `network:proxy` | `lazysite.<domain>` through Caddy, open to the internet |
| `network:rules` | the firewall rules for port 8080 |
| `forgejo:repo` | the repository the pages live in, and the VM's read-only deploy key (SSH to Forgejo, opened by a pinhole) |
| `logging:logs` (optional) | the VM's logs in Loki |
