# Home Assistant — Home Automation Platform

Primary audience: home user, household administrator.

Central hub for all smart home integrations. Control lights, energy,
security, EV charging and audio from one interface — locally, without
cloud dependency.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Home Assistant web UI | Home WiFi, work | `https://homeassistant.gridtefy.com` |
| Mobile app | Home WiFi, internet (via proxy) | Home Assistant companion app |
| Alfen EV charger integration | Home Assistant | Modbus TCP — auto-discovered |
| Sonos audio control | Home Assistant | Sonos built-in integration — auto-discovered |
| Add-ons (HACS, SSH, Zigbee…) | Home Assistant | HA Supervisor add-on store |

## What is not included

- Cloud account or Nabu Casa subscription (fully local by default)
- Zigbee/Z-Wave hardware integration — requires USB pass-through configured in Proxmox after VM creation
- Voice assistant setup (Google Home, Alexa) — optional, configured in HA

## Requirements

- Proxmox node with storage pool `tanka1`
- UEFI boot support (OVMF — included in Proxmox)
- `srv-home` network zone (VLAN 210)

## Known limitation

HAOS manages its own runtime updates via the web UI — do not update via
TAPPaaS `update-module.sh`. The module version tracks the initial image
used at deploy time; HAOS self-updates from there.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `backup:vm` | Scheduled VM snapshots |
| `firewall:proxy` | HTTPS reverse proxy — `homeassistant.gridtefy.com` |
| `identity:identity` | SSO integration (optional) |
| `firewall:rules` | Firewall pinholes to IoT modules |
| `alfen:ui` `alfen:discovery` `alfen:modbus` | Cross-zone access to Alfen EV charger |
| `sonos:audio` `sonos:airplay` | Cross-zone access to Sonos speakers |

For installation steps see [INSTALL.md](./INSTALL.md).
