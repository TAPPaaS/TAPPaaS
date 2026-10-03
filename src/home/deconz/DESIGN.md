# deconz — Design notes

## Why this exists

- **Decouple Zigbee from HA.** ZHA cannot run standalone — if HA is down, Zigbee is down.
  deCONZ is an independent service; HA is just one consumer (official `deconz`
  integration over the websocket).
- **Replace HA `emulated_hue`.** deCONZ *is* a Hue-compatible bridge by design, so SysAP
  talks to it directly as a Hue bridge — HA out of the control path (supports the
  ADR-COM-0005 control-plane split).
- **No MQTT broker** — HA's deCONZ integration uses the websocket, not MQTT.

## Services offered (`provides`)

| Service | Ports | Used for |
|---------|-------|----------|
| `zigbee` | TCP 8080, 8443 | Native deCONZ REST + websocket (Home Assistant) |
| `bridge` | TCP 8080, UDP 1900 | Hue-compat REST + SSDP (SysAP); interchangeable with `hue:bridge` |

SSDP discovery is intra-zone only (`iotCloud`); no cross-zone relay (ADR-COM-0006).
The HA REST/websocket path is a cross-zone pinhole (`srvHome` -> `iotCloud`).

## Device support

- **IKEA Trådfri** — full (standard Zigbee 3.0). OTA via deCONZ OTAU (mfr 117C).
- **Philips Hue lamps** — supported as standard Zigbee lights (bridge bypassed);
  OTA via OTAU (Signify 100B). Hue Entertainment/sync is bridge-only — not on deCONZ.
- **Aqara/LUMI** — per-model via DDF (door/window, water, temp, humidity, vibration, lux,
  motion — each with a battery %). Verify specific models on the deCONZ compatibility
  list; Aqara battery reporting is quirky.

## Scenes

Created in Phoscon (Group -> Scenes) and stored as the Zigbee Scenes cluster on the
devices -> recalled by a bound switch even with HA/deCONZ down (the resilient layer).
Exposed to HA as `scene.<group>_<name>` and via the Hue API.
**SSOT rule:** daily single-radio scenes live on-device; HA scenes only for cross-system.

## Hardware / USB passthrough

- ConBee II USB coordinator (reused from the previous ZHA setup), vendor:product
  `1cf1:0030`.
- Attached to the VM by `update.sh` (`qm set -usb0 host=1cf1:0030`) — module-local, the
  engine is untouched (marked `FOUNDATION-CANDIDATE`: promote to a `usb` field on
  `cluster:vm` when a second USB module appears). USB pins the VM to its node (no HA
  failover).
- `DECONZ_SKIP_USB=1` before install/update does a phase-0 smoke deploy: brings up the VM
  and service without grabbing the ConBee (e.g. while it is still on the live ZHA VM).
  deCONZ then runs with no coordinator until the cutover.

## Sizing

deCONZ is featherweight; the disk is sized for the NixOS store + generations, not deCONZ
data (see `deconz.json` for current values). Grow only if `nix` GC headroom runs low.
