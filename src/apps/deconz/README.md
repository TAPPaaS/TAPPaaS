# deconz — standalone Zigbee gateway (ConBee II) + Hue-bridge API


deCONZ runs the Zigbee network on a **dedicated NixOS VM** instead of inside
Home Assistant. HA consumes it over the deCONZ websocket; SysAP (free@home)
controls lights through deCONZ's **native Hue-compatible API** — so daily
lighting no longer depends on HA being up.

## Why this exists

- **Decouple Zigbee from HA.** ZHA cannot run standalone — if HA is down, Zigbee
  is down. deCONZ is an independent service; HA is just one consumer.
- **Replace HA `emulated_hue`.** deCONZ *is* a Hue-compatible bridge by design,
  so SysAP talks to it directly as a Hue bridge — HA out of the control path
  (supports the ADR-COM-0005 control-plane split).
- **No MQTT broker** — HA's deCONZ integration uses the websocket, not MQTT.

## What you get

| Capability | Consumer | Access | How |
|---|---|---|---|
| `zigbee` | Home Assistant (`srvHome`) | TCP 8080 (REST) + 8443 (ws) | official `deconz` integration |
| `bridge` | SysAP (`iotCloud`) | TCP 8080 (Hue API) + UDP 1900 (SSDP) | Hue-compat API (= `hue:bridge` capability) |
| Admin UI | mgmt | TCP 8080 via reverse proxy | Phoscon web UI |

## Services offered (`provides`)

| Service | Ports | Used for |
|---|---|---|
| `zigbee` | TCP 8080, 8443 | native deCONZ REST + websocket (Home Assistant) |
| `bridge` | TCP 8080, UDP 1900 | Hue-compat REST + SSDP (SysAP) — interchangeable with `hue:bridge` |

## Device support

- **IKEA Trådfri** — full (standard Zigbee 3.0). OTA via deCONZ OTAU (mfr 117C).
- **Philips Hue lamps** — supported as standard Zigbee lights (bridge bypassed);
  OTA via OTAU (Signify 100B). *Hue Entertainment/sync is bridge-only — not on deCONZ.*
- **Aqara/LUMI** — per-model via DDF (door/window, water, temp, humidity, vibration,
  lux, motion — each with a battery %). Verify specific models on the deCONZ
  compatibility list; Aqara battery reporting is quirky.

## Scenes

Created in **Phoscon** (Group → Scenes) and stored as the **Zigbee Scenes cluster
on the devices** → recalled by a bound switch even with HA/deCONZ down (the
resilient layer). Exposed to HA as `scene.<group>_<name>` and via the Hue-API.
**SSOT rule:** daily single-radio scenes live on-device; HA scenes only for
cross-system.

## Hardware

- ConBee II USB coordinator (reused from the previous ZHA setup).
- Attached to this VM by `update.sh` (`qm set -usb0 host=1cf1:0030`) — module-local
  (engine untouched). USB pins the VM to its node (no HA failover).

## Dependencies

| Depends on | Purpose |
|---|---|
| `cluster:vm` | the NixOS VM (clone of the golden template) |
| `templates:nixos` | NixOS base image |
| `backup:vm` | full-VM PBS backup (includes the Zigbee DB) |
| `firewall:proxy` | Phoscon admin UI behind the reverse proxy (mgmt only) |
| `firewall:rules` | pinholes for the `zigbee` + `bridge` services |

For installation steps see [INSTALL.md](./INSTALL.md); upgrades see [UPGRADE.md](./UPGRADE.md).
