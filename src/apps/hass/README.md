# Home Assistant — Home Automation Platform

> **⚠️ Deployment note (temporary):** Until PR #278 (zones.json hyphen/underscore) is
> resolved, deploy in a zone without underscores in the name. Use `--zone0 work` as a
> test deployment:
> ```bash
> install-module.sh hass --zone0 work --vmid <id>
> ```
> Production zone is `srv_home`. Revert once PR #278 is merged.

Central hub for all smart home integrations. Control lights, energy,
security, EV charging and audio from one interface — locally, without
cloud dependency.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Home Assistant web UI | Configured zones | `https://<vmname>.<tappaas.domain>` |
| Mobile app | Home WiFi, internet (via proxy) | Home Assistant companion app |
| Alfen EV charger integration | Home Assistant | Modbus TCP — auto-discovered |
| Sonos audio control | Home Assistant | Sonos built-in integration — auto-discovered |
| Add-ons (HACS, SSH, Zigbee…) | Home Assistant | HA Supervisor add-on store |

## What is not included

- Cloud account or Nabu Casa subscription (fully local by default)
- Zigbee/Z-Wave hardware integration — requires USB pass-through configured in Proxmox after VM creation
- Voice assistant setup (Google Home, Alexa) — optional, configured in HA

## Requirements

- Proxmox node with storage pool configured in `hass.json`
- UEFI boot support (OVMF — included in Proxmox)
- Active network zone without underscores in zone name (see deployment note above)

## Security note — bootstrap admin account

The `hass:config` service creates a `tappaas` user with **owner + system-admin**
access during first-run onboarding. This is required to bootstrap the Long-Lived Access
Token (LLAT) used for automation. The account credentials are stored in
`/etc/secrets/hass.env` on the Proxmox node.

**Recommended after first login:** change the `tappaas` user password in HA → Profile.
The LLAT remains valid after a password change.

## Shell access (appliance)

HAOS is a sealed appliance and does not run the normal TAPPaaS NixOS SSH model
(no `tappaas` user on port 22). Shell access is the HAOS **host SSH on port
22222 as `root` (key-only)**, enabled on boot by a small FAT disk **labelled
`CONFIG`** holding `authorized_keys` = the canonical `tappaas-cicd.pub`.

Because HAOS ignores cloud-init, the shared deployment engine cannot inject the
key. Instead the module's own **`lib/appliance-ssh.sh`** (run from `install.sh`)
builds + attaches this disk over `ssh root@<node> qm` after VM creation, enables
the QEMU guest agent with `freeze-fs-on-backup`, then cold stop/starts the VM so
HAOS reads the CONFIG label. **The shared engine (`Create-TAPPaaS-VM.sh`) is
unchanged** — the appliance special-case stays inside this module.

```bash
ssh -p 22222 root@<hass-ip>
```

## Authentication / identity (appliance — no `identity:identity`)

This module deliberately does **not** declare `identity:identity` in `dependsOn`.
The standard OIDC wiring writes `/etc/secrets/<module>.env` over `ssh tappaas@<vm>:22`
and restarts a NixOS `*-configure-oidc.service` — none of which exist on a sealed
HAOS appliance (no `tappaas` user, no `/etc/secrets`, no NixOS systemd unit). HA's
own auth is bootstrapped by the `hass:config` service via the LLAT + `secrets.yaml`,
so the OIDC-injection path is not applicable here. Centralised Authentik SSO returns
when hass becomes **HA Core on NixOS** (native module — see "Management/access model"),
which gets `identity:identity` wiring for free. Until then, external access is gated at
the proxy/Authentik layer, not via this dependency.

## Known limitation

HAOS manages its own runtime updates via the web UI — do not update via
TAPPaaS `update-module.sh`. The module version tracks the initial image
used at deploy time; HAOS self-updates from there.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `backup:vm` | Scheduled VM snapshots |
| `network:proxy` | HTTPS reverse proxy |
| `network:rules` | Firewall pinholes to IoT modules |

**IoT module integrations** (optional — only when the module is deployed):

| Module | Purpose | Docs |
|--------|---------|------|
| `alfen` | EV charger — web UI, discovery, Modbus TCP | [alfen →](https://github.com/TAPPaaS/Community/blob/main/src/ErikDaniel007/energy/alfen/README.md) |
| `sonos` | Multi-room audio — control API, AirPlay | [sonos →](https://github.com/TAPPaaS/Community/blob/main/src/ErikDaniel007/entertainment/sonos/README.md) |
| `reolink` | Surveillance cameras — RTSP streaming, motion events | [reolink →](https://github.com/TAPPaaS/Community/blob/main/src/ErikDaniel007/surveillance/reolink/README.md) |

For installation steps see [INSTALL.md](./INSTALL.md).
