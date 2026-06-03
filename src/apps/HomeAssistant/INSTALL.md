# Home Assistant — Installation

Only manual steps are listed here. Scripts handle everything else automatically.

## Prerequisites

1. **Active network zone** — the target zone must be active in `zones.json` and configured
   in OPNsense. See `homeassistant.json` for the configured `zone0`.
2. **HAOS image** — downloaded automatically by `install-module.sh` from the URL in
   `homeassistant.json` (`config.cluster:vm.imageLocation`). No manual download needed.

## Install

```bash
cd /home/tappaas/TAPPaaS/src/apps/HomeAssistant
install-module.sh homeassistant
```

Override zone and VMID if needed (e.g. test deployment):

```bash
install-module.sh homeassistant --zone0 work --vmid 211
```

This creates the VM, imports the HAOS disk image, and configures automatically:
- Firewall proxy (HTTPS reverse proxy for the configured domain)
- Firewall pinholes to IoT modules (alfen, sonos, reolink)
- HAOS trusted_proxies, external_url and LLAT bootstrap (`homeassistant:config` service)

## Post-install

**Onboarding is automated.** The `homeassistant:config` service:
- Creates admin user `tappaas` with a generated password
- Stores credentials in `/etc/secrets/homeassistant.env` on the Proxmox node
- Writes `trusted_proxies` + `use_x_forwarded_for` to `configuration.yaml`
- Sets `external_url` to the configured proxy domain
- Restarts HA Core

**After first login:** change the `tappaas` user password in HA → Profile → Security.

**Alfen EV charger** (if deployed):
- Settings → Devices & Services → Add integration → `alfen_wallbox` (via HACS)
- Host: `alfen.<iot-zone>.internal`, port: `502`

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
| `https://<vmname>.<tappaas.domain>` from configured zones | HA login page (302) |
| `http://<ha-ip>:8123` direct | HA login page |
| `/etc/secrets/homeassistant.env` on Proxmox node | `HA_TOKEN` present |

## Troubleshooting

**firewall:rules fails during install**
Zone name contains an underscore (e.g. `srv_home`). See PR #278. Workaround:
deploy with `--zone0 work` or another zone without underscores.

**Proxy returns 400 Bad Request**
`trusted_proxies` not applied. Re-run `homeassistant:config` service:
```bash
bash services/config/install-service.sh homeassistant
```

**Sonos speakers not discovered**
Verify mDNS relay: `test-service.sh firewall:discovery homeassistant`.
If pinholes are missing, run `install-module.sh homeassistant --force`.
