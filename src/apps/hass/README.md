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

## Known limitation

HAOS manages its own runtime updates via the web UI — do not update via
TAPPaaS `update-module.sh`. The module version tracks the initial image
used at deploy time; HAOS self-updates from there.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `backup:vm` | Scheduled VM snapshots |
| `firewall:proxy` | HTTPS reverse proxy |
| `identity:identity` | SSO integration (optional) |
| `firewall:rules` | Firewall pinholes to IoT modules |

**IoT module integrations** (optional — only when the module is deployed):

| Module | Purpose | Docs |
|--------|---------|------|
| `alfen` | EV charger — web UI, discovery, Modbus TCP | [alfen →](https://github.com/TAPPaaS/Community/blob/main/src/ErikDaniel007/energy/alfen/README.md) |
| `sonos` | Multi-room audio — control API, AirPlay | [sonos →](https://github.com/TAPPaaS/Community/blob/main/src/ErikDaniel007/entertainment/sonos/README.md) |
| `reolink` | Surveillance cameras — RTSP streaming, motion events | [reolink →](https://github.com/TAPPaaS/Community/blob/main/src/ErikDaniel007/surveillance/reolink/README.md) |

For installation steps see [INSTALL.md](./INSTALL.md).
