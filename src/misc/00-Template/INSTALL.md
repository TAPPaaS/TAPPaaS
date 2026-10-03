# <Module Name> — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. <manual pre-condition that scripts cannot handle>

> To deviate from the defaults in `./<module>.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing.

## Install

    install-module.sh <module>

## Post-install

<manual steps on the device, in third-party systems, etc. — only what the
scripts cannot automate. If there are none, say "None.">

## Verification

    test-module.sh <module>

| Check | Expected |
|-------|----------|
| <manual check> | <expected result> |

## Troubleshooting

**<symptom>**
<diagnosis and fix>
