# OpenWebUI — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. LiteLLM must be deployed and accessible before installing OpenWebUI
   (`litellm:models` dependency).
2. Verify `openwebui.json` matches your environment (node, storage, zone).

> To deviate from the defaults in `./openwebui.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing.

Fields can also be overridden with flags at install time, e.g.
`install-module.sh openwebui --node tappaas1 --zone0 srvDev --vmid 399`,
or a named variant config (`--variant staging`).

## Install

    install-module.sh openwebui

Duration: ~10–20 minutes on first run (NixOS rebuild + container pull ~1 GB).

## Post-install

First login (one-time):

1. Open `http://openwebui.srvWork.internal:8080`
2. Create admin account
3. Settings → Connections → OpenAI API:
   - Base URL: `http://litellm.srvWork.internal:4000/v1`
   - API Key: your LiteLLM virtual key
4. Test: start a conversation, select a model

For upgrades of an existing install see [UPGRADE.md](./UPGRADE.md).
To restore application data from backups see [RESTORE.md](./RESTORE.md).

## Verification

    test-module.sh openwebui

| Check | Expected |
|-------|----------|
| SSH connectivity | PASS |
| OpenWebUI container | running |
| HTTP endpoint on port 8080 | responding (200) |
| PostgreSQL | accepting connections |
| Redis | responding to PING |

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
