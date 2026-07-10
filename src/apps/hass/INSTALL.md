# Home Assistant — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. Active network zone — the target zone (default `srvHome`) must be active in
   `zones.json` and configured in OPNsense. See `hass.json` for the configured `zone0`.
2. HAOS image — downloaded automatically by `install-module.sh` from the URL in
   `hass.json` (`config.cluster:vm.imageLocation`). No manual download needed.

> To deviate from the defaults in `./hass.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing.

## Install

    install-module.sh hass

This creates the VM, imports the HAOS disk image, and configures automatically:

- Appliance SSH: a `CONFIG` key disk enabling HAOS host SSH (`root@<vm>:22222`) plus the
  QEMU guest agent with freeze-fs-on-backup (`lib/appliance-ssh.sh`).
- Firewall proxy (HTTPS reverse proxy for the configured domain) and the pinholes to the
  IoT modules (alfen, sonos, reolink).
- HAOS onboarding, `trusted_proxies`, `external_url` and the Long-Lived Access Token
  (LLAT) bootstrap (`lib/config.sh`).

## Post-install

Onboarding is automated. `lib/config.sh`:

- Creates admin user `tappaas` (owner + system-admin) with a generated password
- Stores credentials and the LLAT in `/mnt/data/tappaas/hass.env` on the VM
  (persistent, outside the HA backup set)
- Writes `trusted_proxies` + `use_x_forwarded_for` to `configuration.yaml`
- Sets `external_url` to the configured proxy domain
- Restarts HA Core

Remaining manual steps:

1. After first login: change the `tappaas` user password in HA -> Profile -> Security
   (the LLAT remains valid after a password change).
2. Alfen EV charger (if deployed): Settings -> Devices & Services -> Add integration ->
   `alfen_wallbox` (via HACS); host `alfen.<iot-zone>.internal`, port `502`.
3. Zigbee/Z-Wave hardware (optional): add USB pass-through in Proxmox
   (VM -> Hardware -> Add -> USB Device), then in HA: Settings -> Integrations -> add
   the relevant integration.

## Verification

    test-module.sh hass

| Check | Expected |
|-------|----------|
| VM status (`qm status`) | `running` |
| `http://<ha-ip>:8123` | HA login page (HTTP 200/302), no `/onboarding.html` redirect |
| `https://hass.<tappaas.domain>` from allowed zones | HA login page |
| HA API with the bootstrapped LLAT | HTTP 200 (`/api/`) |
| `/mnt/data/tappaas/hass.env` on the VM | `HA_TOKEN` present |
| Appliance host SSH `root@<ha-ip>:22222` | Key-only login works (CONFIG disk applied) |
| `internal_url` / `external_url` | Internal = `.internal:8123` direct; external = proxy domain |

## Troubleshooting

**`network:rules` fails during install**
Zone name contains an underscore (e.g. `srv_home`) — see PR #278. Workaround: deploy to
a zone without underscores in the name (the default `srvHome` is fine).

**Proxy returns 400 Bad Request**
`trusted_proxies` not applied (HA Core may not have been ready during install). Re-run
the config step:

    bash lib/config.sh hass

**Sonos speakers not discovered**
Verify the mDNS relay: `test-service.sh network:discovery hass`.
If pinholes are missing, run `install-module.sh hass --force`.

**Internal access breaks when the proxy/firewall is down**
`internal_url` must be the direct `.internal:8123` LAN URL, never the proxy domain —
otherwise internal access couples to the external proxy (2026-06-13 incident).
`test-module.sh hass` checks this.
