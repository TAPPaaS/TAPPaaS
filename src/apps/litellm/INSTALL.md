# LiteLLM — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. All dependency modules are installed — in particular `vllm-amd` (local inference
   backend, see the `dependsOn` list in `litellm.json`).
2. Verify `litellm.json` matches your environment (node, storage, zone).

> To deviate from the defaults in `./litellm.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing.

Fields can also be overridden with flags at install time, e.g.
`install-module.sh litellm --node tappaas1 --zone0 srvDev --vmid 399 --memory 8192`,
or a named variant config (`--variant staging` reads `litellm-staging.json`).

## Install

    install-module.sh litellm

Duration: ~5–10 minutes on first run.

## Post-install

**1. Get the master key**

    ssh tappaas@litellm.srvWork.internal "sudo cat /etc/secrets/litellm.env"

Save this key in your password manager — it is the admin password for the UI and API.

**2. Open the UI and configure**

`http://litellm.srvWork.internal:4000/ui` — log in with the master key.

1. Settings → Credentials — add API keys (OpenRouter, Anthropic, Perplexity, …)
2. AI Hub — add models
3. Virtual Keys — create per-user or per-application keys

Reference: [LiteLLM proxy docs](https://docs.litellm.ai/docs/proxy/ui_credentials)

For upgrades of an existing install see [UPGRADE.md](./UPGRADE.md).

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

## Troubleshooting

**Container not starting**

    ssh tappaas@litellm.srvWork.internal "journalctl -u podman-litellm -n 50"

Common cause: API key not yet configured — add at least one provider credential
via UI first.

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
