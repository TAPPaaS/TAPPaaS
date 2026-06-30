# deconz — Installation


## Prerequisites

1. **Free VMID** — confirm 213 is free (live `qm`/`pct` + every repo's modules.json
   + config). Re-assign in `deconz.json` if taken.
2. **ConBee II** physically on the target node (`tappaas2`). Note its USB id
   (`lsusb` → dresden elektronik, expected `1cf1:0030`) and serial.
3. **Move the ConBee off the old ZHA host** (VM 200) before pairing here — one
   coordinator per stick. Migrating ZHA→deCONZ means **re-pairing all devices**
   (no engine-to-engine migration).

## Install

```bash
cd /home/tappaas/Community/src/ErikDaniel007/home-automation/deconz
install-module.sh deconz
```

This:
- clones the NixOS golden template and applies `deconz.nix` (`services.deconz`);
- attaches the ConBee II to the VM (`update.sh`: `qm set -usb0 host=1cf1:0030`);
- opens the firewall (8080/8443 TCP, 1900/UDP) and the Phoscon proxy (mgmt).

**After first attach**, confirm the device path on the VM and align `deconz.nix`
if needed:

```bash
ls -l /dev/serial/by-id/    # expect ...ConBee_II_<serial>-if00
```

If the USB device is absent (attached while the VM was running), restart the VM.

## Post-install

### 1. Pair devices + scenes (Phoscon)
Open `http://deconz.srvHome.internal:8080` (via the mgmt proxy), press the
gateway link button, and add lights/sensors/switches. Create scenes per group
(stored on-device).

### 2. Home Assistant
Settings → Devices & Services → Add **deCONZ** → host `deconz.srvHome.internal`,
port `8080` (websocket auto-negotiated on 8443). Entities appear automatically.

### 3. SysAP (free@home) — control lights via the Hue API
Add `"deconz:bridge"` to `sysap.dependsOn` and re-run `install-module.sh sysap`.
This grants SysAP the cross-zone pinhole (iotCloud → deconz 8080) + SSDP relay,
so SysAP discovers deCONZ as a Hue bridge. (Replaces HA `emulated_hue`.)

## Verification

```bash
bash test.sh deconz                       # service + API health
bash services/zigbee/test-service.sh hass # HA-side reachability + pinholes
bash services/bridge/test-service.sh sysap # SysAP-side reachability + pinholes
```

## Troubleshooting

**deCONZ does not see the ConBee** — wrong/again-renumbered device path. Use the
`/dev/serial/by-id/...` path in `deconz.nix`, never `/dev/ttyACM0`. Restart the VM
if the USB was attached late.

**SysAP cannot discover the bridge** — SSDP not relayed across iotCloud↔srvHome.
Verify the `firewall:discovery` relay (UDP 1900) and the `bridge` pinhole.

**Aqara device won't pair / no battery** — per-model DDF; check the deCONZ
compatibility list and update DDF bundles.
