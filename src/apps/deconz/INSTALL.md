# deconz — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. Free VMID — confirm 213 is free (live `qm`/`pct` + every repo's modules.json + config).
   Re-assign in `deconz.json` if taken.
2. ConBee II physically on the target node (`tappaas2`). Note its USB id
   (`lsusb` -> dresden elektronik, expected `1cf1:0030`) and serial.
3. Move the ConBee off the old ZHA host (VM 200) before pairing here — one coordinator per
   stick. Migrating ZHA -> deCONZ means re-pairing all devices (no engine-to-engine
   migration).

> To deviate from the defaults in `./deconz.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing.

## Install

    install-module.sh deconz

This clones the NixOS golden template and applies `deconz.nix` (`services.deconz`),
attaches the ConBee II to the VM (`qm set -usb0 host=1cf1:0030`), and opens the firewall
(8080/8443 TCP, 1900 UDP) plus the Phoscon proxy (`mgmt`).

## Post-install

1. Confirm the ConBee device path on the VM and align `deconz.nix` if needed:

       ls -l /dev/serial/by-id/    # expect ...ConBee_II_<serial>-if00

   If the USB device is absent (attached while the VM was running), restart the VM.
2. Pair devices and scenes in Phoscon: open `http://deconz.iotCloud.internal:8080`
   (via the mgmt proxy), press the gateway link button, add lights/sensors/switches.
   Create scenes per group (stored on-device).
3. Home Assistant: Settings -> Devices & Services -> Add deCONZ -> host
   `deconz.iotCloud.internal`, port `8080` (websocket auto-negotiated on 8443).
   Entities appear automatically.
4. SysAP (free@home) — control lights via the Hue API: add `"deconz:bridge"` to
   `sysap.dependsOn` and re-run `install-module.sh sysap`. This grants SysAP the pinhole
   to deconz 8080 + SSDP discovery, so SysAP discovers deCONZ as a Hue bridge
   (replaces HA `emulated_hue`).

## Verification

    test-module.sh deconz

| Check | Expected |
|-------|----------|
| `http://deconz.iotCloud.internal:8080/api/config` | HTTP 200 with the bridge descriptor |
| Websocket port 8443 | Reachable (HA live-event channel) |
| `bash services/zigbee/test-service.sh hass` | HA-side reachability + pinholes pass |
| `bash services/bridge/test-service.sh sysap` | SysAP-side reachability + pinholes pass |

## Troubleshooting

**deCONZ does not see the ConBee**
Wrong/renumbered device path. Use the `/dev/serial/by-id/...` path in `deconz.nix`,
never `/dev/ttyACM0`. Restart the VM if the USB was attached late.

**SysAP cannot discover the bridge**
SSDP not relayed across zones. Verify the `firewall:discovery` relay (UDP 1900) and the
`bridge` pinhole.

**Aqara device won't pair / no battery**
Per-model DDF; check the deCONZ compatibility list and update DDF bundles.
