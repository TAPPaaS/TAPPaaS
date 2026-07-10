# deconz

Primary audience: home user with Zigbee devices; Home Assistant administrator.

Standalone Zigbee gateway (ConBee II) with a native Hue-compatible bridge API — runs the
Zigbee network on its own VM so daily lighting does not depend on Home Assistant being up.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Zigbee network (`zigbee`) | Home Assistant (`srvHome`) | `deconz` integration (REST 8080, ws 8443) |
| Hue-compatible bridge (`bridge`) | SysAP (`iotCloud`) | Hue API TCP 8080 + SSDP UDP 1900 |
| Phoscon admin UI | `mgmt` zone | `http://deconz.iotCloud.internal:8080` via the reverse proxy |

## What is not included

- No MQTT broker — HA's deCONZ integration uses the websocket, not MQTT.
- Hue Entertainment/sync — a Hue-bridge-only feature, not available on deCONZ.
- No automatic background device-firmware OTA — updates are a manual, per-device flow
  (see [UPGRADE.md](./UPGRADE.md)).
- No engine-to-engine migration from ZHA — moving from ZHA means re-pairing all devices.

## Requirements

- ConBee II USB coordinator (`1cf1:0030`) physically attached to the target node
  (`tappaas2`). USB passthrough pins the VM to its node (no HA failover).
- `iotCloud` zone; consumers reach it cross-zone via firewall pinholes
  (HA: `srvHome` -> `iotCloud` on 8080/8443).
- Home Assistant is optional — deCONZ runs standalone; HA is just one consumer.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | The NixOS VM (clone of the golden template) |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Full-VM PBS backup (includes the Zigbee DB) |
| `firewall:proxy` | Phoscon admin UI behind the reverse proxy (`mgmt` only) |
| `firewall:rules` | Pinholes for the `zigbee` + `bridge` services (8080, 8443, 1900) |

For installation steps see [INSTALL.md](./INSTALL.md).
