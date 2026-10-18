# Karakeep — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. The foundation: `cluster:vm`, `templates:nixos`, `backup:vm`, `network:proxy`, `network:rules`
   and the `identity` module (Authentik).
2. Optional: the AI stack (`litellm`) for automatic tags — installed before or after Karakeep.

## Install

```bash
cd "${TAPPAAS_REPO:-/home/tappaas/TAPPaaS}"/src/home/karakeep
install-module.sh karakeep
```

This creates the VM, applies its NixOS configuration (Docker and Karakeep's stack), publishes
`karakeep.<domain>`, and registers it with Authentik. The first start pulls three images, a few
minutes.

## Post-install

1. Open `https://karakeep.<domain>`, or the Karakeep tile in Authentik. Sign in with Authentik —
   the first person to do so becomes Karakeep's administrator.
2. For the **browser extension** and the **mobile apps**: in the web app, Settings → API keys,
   create a key; in the extension or app, enter `https://karakeep.<domain>` and the key.
3. With the AI stack, new bookmarks get tags on their own. To choose the model, see
   [README.md](README.md#choosing-the-ai-model-and-other-settings).

## Verification

```bash
./test.sh karakeep
```

| Check | Expect |
|---|---|
| docker, `karakeep.service`, the three containers | running |
| `/api/health` | 200 |
| images | pinned tags, never `:latest` or `:release` |
| Meilisearch's environment | its master key only |
| sign-in | Authentik only, on the VM and at `https://karakeep.<domain>` |
| AI tagging | a model chosen, when the site has LiteLLM |

## Troubleshooting

**Sign in with Authentik says the user may not use the application.** Karakeep's Authentik
application admits the group `users`; add the person there.

**No tags appear.** `sudo grep INFERENCE /run/karakeep/env` on the VM: `INFERENCE_ENABLE_AUTO_TAGGING=false`
means there is no LiteLLM key, or LiteLLM listed no model when Karakeep started. Restart it with
`sudo systemctl restart karakeep` once LiteLLM serves one, or name one in `local.env`.

**A saved page has no archive or screenshot.** The Chromium could not fetch it (a login wall, a
page that blocks headless browsers). `sudo docker logs karakeep_web` on the VM shows why.
