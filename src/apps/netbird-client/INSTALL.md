# NetBird Client — Installation

Primary audience: TAPPaaS admin.

> Status: the module is currently marked not working — see the note in
> [README.md](./README.md) and the known issues in [DESIGN.md](./DESIGN.md).

## Prerequisites

1. A NetBird account with access to the NetBird dashboard.
2. Generate a one-off setup key for this VM:
   1. Access your NetBird dashboard
   2. Navigate to the Setup Keys section
   3. Click the Create Setup Key button on the right
   4. Name your key (e.g., "ProxmoxLXC")
   5. Set an expiration date (recommended for enhanced security)
   6. Configure auto-assigned groups if needed (e.g., "Homelab")
   7. Click Create Setup Key to generate the setup key

> To deviate from the defaults in `./netbird-client.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing.

## Install

    install-module.sh netbird-client

## Post-install

1. Install the NetBird client on the VM (the automated step is currently
   disabled in `install.sh`):

       ssh root@netbird-client.home.internal \
         "curl -fsSL https://pkgs.netbird.io/install.sh | sh"

2. Connect the client to your account using the setup key generated in
   Prerequisites, on the VM:

       netbird up --setup-key <SETUP KEY>

## Verification

    test-module.sh netbird-client

Note: the module has no `test.sh` yet; verify manually.

| Check | Expected |
|-------|----------|
| VM reachable | `ssh root@netbird-client.home.internal` succeeds |
| Peer registered | The VM appears as a connected peer in the NetBird dashboard |

## Troubleshooting

**Module does not come up as a working NetBird peer**

The module is currently marked not working. The NetBird package install step
in `install.sh` is commented out — run the manual install command from
Post-install above, then `netbird up --setup-key <SETUP KEY>` again.
