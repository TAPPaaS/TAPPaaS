# n8n — Installation

Primary audience: TAPPaaS admin.

> Status: placeholder. The module has no `n8n.json`, `install.sh`, or VM
> configuration yet, so the standard install below will not work until the
> module is implemented. The sections describe the standard TAPPaaS flow that
> will apply once it is.

## Prerequisites

1. None defined yet — the module is not implemented.

> To deviate from the defaults in `./n8n.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing. (The json does not exist yet.)

## Install

    install-module.sh n8n

## Post-install

None defined yet.

## Verification

    test-module.sh n8n

| Check | Expected |
|-------|----------|
| — | to be defined when the module is implemented |

## Troubleshooting

**install-module.sh fails immediately**

Expected — the module is a placeholder with no `n8n.json` or install scripts.
