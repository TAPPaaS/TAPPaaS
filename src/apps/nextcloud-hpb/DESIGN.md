# nextcloud-hpb — Design notes

Primary audience: **module developers** (Diataxis: *explanation*).

## Why this exists

Without a High-Performance Backend, Nextcloud Talk signals through the PHP web server and
sends media in a full mesh: every participant uploads one stream per other participant, which
limits how many people a video call can hold. This module runs a dedicated Go signaling server
plus a Janus SFU, so each participant uploads only **one** stream, which Janus fans out to the
room.

## Architecture

```
Browser/Phone ─wss://<proxyDomain>/spreed─▶ Caddy (dmz) ─▶ nextcloud-hpb :8080 ── ws://127.0.0.1:8188 ──▶ Janus (same VM)
      │                                                       │  ▲                                          │ RTP UDP 20000-20999
      │ media                                                 │  │ https://<nextcloudPublicUrl>            │
      ▼                                                       │  │  (backend validation, room events)      ▼
   coturn (dmz) ◀──── relay legs for everyone Janus cannot reach directly ◀──────────────────────── Janus (TURN REST creds)
                                                              ▼
                                           Nextcloud (same zone) registers HPB as Talk's signaling server (hpb connector)
```

- `services.nextcloud-spreed-signaling` (Go, from nixpkgs) + NATS loopback (in-process — no
  external NATS needed for a single node), with `mcu.type = janus`.
- Janus (`pkgs.janus-gateway`) as a custom systemd unit — nixpkgs has no service module —
  rendering its `.jcfg` files into `/run/janus` at start from runtime secrets, the coturn
  pattern. Only the `videoroom` plugin and the `websockets` transport are enabled; the
  WebSocket API binds to loopback; the admin API is off.
- No PHP — signaling runs entirely in the Go process, off the Nextcloud workers.
- Stateless beyond its secrets — regenerated on reinstall if absent; no application data to
  restore (see Backup & restore).

## Media path

- Janus runs only the `videoroom` plugin: it is a pure SFU, not a mixer. Every participant
  uploads one stream; Janus fans it out to the rest of the room.
- A client that can reach the HPB's zone directly sends its RTP straight to Janus, over UDP
  20000-20999 on the HPB VM.
- A client that cannot reach the HPB directly (a different zone, or the internet) is relayed
  by coturn instead. coturn denies relaying to private addresses by default; the `coturn:turn`
  service carves out an explicit allowed-peer entry for the HPB's own address so this leg is
  possible. The HPB's declared `ingress` (`from: dmz`, UDP 20000-20999) is exactly that path
  from coturn — no other zone needs (or gets) that opening.
- Janus uses full trickle ICE, not ice-lite: it sits behind the site's NAT and needs its own
  TURN relay candidates for participants it cannot reach directly. It gets short-lived TURN
  credentials from the signaling server's TURN REST endpoint at `/turn/credentials`, keyed
  with `turn-apikey` — Janus never holds a copy of coturn's shared secret.
- Janus's WebSocket API (the signaling server's MCU connection) binds to `127.0.0.1:8188`
  only; nothing outside the VM can reach it.
- No WAN port-forward for Janus in this version — a future version could NAT the RTP range
  to the HPB directly, taking load off coturn for external callers.

## Facts from providers

`nextcloud-hpb.nix` reads two values from its companion JSON (`/etc/nixos/nextcloud-hpb.json`,
the deployed config as `update-os.sh` ships it on every rebuild):

| Fact | Stamped by | Declared in | Used for |
|---|---|---|---|
| `turnHost` (`<publicDomain>:3478`) | `coturn:turn` install/update-service | `coturn/services/turn/fields.json` | `turn.servers`, Janus `nat.turn_server` |
| `nextcloudPublicUrl` (`https://<proxyDomain>`) | `nextcloud:fileservice` install/update-service | `nextcloud/services/fileservice/fields.json` | `backends.nextcloud.urls` |

Both providers run before `templates:nixos` in the `dependsOn` order, so the first rebuild
already has them, and every `update-module.sh nextcloud-hpb` re-derives them. Talk validates
against Nextcloud's **public** base URL, so an internal name is rejected with
`invalid_backend`; the `.nix` warns at evaluation time when either fact is missing.

## Dependencies rationale

All `dependsOn` entries are hard requirements; this module declares no `integratesWith`.

| Depends on | Why |
|---|---|
| `cluster:vm` | The VM itself |
| `templates:nixos` | Ships and rebuilds this module's NixOS configuration against the platform's pin |
| `backup:vm` | VM-level backup (see Backup & restore) |
| `network:proxy` | The `wss://` route Talk clients connect to |
| `network:rules` | Firewall pass rules, including the `dmz` ingress for coturn's relay leg |
| `nextcloud:fileservice` | The Nextcloud instance this backend serves; stamps its public URL, registers the `hpb` connector |
| `coturn:turn` | TURN relay for participants the HPB cannot reach directly; stamps `turnHost`, publishes the shared secret, and allow-lists the HPB's address on coturn |

## Configuration & install-time overrides

`zone0` is the field an installer most often needs to think about, and `pre-install.sh`
already fills it in automatically from Nextcloud's own zone — see Zone placement. Any other
field (`cluster:vm` sizing, storage, node) follows the platform's usual override path: copy
`nextcloud-hpb.json` to `/home/tappaas/config` and edit it before installing.

## Secrets

| Plane | Location | Written by |
|-------|----------|-----------|
| Runtime | `/var/lib/nextcloud-hpb/secrets/` on the HPB VM | NixOS `hpb-init-secrets` on first boot (`janus-admin` is added by `janus.service` if missing) |
| Management | `/home/tappaas/secrets/nextcloud-hpb.env` on tappaas-cicd | `install.sh` |
| coturn dependency | `/home/tappaas/secrets/coturn.env` on tappaas-cicd | `coturn/install.sh`, the `coturn:turn` service |

`install.sh` reads `HPB_SECRET` from the runtime plane, saves it to the management plane, and
hands over to Nextcloud's fileservice converge, which writes `HPB_URL` + `HPB_SECRET` into
`/etc/secrets/hpb.env` on the Nextcloud VM for `nextcloud-configure-hpb.service`. TURN is not
part of that file: the `talk` connector (owned by coturn's declaration) writes
`/etc/secrets/talk.env` for its own unit, so a coturn-only site has a relay too.

## Sizing

Default: 4 vCPU, 4 GB RAM, 16 GB disk. What scales with load is the Janus SFU, not the
signaling server: one uplink per participant, fanned out to everyone else in the room. The
UDP 20000-20999 RTP range gives roughly 500 concurrent media legs; widen the range (and the
matching firewall rule) for bigger meetings. In practice the ceiling for external
participants is their WAN uplink, not CPU — a 30-way call already drives roughly 30 × 29
downstream streams out of Janus.

## Backup & restore

No application data. The module is stateless beyond its own secrets, which regenerate on
reinstall if absent. VM-level backup via `backup:vm` is enough; there is no restore procedure
beyond restoring the VM itself.

## Zone placement

The pre-install hook places the HPB in the zone of the Nextcloud it serves, unless the
operator names one explicitly. Reaching the reverse proxy needs no egress either way —
every zone is granted the DMZ gateway on 443 — so co-location is about predictable placement
rather than reachability. `install.sh` fails fast, naming the zone and VLAN, when the VM does
not resolve.

## Split-horizon DNS

Registered by `network:proxy` for the HPB's `proxyDomain` (answer: the DMZ gateway — the
Caddy proxy, right for a `wss://` route).

## Connector ownership

The Talk HPB connector (shared `HPB_SECRET`, `wss://<domain>/spreed`) is owned by Nextcloud
(`config["nextcloud:fileservice"].connector = "hpb"`) and is applied whenever this module is
installed or updated. After reinstalling Nextcloud, run `update-module.sh nextcloud-hpb` to
wire it in again. `dependsOn coturn:turn` supplies the TURN secret and
`turnHost`. See [UPGRADE.md](./UPGRADE.md) for upgrade/pin handling.

## Deploy notes & known limitations (0.3.0)

- Janus plugin/transport paths are taken as `${janus-gateway}/lib/janus/{plugins,transports,
  events,loggers}`; a nixpkgs layout change would surface as `janus.service` failing to load
  the videoroom plugin.
- Public exposure is opt-in: the route keeps the default access list (internal zones only).
  For external callers, set `proxyAllowedZones: ["internet"]` in `config["network:proxy"]`
  of both `nextcloud` and `nextcloud-hpb`, then run `update-module.sh` on each.
- Talk's admin page may warn that this signaling server lacks the feature `changed-users`.
  It is optional; calls work. The warning goes away once a signaling-server release ships
  that feature.
- `services/vm/*` hooks exist in this module but are unused: `provides` is empty, so nothing
  depends on `nextcloud-hpb:vm`.

## Related documents

- [README.md](./README.md) — end-user overview (what you get)
- [INSTALL.md](./INSTALL.md) — admin install / operate
- [UPGRADE.md](./UPGRADE.md) — upgrade / pin handling
- coturn's [DESIGN.md](../coturn/DESIGN.md) — the TURN relay this module depends on
