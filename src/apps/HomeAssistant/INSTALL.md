# Home Assistant — Installation

Only manual steps are listed here. Scripts handle everything else automatically.

## Prerequisites

1. **HAOS image** — download `haos_ova-17.3.qcow2.xz` from the
   [HA OS releases page](https://github.com/home-assistant/operating-system/releases/tag/17.3)
   and place it in the Proxmox ISO storage on `tappaas1`.
2. **Static DHCP reservation** — assign a fixed IP to the HA VM's MAC address
   on the `srv_home` network (10.2.10.x range).
3. **DNS host override** — `homeassistant.srv_home.internal → <ip>` via `dns-manager`.

## Install

```bash
cd /home/tappaas/TAPPaaS/src/apps/HomeAssistant
install-module.sh homeassistant
```

This creates the VM, imports the HAOS disk image, and configures:
- Firewall proxy (`homeassistant.gridtefy.com`)
- Firewall pinholes to IoT modules (alfen, sonos, reolink)

## Post-install

**First boot — HA onboarding** (one-time):
1. Open `http://homeassistant.srv_home.internal:8123` from home WiFi
2. Complete the onboarding wizard (create admin account, home location)
3. HA will auto-discover Sonos speakers and prompt to add the integration

**Alfen EV charger** (if deployed):
- Settings → Devices & Services → Add integration → `alfen_wallbox` (via HACS)
- Host: `alfen.iot_cloud.internal`, port: `502`

**Zigbee/Z-Wave hardware** (optional):
- Add USB pass-through in Proxmox: VM → Hardware → Add → USB Device
- In HA: Settings → Integrations → add the relevant integration

## Verification

```bash
test-module.sh homeassistant
```

Manual checks:

| Check | Expected |
|-------|----------|
| `https://homeassistant.gridtefy.com` from home browser | HA login page loads |
| `http://homeassistant.srv_home.internal:8123` from home WiFi | HA login page loads |
| Home Assistant → Settings → Devices → Sonos | Speakers visible |

## Troubleshooting

**Onboarding page not loading**
Verify VM is running: `test-module.sh homeassistant`. Check DNS override is present.

**Sonos speakers not discovered**
Verify mDNS relay: `test-service.sh firewall:discovery homeassistant` should show relay present.
If pinholes are missing, run `install-module.sh homeassistant --force`.

**Alfen integration unavailable**
Confirm HACS is installed and `alfen_wallbox` integration is added.
Verify Modbus TCP is enabled on the charger (port 502).
