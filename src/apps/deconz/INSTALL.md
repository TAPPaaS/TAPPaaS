# deconz — Installation


## Prerequisites

1. **Free VMID** — confirm 213 is free (live `qm`/`pct` + every repo's modules.json
   + config). Re-assign in `deconz.json` if taken.
2. **ConBee II** physically on the target node (`tappaas1`). Note its USB id
   (`lsusb` → dresden elektronik, expected `1cf1:0030`) and serial.
3. **Move the ConBee off the old ZHA host** (VM 200) before starting here — one
   coordinator per stick. **No re-pair needed:** reusing the same coordinator (same
   channel / PAN / network key) keeps every device joined. Take a Zigbee network
   backup first (channel / PAN / network key) as insurance — power-cycle devices to
   force re-announce if some don't show immediately.

## Install

```bash
cd /home/tappaas/Community/src/ErikDaniel007/home-automation/deconz
install-module.sh deconz        # run FROM the module dir (install-module is pwd-based)
```

This:
- clones the NixOS golden template and applies `deconz.nix` (`services.deconz`
  + the diyHue podman container);
- attaches the ConBee II to the VM (`update.sh`: `qm set -usb0 host=1cf1:0030`);
- opens the firewall (8080/8443 TCP for deCONZ; 80/443 TCP + 1900/2100 UDP for
  diyHue) and the Phoscon proxy (mgmt).

**After first attach**, confirm the device path on the VM and align `deconz.nix`
if needed:

```bash
ls -l /dev/serial/by-id/    # expect ...ConBee_II_<serial>-if00
```

If the USB device is absent (attached while the VM was running), restart the VM.

## Post-install

### 1. Verify devices in Phoscon
Open `http://deconz.<mgmt-proxy>:8080`. With the reused coordinator the existing
24 IKEA lights + 8 Aqara sensors should already be present. If any are missing,
power-cycle that device to force a re-announce (no re-pair). For Aqara: hard-reset
+ keep close to a router during join.

### 2. Home Assistant (native path)
Settings → Devices & Services → Add **deCONZ** → host `deconz` IP, port `8080`
(websocket auto-negotiated on 8443). Entities appear automatically.

### 3. SysAP (free@home) — control lights via diyHue
The `hue-bridge` is diyHue, started by the module. To pair it to the SysAP:

1. **Link the deCONZ backend into diyHue** (out-of-the-box method): unlock the
   deCONZ gateway in Phoscon, then open `http://<deconz-vm>/deconz` — diyHue
   auto-registers and imports lights+sensors. (The settings *form* is flaky — a
   2 s UI timeout; `/deconz` or seeding `config.deconz` directly is the robust path.)
2. In the SysAP, add the Hue bridge as a source. The SysAP discovers diyHue via
   SSDP (UDP 1900). deCONZ's own SSDP is disabled (`--upnp=0`) so only diyHue
   advertises — otherwise the SysAP dedups by IP and locks onto deCONZ (which it
   then rejects).
3. **Timezone must match** across the diyHue container `TZ`, its `config.yaml`
   `timezone`, and your browser — else the Hue link-button timestamp check fails
   and the bridge never pairs. The module pins `TZ=Europe/Amsterdam`.
4. In the SysAP, wire each free@home switch to its light(s) as normal.

## Verification

```bash
bash test.sh deconz                              # service + API health
bash services/zigbee/test-service.sh hass        # HA-side reachability + pinholes
bash services/hue-bridge/test-service.sh sysap   # SysAP-side reachability + pinholes
```

## Troubleshooting

**deCONZ does not see the ConBee** — wrong/again-renumbered device path. Use the
`/dev/serial/by-id/...` path in `deconz.nix`, never `/dev/ttyACM0`. Restart the VM
if the USB was attached late.

**SysAP shows the bridge "pairing" forever / rejects it** — it locked onto deCONZ's
own Hue emulation. Confirm `--upnp=0` is active on deCONZ (only diyHue should
advertise on UDP 1900). Remove the half-paired entry in the SysAP and re-add.

**diyHue link button "please check timezone setting"** — `TZ` / `config.yaml
timezone` / browser tz mismatch. Align all three to `Europe/Amsterdam`.

**Lights respond after seconds / not at all** — upstream diyHue's deCONZ adapter
has an unconditional `sleep(0.7)` per light (a 24-light room ≈ 17 s). `deconz.nix`
ships a patched adapter (bind-mounted, image pinned by digest) — see README →
Performance. Confirm `/etc/diyhue/deconz.py` is mounted into the container if slow.

**Want a fixture/room as ONE entity in the SysAP** (not N lamps) — expose the
deCONZ group as a single diyHue entity (groupcast), see UPGRADE.md → grouping.

**Aqara device won't pair / no battery** — per-model DDF; hard-reset the device,
keep it close to a router during join, check the deCONZ compatibility list.
