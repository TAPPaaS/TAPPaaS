# identity — Installation

Primary audience: TAPPaaS admin.

Identity is a foundation module: in a normal install it is **installed automatically by
`rest-of-foundation.sh`** (in order backup → identity → logging), which also bootstraps
the people domain — your organisation, the `users` group and your installer user — into
Authentik once it is up. There is **no manual Authentik setup wizard**: secrets are
generated on the VM's first boot and the API credential bootstrap is fully automated.

## Prerequisites

1. Foundation base installed: cluster, network (OPNsense + Caddy), templates,
   tappaas-cicd, backup.
2. A domain resolved for the default environment (`config/environments/<env>.json`, or
   legacy `configuration.json .tappaas.domain`) — the install dies without one.
3. OPNsense API credentials present on tappaas-cicd (`~/.opnsense-credentials.txt`) —
   used to configure Caddy's forward-auth wiring.

> To deviate from the defaults in `./identity.json` (target node, storage, zone/VLAN,
> sizing), copy the json to `/home/tappaas/config` and edit it before installing.

## Install

Normal path (with the rest of the foundation):

    rest-of-foundation.sh

Stand-alone (idempotent, safe to re-run):

    cd ~/TAPPaaS/src/foundation/identity && install-module.sh identity

Everything is automated. Beyond creating the VM, the install:

1. Waits for Authentik's API to come up on the identity VM.
2. Reads `AUTHENTIK_BOOTSTRAP_TOKEN` from `/etc/secrets/authentik.env` (created on first
   boot by `identity.nix`'s secrets generator) and persists it to
   `~/.authentik-credentials.txt` on the cicd (mode 600) for `authentik-manager`.
3. Configures Caddy's global AuthProvider = Authentik and registers the 12
   `X-Authentik-*` copy-headers.
4. Sets the embedded outpost's `authentik_host` to `https://identity.<domain>` and
   registers the identity self-application + Proxy Provider.
5. Adopts Authentik's built-in **`authentik Admins`** group (`is_superuser`) and puts the
   **site owner** in it (issue #476), so that person can administer users in the Authentik
   UI. On a fresh install the group + membership come from the people bootstrap; on an
   existing install `update.sh` adds them to `config/people/` and applies the membership.

Role groups (`user`/`admin`/`root`) and the `users` team group are reconciled into
Authentik by `people-manager sync` — run by `rest-of-foundation.sh` at first install and
on update.

## Post-install

None. Log in to `https://identity.<domain>` as the **site owner** — the owner user of the
organization that owns the default environment (`site.json` `.owner` →
`config/people/organizations/<org>.json` `.owner`) — to reach the admin UI.

Break-glass only: user `akadmin`, password in `/etc/secrets/authentik.env` on the identity
VM (`AUTHENTIK_BOOTSTRAP_PASSWORD`). It is the sole admin if the owner account is lost.

Every consumer module with `dependsOn: identity:accessControl` (forward-auth) or
`identity:identity` (OIDC) gets its SSO wiring automatically when it installs — no
manual step per app.

## Verification

    test-module.sh identity

Fast tier asserts Authentik connectivity, role groups and the OIDC allow-list;
`./test.sh --deep` adds live forward-auth/OIDC fixture tests (see [TEST.md](./TEST.md)).

| Check | Expected |
|-------|----------|
| Browse `https://identity.<domain>` | Authentik login page |
| `authentik-manager test` (on tappaas-cicd) | exits 0 — API reachable, token accepted |
| Log in as `akadmin` (password from the VM's `/etc/secrets/authentik.env`) | Authentik admin interface |
| `authentik-manager list-users \| jq '.[] \| select(.name=="<site-owner>") \| .groups'` | includes `authentik Admins` |

## Troubleshooting

**`~/.authentik-credentials.txt` missing or token rejected (stale)**
Self-heals: any consumer install and `update.sh` re-fetch the bootstrap token from the
identity VM (`lib/ensure-authentik-creds.sh`). To force it:
`cd src/foundation/identity && ./update.sh identity`.

**"Authentik API never came up"**
Confirm the identity VM is running and has finished its first boot (secrets generation +
container start take a few minutes), then re-run the update.

**Token never accepted after bootstrap**
Authentik's worker binds `AUTHENTIK_BOOTSTRAP_TOKEN` to `akadmin` asynchronously on
first boot — the API can be up before the token is valid. The bootstrap polls up to
3 minutes; if it still fails, re-run `./update.sh identity`.

**"No domain resolved"**
Set the environment domain (`environment-manager modify <system-name> --domain <domain>`)
or legacy `configuration.json .tappaas.domain`, then re-run.

**OPNsense credentials file missing**
The Caddy wiring needs `~/.opnsense-credentials.txt` (key= / secret=) on tappaas-cicd —
created by the network/tappaas-cicd install.
