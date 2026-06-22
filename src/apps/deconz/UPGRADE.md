# deconz — Upgrade


## deCONZ application (the gateway software)

deCONZ is pinned by nixpkgs (`services.deconz` → `pkgs.deconz`). Upgrade
declaratively:

```bash
cd /home/tappaas/Community/src/ErikDaniel007/home-automation/deconz
./update.sh deconz        # rebuilds the NixOS VM from deconz.nix
```

A NixOS rebuild keeps the previous generation — roll back with
`nixos-rebuild --rollback` on the VM if a deCONZ release regresses.
The full VM is backed up daily via `backup:vm` (includes the Zigbee DB).

## Zigbee device firmware (OTA)

deCONZ ships the **STD OTAU** plugin (Zigbee OTA server). It is a **manual,
per-device** flow — NOT automatic background OTA like a vendor hub:

1. Fetch firmware to `~/otau` on the VM:
   - IKEA (mfr 117C): `ikea-ota-download.py`
   - Philips/Signify Hue (mfr 100B): Hue firmware files
2. Phoscon/deCONZ → Plugins → **OTA Update** → select device → choose .ota → Update.
3. **Disable "source routing beta" before flashing** (else Hue/other upgrades hang).
4. Not every device that advertises the OTA cluster implements it.

## Coordinator (ConBee II) firmware

Separate from device OTA — flash via deCONZ/GCFFlasher during a maintenance
window only if a release requires it.

## VM resources

deCONZ is featherweight (2 vCPU / 1 GB / 16 GB disk). The 16 GB disk is sized for
the NixOS store + generations, not deCONZ data. Grow only if `nix` GC headroom
runs low.
