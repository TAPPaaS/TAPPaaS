# HomeAssistant

Home Assistant OS (HAOS) home automation platform, running as a dedicated VM in the `srv-home` zone.

## About

Deploys the official [Home Assistant Operating System](https://www.home-assistant.io/installation/linux/) image (HAOS) as a Proxmox KVM VM. HAOS includes:
- Home Assistant Core + Supervisor
- Full add-ons support (Zigbee, Z-Wave, HACS, SSH terminal, etc.)
- Built-in update management via the HA web UI

## Access

After install: `http://homeassistant:8123` (or via IP in the `srv-home` 10.2.10.x range)

## Image

| Field         | Value |
|---------------|-------|
| imageType     | `img` (HAOS qcow2 disk image) |
| Current image | `haos_ova-17.3.qcow2.xz` |
| Source        | https://github.com/home-assistant/operating-system/releases |
| BIOS          | OVMF (UEFI — required by HAOS) |

To update to a newer HAOS release at deploy time, change `image` and `imageLocation` in `homeassistant.json`.

**Note:** HAOS handles runtime updates itself via the web UI — no TAPPaaS intervention needed.

## VMID Scheme

VMID 210 starts the **2XX range for srv-home apps** (VLAN 210):
- 200–209: reserved / externally managed
- 210+: TAPPaaS-managed srv-home apps

## USB Pass-through (Zigbee/Z-Wave)

For hardware integrations (Zigbee stick, Z-Wave dongle), add USB pass-through in Proxmox after VM creation:

1. Identify the USB device on the node: `lsusb`
2. In Proxmox GUI: VM → Hardware → Add → USB Device
3. In HA: Settings → Integrations → add the integration

## Install

```bash
cd /home/tappaas/TAPPaaS/src/apps/HomeAssistant
./install.sh homeassistant
```

## Test

```bash
./test.sh homeassistant
```
