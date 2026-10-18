# karakeep — Karakeep

Primary audience: TAPPaaS admin.

[Karakeep](https://karakeep.app/) (AGPL-3.0) keeps what you want to read or find again: links,
notes and images. Each saved page is fetched, archived and indexed, so it stays readable and
searchable when the original changes or disappears, and it can be tagged automatically by an AI
model.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| The web app: save, read, search, lists and tags | home, netbird, internet | `https://karakeep.<domain>` — Sign in with Authentik |
| The mobile apps (iOS, Android) and the browser extensions | anywhere | the same address and an API key made in the web app (Settings → API keys) |
| Page archives and screenshots | — | a headless Chromium fetches every saved link |
| Full-text search | — | Meilisearch, over titles, text and notes |
| Automatic tags | — | through the site's LiteLLM, when the AI stack is installed |

## How it is built

- A NixOS VM running Karakeep's three containers with Docker Compose: the web app and its
  background workers (port 3000), the Chromium that fetches pages, and Meilisearch. The images
  are **pinned** to release tags (`src/image-pins.json`); a pin bump is how Karakeep is upgraded.
- **Sign in with Authentik.** `identity:identity` registers Karakeep with Authentik and writes the
  client to `/etc/secrets/karakeep.env`. Karakeep then offers only Sign in with Authentik: no local
  passwords, and the sign-in page goes straight to Authentik. Who may use it is the Authentik group
  bound to its application (`users`). The first person to sign in is Karakeep's administrator.
- **AI tagging** through LiteLLM (`litellm:models`, optional). The key and address are written to
  `/etc/secrets/litellm-svckey.env`; Karakeep tags with the first model LiteLLM serves. Without the
  AI stack, tagging is off and everything else works.
- When either file is written or changes, the stack restarts and picks it up.
- Secrets (the session key, Meilisearch's master key) are generated on the VM the first time and
  kept in `/var/lib/karakeep/secrets.env`; they are in no config file. Meilisearch gets its own key
  and nothing else.
- Data: the library, archives and screenshots in `/var/lib/karakeep/data`, the search index in
  `/var/lib/karakeep/meili`, on the VM's disk (64G, thin) and in its backup.

### Choosing the AI model, and other settings

Settings of your own go in `/var/lib/karakeep/local.env` on the VM — one `NAME=value` per line,
read last, so they win. For example:

```
INFERENCE_TEXT_MODEL=<a model LiteLLM serves>
INFERENCE_ENABLE_AUTO_SUMMARIZATION=true
MAX_ASSET_SIZE_MB=100
```

Then `sudo systemctl restart karakeep`. TAPPaaS never writes this file. The settings are
Karakeep's own ([environment variables](https://docs.karakeep.app/configuration/environment-variables)).

## What is not included

- **Local accounts.** With Authentik configured there are none; before it is (a fresh install
  whose identity step has not run), Karakeep keeps its own and the first account is the
  administrator.
- **Email.** Karakeep sends none here; nothing in it needs it with Authentik sign-in.
- **Full-page screenshots** — only the visible part of a page is kept (they grow the disk quickly);
  turn them on with `CRAWLER_FULL_PAGE_SCREENSHOT=true` in `local.env`.

## Requirements

- 2 cores, 3 GB RAM (the Chromium is most of it), 64G thin disk.
- An environment with a published domain, for the apps and extensions to reach it from anywhere.

## Dependencies

| Service | Why |
|---|---|
| `cluster:vm`, `templates:nixos` | the VM and its NixOS configuration |
| `backup:vm` | the VM, its library and its index, backed up |
| `network:proxy` | `karakeep.<domain>` through Caddy |
| `network:rules` | the firewall rules for port 3000 |
| `identity:identity` | Sign in with Authentik |
| `litellm:models` (optional) | AI tagging |
| `logging:logs` (optional) | the VM's logs in Loki |
