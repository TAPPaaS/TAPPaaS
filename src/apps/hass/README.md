# Home Assistant

Primary audience: home user; Home Assistant administrator.

Central hub for all smart home integrations — control lights, energy, security, EV
charging and audio from one interface, locally, without cloud dependency.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Home Assistant web UI | `mgmt` and `home` zones (via proxy) | `https://hass.<tappaas.domain>` |
| Web UI, direct/internal | `srvHome` zone | `http://hass.srvHome.internal:8123` |
| Mobile app | Home WiFi, internet (via proxy) | Home Assistant companion app |
| Alfen EV charger integration | Home Assistant | Modbus TCP — auto-discovered |
| Sonos audio control | Home Assistant | Sonos built-in integration — auto-discovered |
| Reolink camera streams | Home Assistant | RTSP streaming, motion events |
| Add-ons (HACS, SSH, Zigbee…) | Home Assistant | HA Supervisor add-on store |

## What is not included

- Cloud account or Nabu Casa subscription (fully local by default).
- Zigbee/Z-Wave hardware integration — requires USB pass-through configured in Proxmox
  after VM creation (or the standalone `deconz` module).
- Voice assistant setup (Google Home, Alexa) — optional, configured in HA.
- Centralised Authentik SSO (`identity:identity`) — not applicable to the sealed HAOS
  appliance; external access is gated at the proxy layer instead (see
  [DESIGN.md](./DESIGN.md)).
- Updates via `update-module.sh` — HAOS manages its own runtime updates via the web UI.
  The module version tracks the initial image used at deploy time.

## Requirements

- Proxmox node with the storage pool configured in `hass.json`.
- UEFI boot support (OVMF — included in Proxmox).
- An active network zone (default `srvHome`), configured in `zones.json` and OPNsense.
- The IoT integrations (alfen, sonos, reolink) only work when those modules are deployed.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning (HAOS image import, OVMF, no cloud-init) |
| `backup:vm` | Scheduled VM snapshots (PBS) |
| `network:proxy` | HTTPS reverse proxy (`mgmt`, `home` zones) |
| `network:rules` | Firewall pass rule for the web UI (TCP 8123) |
| `alfen:ui`, `alfen:discovery`, `alfen:modbus` | EV charger: UI, discovery, Modbus TCP (optional) |
| `sonos:audio`, `sonos:airplay` | Multi-room audio — control API, AirPlay (optional) |
| `reolink:rtsp` | Surveillance cameras — RTSP streaming (optional) |

For installation steps see [INSTALL.md](./INSTALL.md).
