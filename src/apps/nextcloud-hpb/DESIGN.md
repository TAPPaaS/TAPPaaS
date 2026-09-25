# nextcloud-hpb — Design notes

Implementation detail moved out of README/INSTALL (Diataxis: explanation).

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
- Janus (`pkgs.janus-gateway`, built with the TURN REST API) as a custom systemd unit — nixpkgs
  has no service module — rendering its `.jcfg` files into `/run/janus` at start from runtime
  secrets, the coturn pattern. Only the `videoroom` plugin and the `websockets` transport are
  enabled; the WebSocket API binds to loopback; the admin API is off.
- ICE: full trickle, **not** ice-lite. Janus sits behind the site's NAT and needs its own TURN
  relay candidates for participants it cannot reach directly; an ice-lite agent never uses
  TURN. Credentials come from the signaling server's TURN REST endpoint (`turn-apikey`), so
  Janus shares coturn's secret without holding a copy.
- Media reachability by design: clients in a zone that reaches the HPB's zone send RTP to
  Janus directly (UDP 20000-20999 open on the VM); every other participant relays through
  coturn. No WAN port-forward for Janus in this version — a v2 could NAT the RTP range to the
  HPB and set `nat_1_1_mapping` to take load off coturn.
- No PHP — signaling runs entirely in the Go process, off the Nextcloud workers.
- Stateless beyond its secrets — re-generated on reinstall if absent; no application data to
  restore (VM-level backup via `backup:vm`).

## Facts from providers, not `sed`

`nextcloud-hpb.nix` reads two values from its companion JSON (`/etc/nixos/nextcloud-hpb.json`,
the deployed config as `update-os.sh` ships it on every rebuild):

| Fact | Stamped by | Declared in | Used for |
|---|---|---|---|
| `turnHost` (`<publicDomain>:3478`) | `coturn:turn` install/update-service | `coturn/services/turn/fields.json` | `turn.servers`, Janus `nat.turn_server` |
| `nextcloudPublicUrl` (`https://<proxyDomain>`) | `nextcloud:fileservice` install/update-service | `nextcloud/services/fileservice/fields.json` | `backends.nextcloud.urls` |

Both providers run before `templates:nixos` in the `dependsOn` order, so the first rebuild
already has them, and every `update-module.sh nextcloud-hpb` re-derives them. Talk validates
against the Nextcloud **public** base URL, so an internal name is rejected with
`invalid_backend`; the `.nix` warns at evaluation time when either fact is missing.

Until 0.3.0 `install.sh` `sed`-edited the deployed `.nix` and ran `nixos-rebuild switch`
itself — outside `update-os.sh`, hence without the platform's nixpkgs pin. That is the class
of out-of-band rebuild that let another module's data ratchet past its pin; it is gone.

## Zone placement

The pre-install hook places the HPB in the zone of the Nextcloud it serves, unless the
operator names one. Reaching the reverse proxy needs no egress either way — ADR-021's
caddy-reach rule grants every zone the DMZ gateway on 443 — so co-location is about
predictable placement rather than reachability. `install.sh` fails fast, naming the zone
and VLAN, when the VM does not resolve.

## Secret planes

| Plane | Location | Written by |
|-------|----------|-----------|
| Runtime | `/var/lib/nextcloud-hpb/secrets/` on the HPB VM | NixOS `hpb-init-secrets` on first boot (`janus-admin` is added by `janus.service` if missing) |
| Management | `/home/tappaas/secrets/nextcloud-hpb.env` on tappaas-cicd | `install.sh` |
| coturn dep | `/home/tappaas/secrets/coturn.env` on tappaas-cicd | `coturn/install.sh`, `coturn:turn` |

`install.sh` reads `HPB_SECRET` from the runtime plane, saves it to the management plane, and
hands over to Nextcloud's fileservice converge, which writes `HPB_URL` + `HPB_SECRET` into
`/etc/secrets/hpb.env` on the Nextcloud VM for `nextcloud-configure-hpb.service`. TURN is
no longer part of that file: the `talk` connector (owned by coturn's declaration) writes
`/etc/secrets/talk.env` for its own unit, so a coturn-only site has a relay too.

## Split-horizon DNS

Registered by `network:proxy` for the HPB's `proxyDomain` (answer: the DMZ gateway — the
Caddy proxy, right for a wss:// route). The earlier `install.sh` override to a hard-coded
gateway is gone (#577: one writer per record).

## Connector ownership

The Talk HPB connector (shared `HPB_SECRET`, `wss://<domain>/spreed`) is owned by Nextcloud per
ADR-COM-0002 (`config["nextcloud:fileservice"].connector = "hpb"`), and converges on every
update of either module. `dependsOn coturn:turn` supplies the TURN secret and `turnHost`. See
[UPGRADE.md](./UPGRADE.md) for upgrade/pin handling.

## Deploy notes & known limitations (0.3.0)

- Janus plugin/transport paths are taken as `${janus-gateway}/lib/janus/{plugins,transports,
  events,loggers}`; a nixpkgs layout change would surface as `janus.service` failing to load
  the videoroom plugin (Test 9/10).
- Public exposure is opt-in: the route keeps the default access list (internal zones only).
  For external callers, set `proxyAllowedZones: ["internet"]` in `config["network:proxy"]`
  of both `nextcloud` and `nextcloud-hpb`, then run `update-module.sh` on each.
- Sizing note: a 30-participant video call drives roughly 30 × 29 × per-stream bitrate out of
  Janus; for external attendees the WAN uplink is the ceiling before CPU is.
