# Home Assistant — Design notes

## Appliance model

HAOS is a sealed appliance: it ignores cloud-init and does not run the normal TAPPaaS
NixOS SSH model (no `tappaas` user on port 22, no `/etc/secrets`, no NixOS systemd
units). VM creation (sata0, efidisk0, boot order, no cloud-init) is handled by the
shared engine via `bios: ovmf` and `cloudInit: false` in `hass.json` — the engine
(`Create-TAPPaaS-VM.sh`) is unchanged; all appliance special-casing stays inside this
module.

The module's install steps live in `lib/` (module-local helpers — NOT TAPPaaS services:
hass has `provides: []` and nothing depends on them; they are called directly from
`install.sh`):

- `lib/appliance-ssh.sh` — appliance shell access. Builds a small FAT disk labelled
  `CONFIG` holding `authorized_keys` = the canonical `tappaas-cicd.pub`, attaches it
  over `ssh root@<node> qm` after VM creation, enables the QEMU guest agent with
  `freeze-fs-on-backup`, then cold stop/starts the VM so HAOS reads the CONFIG label.
  Result: HAOS host SSH on port 22222 as `root` (key-only):

      ssh -p 22222 root@<hass-ip>

- `lib/config.sh` — TAPPaaS-native HAOS configuration: bootstraps a Long-Lived Access
  Token via the HA onboarding API (first-run only), completes the remaining onboarding
  steps (core_config, analytics, integration), writes the `http:` block
  (`trusted_proxies` derived from `zones.json` + the module zone gateway — no hardcoded
  IPs), sets `external_url` from the proxy domain, and restarts HA Core.
- `lib/ha-llat.sh`, `lib/ha-ws.sh` — LLAT and websocket helpers used by the above.

## Security — bootstrap admin account

`lib/config.sh` creates a `tappaas` user with owner + system-admin access during
first-run onboarding. This is required to bootstrap the LLAT used for automation. The
credentials and token are stored on the VM at `/mnt/data/tappaas/hass.env` — persistent
(`/mnt/data`) but outside the HA backup set (not under `supervisor/homeassistant`) so
the LLAT is not swept into HA backups (#344); same exposure as a native module's
`/etc/secrets` (PBS only).

Recommended after first login: change the `tappaas` user password in HA -> Profile.
The LLAT remains valid after a password change.

## Authentication / identity (no `identity:identity`)

This module deliberately does not declare `identity:identity` in `dependsOn`. The
standard OIDC wiring writes `/etc/secrets/<module>.env` over `ssh tappaas@<vm>:22` and
restarts a NixOS `*-configure-oidc.service` — none of which exist on a sealed HAOS
appliance. HA's own auth is bootstrapped by `lib/config.sh` via the LLAT +
`secrets.yaml`, so the OIDC-injection path is not applicable here. Centralised Authentik
SSO returns when hass becomes HA Core on NixOS (native module), which gets
`identity:identity` wiring for free. Until then, external access is gated at the
proxy/Authentik layer, not via this dependency.

## Reverse-proxy trust

Home Assistant rejects proxied requests with HTTP 400 unless the proxy's source IP is in
`http.trusted_proxies` (with `use_x_forwarded_for`). Caddy reaches HA from the
firewall's gateway IP on the VM's own zone (TAPPaaS gateways are always `.1` of the zone
network). HAOS keeps its config inside the VM, so `update.sh` injects the block via the
QEMU guest agent and restarts Core — idempotent and non-fatal (on a fresh install HA
Core may still be pulling its container; the next update applies it).

`internal_url` must be the direct `.internal:8123` LAN URL, NOT the proxy domain — else
internal access couples to the external proxy/firewall and breaks with it
("hassanova lesson", 2026-06-13 incident; enforced by test 6 in `test.sh`).

## Updates

HAOS manages its own runtime updates via the web UI — do not update via TAPPaaS
`update-module.sh`. The module version tracks the initial image used at deploy time
(`haos_ova-17.3` in `hass.json`); HAOS self-updates from there. The module's `update.sh`
only re-asserts the trusted-proxy configuration and reports access info.

## Backups

Full-system recovery is covered by scheduled PBS VM snapshots (`backup:vm`), with the
QEMU guest agent's freeze-fs-on-backup enabled by `lib/appliance-ssh.sh` for consistent
snapshots. Home Assistant's built-in backups (Settings -> System -> Backups) can
supplement this with granular, HA-native restore of configuration and add-ons; download
them off the VM if you want an extra off-site copy. Note that the TAPPaaS bootstrap
credentials/LLAT (`/mnt/data/tappaas/hass.env`) are deliberately outside the HA backup
set (#344) — they are covered by PBS only.

## Historical deployment note (PR #278)

Earlier deployments used a zone named `srv_home`; underscores in zone names broke
`network:rules`, so test deployments used `--zone0 work` until PR #278 (zones.json
hyphen/underscore) was resolved. The module json now targets `srvHome` (no underscore).
