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

## Grouping — expose a fixture/room as ONE entity to the SysAP

By default diyHue imports each deCONZ light individually, so the SysAP controls a
multi-lamp fixture as **N separate per-light commands** (a visible ripple, and the
SysAP paces them ~0.35 s apart). A physical fixture (e.g. bedroom-south = 4 lamps)
should be **one** entity. This is how it worked pre-migration: HA's `emulated_hue`
exposed each room as a single (ZHA-group) entity, not the individual lamps.

**Solution — synthetic group-lights (implemented).** deCONZ already holds the
groups (one per room/fixture). We present each deCONZ group to the SysAP as **one
diyHue light** whose writes hit deCONZ `/groups/<id>/action` → **one Zigbee
groupcast** (atomic). Two pieces, both shipped:

1. **Adapter** (`deconz.nix` → bind-mounted `deconz.py`): a light with
   `protocol_cfg.deconzType == "group"` routes to the group action endpoint instead
   of per-light. Backward-compatible (normal lights unchanged).
2. **Registration** (`services/hue-bridge/register-group-lights.sh`): idempotently
   creates one diyHue light per non-empty deCONZ group, named to match the old
   emulated_hue names (`Spot-WW BN`, `Spot-WW BS`, …). Run on the VM:
   ```bash
   sudo bash /etc/.../register-group-lights.sh   # or copy from the module dir
   ```

**Measured:** one PUT → one groupcast, ~10 ms, all lamps atomic (vs ~1.15 s ripple).

### Cut-over procedure (per fixture, no flag day)
1. Run the registration script — the group-lights appear (additive; nothing breaks).
2. In **free@home**, fixture by fixture: unlink the individual lamps from the switch,
   add the group-light (`Spot-WW <room>`), wire the switch to it.
3. **Only after ALL fixtures are re-linked**, prune the 24 individual lights from
   diyHue. Removing them earlier breaks any switch still wired to an individual.
   When you remove a light from diyHue, the SysAP marks its imported copy
   **unresponsive/stale** (it does not auto-delete) — clear the stale entries in the
   free@home app.

Note: the group lives in **deCONZ/Phoscon** (the SSOT) and the entries appear under
diyHue **Lights**, not Groups — that is deliberate (the SysAP imports lights as
single entities; diyHue's own Groups iterate per-light). HA is unaffected — it talks
to deCONZ natively, so the individual lamps remain fully controllable there.

## VM resources

deCONZ is featherweight (2 vCPU / 1 GB / 16 GB disk). The 16 GB disk is sized for
the NixOS store + generations, not deCONZ data. Grow only if `nix` GC headroom
runs low.
