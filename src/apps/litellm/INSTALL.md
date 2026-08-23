# LiteLLM — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. All dependency modules are installed — see the `dependsOn` list in
   `litellm.json`. In particular:
   - **`vllm-amd`** (local inference backend) must be *running and serving a
     model*. Its model is registered into LiteLLM automatically, and the model id
     is read live from vLLM — so if vLLM is down at converge time, LiteLLM ends up
     with no model registered. Check:

         curl -s http://<vllm-vmname>.<zone>.internal:8000/v1/models | jq -r '.data[].id'

   - **`identity`** (Authentik) — LiteLLM's admin UI signs in via SSO.
2. The environment owner must exist in people-manager with a `primaryEmail`; that
   identity is promoted to LiteLLM `proxy_admin`. Resolution is
   `environments/<env>.json .ownerOrg` -> people org `.owner` -> user
   `.primaryEmail`:

       people-manager org show "$(jq -r .ownerOrg /home/tappaas/config/environments/<env>.json)"
       people-manager user show <owner>

3. Verify `litellm.json` matches your environment (node, storage, zone).

> To deviate from the defaults in `./litellm.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing.

Fields can also be overridden with flags at install time, e.g.
`install-module.sh litellm --node tappaas1 --zone0 srvDev --vmid 399 --memory 8192`,
or a named variant config (`--variant staging` reads `litellm-staging.json`).

## Install

    install-module.sh litellm

Duration: ~5–10 minutes on first run.

## What the install wires up automatically

Three things that used to be manual UI steps are now part of the converge, and are
re-applied by every `module-manager reconcile litellm --apply`:

| Integration | What happens | Where it lands |
|-------------|--------------|----------------|
| **vLLM backend** | `vllm-amd:inference` publishes the endpoint, the **live-read** served model id, and the key. LiteLLM registers it as a model through its own API, referencing a named credential (`vllm-amd`). | `/etc/secrets/vllm-inference.env` |
| **SSO (Authentik)** | `identity:identity` creates the OIDC application; the settings translator emits the `GENERIC_*` variables LiteLLM expects, reading the endpoints from the provider's discovery document. | `/etc/secrets/litellm-integrations.env` |
| **Admin account** | `update.sh` resolves the environment owner and pushes it; the seeding service promotes that identity to `proxy_admin`. | `/etc/secrets/litellm-owner.env` |

Notes worth knowing:

- `config.yaml` deliberately carries **no `model_list`** — LiteLLM runs with
  `load_models_from_db`, so models live in the database. Before this automation a
  fresh deploy served **zero models** even though the `vllm-amd:inference`
  dependency was declared and its firewall pinhole was open.
- The model references a **named credential** rather than an embedded `api_key`.
  That is this module's documented pattern (`scripts/litellm-credentials.sh`), so
  rotating the credential updates every model that references it. It also matters
  for verification: `/model/info` does **not** return `api_key` (it is stored
  encrypted and reported as null), so an embedded key reads as "missing" to
  `services/models/test-service.sh` even when it is present in the database.
- Registration and admin seeding are idempotent — both check current state first,
  so a reconcile does not create duplicate models or users.
- **This covers the local vLLM backend only.** External providers (OpenRouter,
  Anthropic, Perplexity, …) still require credentials to be added deliberately —
  see step 2 below.

## Post-install

**1. Get the master key**

    ssh tappaas@<vmname>.<zone>.internal "sudo cat /etc/secrets/litellm.env"

Save this key in your password manager — it is the admin credential for the API,
and the fallback login for the UI if SSO is unavailable.

**2. Sign in**

Open `https://<proxyDomain>/ui` (or `http://<vmname>.<zone>.internal:4000/ui`) and
sign in with SSO as the environment owner — that account is already `proxy_admin`.
The local vLLM model is already registered; do not add it by hand.

**3. Add external providers (optional)**

Only needed for hosted providers. Use the credential registry rather than
embedding keys in models:

    litellm-credentials.sh add --name "<name>" --provider <provider>
    litellm-credentials.sh assign-model --model <model_name> --credential "<name>"

Reference: [LiteLLM proxy docs](https://docs.litellm.ai/docs/proxy/ui_credentials)

For upgrades of an existing install see [UPGRADE.md](./UPGRADE.md).

## Optional: publish to the internet

LiteLLM ships **internal-only** — `litellm.json` declares no
`proxyAllowedZones`, so `network:proxy` applies its zero-trust default: every
Active Service zone plus home, work, mgmt and netbird, but **not** the internet.

A request from a zone that is not allowed gets **HTTP 403 from Caddy**. That is
worth recognising: a 403 means the request *reached* the proxy and was refused
there, so the firewall path is fine and only the access list needs changing. A
missing firewall rule times out instead.

Think twice here: LiteLLM proxies your paid provider credentials, so publishing it
widens the blast radius of a leaked virtual key. Prefer reaching it over the
netbird overlay where that is an option. To publish anyway:

    # deployed config, NOT the module source — this is a per-site decision
    cd /home/tappaas/config
    cp litellm.json litellm.json.bak
    tmp=$(mktemp)
    jq '.config["network:proxy"].proxyAllowedZones = ["internet"]' litellm.json > "$tmp"
    mv "$tmp" litellm.json && chmod 600 litellm.json

    module-manager reconcile litellm --apply

The SSO callback follows `PROXY_BASE_URL`, which `update.sh` derives from the
module's resolved `proxyDomain` — so re-converge after any domain change or the
redirect will point at the old host.

This lives in the deployed config only: `install-module.sh litellm --reinstall`
reverts it.

## Verification

    test-module.sh litellm

All 10 tests should pass.

| Check | Expected |
|-------|----------|
| `postgresql` service | active |
| `redis-litellm` service | active |
| `podman-litellm` service | active |
| API health check | passed |
| PostgreSQL | responding |
| LiteLLM database | has tables |
| Redis | responding (PONG) |
| API authentication | successful |
| Backup directories | all exist |
| Backup timers | scheduled |

The dependency-service checks add coverage of the automation (`module-manager
reconcile litellm` runs them read-only):

| Check | Expected |
|-------|----------|
| `vllm-amd:inference` | endpoint published to the consumer |
| `litellm:models` (per consumer) | VK resolves >0 models; every DB model has an explicit key or credential |
| `identity:identity` | OIDC application exists for slug `litellm` |

Spot-check the automation directly:

    M=<vmname>.<zone>.internal

    # the vLLM model is registered and references the named credential
    ssh tappaas@$M 'MK=$(sudo grep "^LITELLM_MASTER_KEY=" /etc/secrets/litellm.env | cut -d= -f2-); \
      curl -sS -H "Authorization: Bearer $MK" http://127.0.0.1:4000/model/info \
      | jq -c ".data[] | {model_name, cred: .litellm_params.litellm_credential_name}"'

    # SSO settings present (secrets masked)
    ssh tappaas@$M "sudo sed -E 's/(SECRET|CLIENT_ID)=.*/\1=<redacted>/' /etc/secrets/litellm-integrations.env"

    # the owner was promoted
    ssh tappaas@$M "journalctl -u litellm-seed-admin -n 5 | grep seed-admin:"

## Troubleshooting

**Container not starting**

    ssh tappaas@<vmname>.<zone>.internal "journalctl -u podman-litellm -n 50"

If the log shows `parsing file "/etc/secrets/litellm-integrations.env": no such
file or directory`, the settings translator has not run. podman refuses to start
when an `--env-file` is missing, so that file is created unconditionally — even
empty. Re-run it:

    ssh tappaas@<vmname>.<zone>.internal "sudo systemctl restart litellm-integrations"

**Model list is empty**

The vLLM backend was not registered. Most often vLLM was not serving when the
converge ran, so no model id could be read. Check vLLM first, then re-converge:

    curl -s http://<vllm-vmname>.<zone>.internal:8000/v1/models | jq -r '.data[].id'
    module-manager reconcile litellm --apply
    ssh tappaas@<vmname>.<zone>.internal "journalctl -u litellm-register-vllm -n 5 | grep register-vllm:"

`no vLLM endpoint recorded yet` means `vllm-amd:inference` has not published
`/etc/secrets/vllm-inference.env` — converge vLLM itself first.

**`test-service.sh` reports "DB model(s) without explicit api_key"**

`/model/info` never returns `api_key`, so a model with an *embedded* key reads as
missing even though the key is in the database. Register models against a named
credential instead:

    litellm-credentials.sh inspect
    litellm-credentials.sh assign-model --model <model_name> --credential <credential_name>

**SSO not offered, or the callback is rejected**

Check the translated settings exist and that `PROXY_BASE_URL` matches the host you
browse to — LiteLLM builds its `redirect_uri` from it, so a stale value makes
Authentik reject the redirect:

    ssh tappaas@<vmname>.<zone>.internal "sudo grep -cE '^GENERIC_' /etc/secrets/litellm-integrations.env"
    ssh tappaas@<vmname>.<zone>.internal "sudo grep '^PROXY_BASE_URL' /etc/secrets/litellm-integrations.env"

Zero `GENERIC_` keys means `identity:identity` has not run or the discovery
document was unreachable; re-run `module-manager reconcile litellm --apply`.

**Adding a new dependency: `modify` aborts on the pre-update test**

Expected. `modify` runs the pre-update test *before* applying, and a newly added
`dependsOn` entry cannot pass until the converge has created its resource (e.g.
the OIDC application). Re-run with `--force`; the failure is the change being
requested, not a fault:

    module-manager modify litellm --force

**Cannot connect to UI after install**

Verify firewall proxy is active: `rules-manager verify-rules litellm --no-ssl-verify`
Check VM is reachable: `nc -zv -w 5 litellm.srvWork.internal 4000`

**Master key lost**

    ssh tappaas@litellm.srvWork.internal
    sudo rm /etc/secrets/litellm.env
    sudo systemctl restart generate-litellm-secrets podman-litellm
    # New key generated — retrieve again with sudo cat

Warning: existing virtual keys remain valid; only the master key changes.

**Database not responding**

    ssh tappaas@litellm.srvWork.internal "systemctl status postgresql"
    ssh tappaas@litellm.srvWork.internal "sudo -u postgres psql -c '\l'"
