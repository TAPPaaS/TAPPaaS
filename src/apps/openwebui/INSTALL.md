# OpenWebUI — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. LiteLLM must be deployed and accessible before installing OpenWebUI
   (`litellm:models` dependency). LiteLLM must also have at least one model
   registered — OpenWebUI is wired to it automatically, but an empty LiteLLM
   means an empty model list (see Troubleshooting).
2. Identity (Authentik) must be deployed (`identity:identity` dependency) —
   OpenWebUI signs users in via SSO.
3. The environment owner must exist in people-manager with a `primaryEmail`,
   because that identity becomes the OpenWebUI admin. Resolution is
   `environments/<env>.json .ownerOrg` -> people org `.owner` -> user
   `.primaryEmail`. Check with:

       people-manager org show "$(jq -r .ownerOrg /home/tappaas/config/environments/<env>.json)"
       people-manager user show <owner>

4. Verify `openwebui.json` matches your environment (node, storage, zone).

> To deviate from the defaults in `./openwebui.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing.

Fields can also be overridden with flags at install time, e.g.
`install-module.sh openwebui --node tappaas1 --zone0 srvDev --vmid 399`,
or a named variant config (`--variant staging`).

## Install

    install-module.sh openwebui

Duration: ~10–20 minutes on first run (NixOS rebuild + container pull ~1 GB).

## What the install wires up automatically

No manual configuration is required after installing. Three things that used to
be hand-configured are now part of the converge, and are re-applied by every
`module-manager reconcile openwebui --apply`:

| Integration | What happens | Where it lands |
|-------------|--------------|----------------|
| **LiteLLM** | `litellm:models` provisions a per-consumer virtual key and writes `/etc/secrets/litellm-svckey.env`. `openwebui-integrations.service` translates it into `OPENAI_API_KEY` / `OPENAI_API_BASE_URL`. | `/etc/secrets/openwebui-integrations.env` |
| **SSO (Authentik)** | `identity:identity` creates the OIDC application and writes `/etc/secrets/openwebui-oidc.env`. The same service translates it into `OAUTH_CLIENT_ID` / `OAUTH_CLIENT_SECRET` / `OPENID_PROVIDER_URL`. | same file |
| **Admin account** | `update.sh` resolves the environment owner and pushes the identity; `openwebui-seed-admin.service` creates that account **before anyone can log in**, so the admin is deterministic rather than "whoever signs up first". | `/etc/secrets/openwebui-owner.env` |

Notes worth knowing:

- OpenWebUI makes the **first** account an admin. Seeding exists so that account
  is the environment owner. It is skipped entirely once any account exists, so it
  can never take over an instance already in use.
- The seeded account is created through OpenWebUI's own signup API with a random,
  discarded password. `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true` means the owner's first
  SSO login **adopts** that account rather than creating a second, non-admin one.
- Credential rotation is handled: `identity:identity` restarts
  `openwebui-integrations.service`, which regenerates the settings and restarts
  the container only when the content actually changed.

## Post-install

First login:

1. Open OpenWebUI at `http://<vmname>.<zone>.internal:8080` (or its
   `proxyDomain` if published).
2. Sign in with SSO as the environment owner. You land in the pre-seeded admin
   account.
3. Start a conversation and pick a model — the LiteLLM connection is already
   configured under Settings -> Connections; do not add it by hand.

For upgrades of an existing install see [UPGRADE.md](./UPGRADE.md).
To restore application data from backups see [RESTORE.md](./RESTORE.md).

## Optional: publish to the internet

OpenWebUI ships **internal-only**: `openwebui.json` declares

    "network:proxy": { "proxyAllowedZones": ["home"] }

so the reverse proxy accepts clients from the `home` zone and refuses everything
else — including the internet. That is the intended default for an LLM chat UI;
only widen it deliberately.

A request from a zone that is not allowed gets **HTTP 403 from Caddy**. That is
worth recognising: a 403 means the request *reached* the proxy and was refused
there, so the firewall path is fine and only the access list needs changing. A
missing firewall rule times out instead.

To publish it, add the literal `internet` zone (which means "no restriction"),
then converge:

    # deployed config, NOT the module source — this is a per-site decision
    cd /home/tappaas/config
    cp openwebui.json openwebui.json.bak
    tmp=$(mktemp)
    jq '.config["network:proxy"].proxyAllowedZones = ["internet"]' openwebui.json > "$tmp"
    mv "$tmp" openwebui.json && chmod 600 openwebui.json

    module-manager reconcile openwebui --apply

Verify:

    curl -o /dev/null -w '%{http_code}\n' https://<proxyDomain>/          # expect 200

    # SSO redirect must carry the PUBLIC callback URL
    curl -o /dev/null -w '%{redirect_url}\n' https://<proxyDomain>/oauth/oidc/login

The second check matters: the OIDC application's `redirect_uri` is derived from
the module's domain, so it must point at the public host you are now serving. If
it does not, re-run the converge so `identity:identity` re-applies.

Two caveats:

- **A 502 immediately after the converge is usually transient.** The container is
  restarted to pick up new settings; Caddy returns 502 while it comes back. Check
  `curl http://127.0.0.1:8080/` on the VM — if that answers 200, just retry.
- **This lives in the deployed config only.** `install-module.sh openwebui
  --reinstall` re-copies the module source and reverts to `["home"]`. Re-apply
  afterwards, or change the authored `openwebui.json` if this site always wants
  it published — but note that changes the shipped default for every deployment
  of this module, so prefer the deployed-config route.

To narrow it again, set the zones back (e.g. `["home"]`) and reconcile.

## Verification

    test-module.sh openwebui

| Check | Expected |
|-------|----------|
| SSH connectivity | PASS |
| OpenWebUI container | running |
| HTTP endpoint on port 8080 | responding (200) |
| PostgreSQL | accepting connections |
| Redis | responding to PING |
| `litellm:models` | VK provisioned, key file present, VK resolves >0 models |

Spot-check the automated wiring directly (secrets redacted):

    ssh tappaas@<vmname>.<zone>.internal \
      "sudo sed -E 's/(KEY|SECRET)=.*/\1=<redacted>/' /etc/secrets/openwebui-integrations.env"

Expect `OPENAI_API_BASE_URL`, `OPENAI_API_KEY`, and the `OAUTH_*` /
`OPENID_PROVIDER_URL` block. Confirm the admin is the environment owner:

    ssh tappaas@<vmname>.<zone>.internal \
      "sudo -u postgres psql -d openwebui -tAc 'SELECT email, role FROM \"user\"'"

## Troubleshooting

These checks cover deployment failures only.
For operational issues after a successful install see [ADMIN.md](./ADMIN.md).

**install-module.sh exits with dependency error**

A required service is not installed. Check which `dependsOn` entry is unmet:

    rules-manager list-installed --no-ssl-verify

Install the missing module first, then retry.

**Container fails to start on first boot**

DNS or image pull failed during NixOS activation. Check from inside the VM:

    ssh tappaas@openwebui.srvWork.internal "sudo journalctl -u openwebui-wrapper -n 30"

Common fix: wait 2–3 minutes for NixOS first-boot to complete, then run
`test-module.sh openwebui`.

**Test shows LiteLLM unreachable**

Firewall pinhole not applied. Re-run install:

    install-module.sh openwebui --force

**Model list is empty (but sign-in works)**

OpenWebUI is wired to LiteLLM correctly; LiteLLM has no models to serve. This is
a LiteLLM configuration matter, not an OpenWebUI one. Confirm on the LiteLLM VM:

    MK=$(sudo grep '^LITELLM_MASTER_KEY=' /etc/secrets/litellm.env | cut -d= -f2-)
    curl -sS -H "Authorization: Bearer $MK" http://127.0.0.1:4000/v1/models

An empty `data` array means no models are registered. `module-manager test
openwebui` reports this as `VK key resolves 0 models`. Register models on
LiteLLM, then re-run `module-manager reconcile openwebui --apply`.

**No SSO button on the login page**

The OIDC half of the settings file is missing — `identity:identity` has not run
or failed. Check for the `OAUTH_*` keys:

    ssh tappaas@<vmname>.<zone>.internal "sudo grep -c OAUTH_ /etc/secrets/openwebui-integrations.env"

If zero, re-apply: `module-manager reconcile openwebui --apply`.

**The admin account is not the environment owner**

Seeding only runs on an instance with **zero** accounts — by design, so it cannot
displace real users. If someone signed up before the seed ran, they hold admin.
Promote the owner from within OpenWebUI (Admin Panel -> Users), or, on a throwaway
instance, delete the accounts and re-run `module-manager reconcile openwebui --apply`.

Check what the seeder decided:

    ssh tappaas@<vmname>.<zone>.internal "journalctl -u openwebui-seed-admin -n 5"

`no owner email recorded yet` means the owner could not be resolved on the TAPPaaS
side — see Prerequisites step 3.
