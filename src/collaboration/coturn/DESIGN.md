# coturn — Design notes

Implementation and deployment detail moved out of README/INSTALL (Diataxis: explanation).

## Why this exists

Nextcloud Talk needs a TURN/STUN relay so calls still connect when two participants can't
reach each other directly — behind different NATs, on a mobile carrier network, or when one
side is outside the site. coturn is a separate module rather than folded into Nextcloud or
the HPB because it is a network-facing relay that must sit in the `dmz` zone with its own
WAN exposure, while Nextcloud and the HPB do not.

## Architecture

```
Client A (NAT) ─[UDP 3478]─▶ coturn (dmz) ─[UDP 3478]─▶ Client B (NAT) / Janus (HPB, allow-listed)
                                  ▲
                  Nextcloud (srv) │ issues per-call credentials (shared HMAC secret)
                  HPB / Janus     │ TURN REST API → same secret
```

- Custom systemd `coturn` service (not the NixOS `services.coturn` module): secrets are
  loaded at runtime from `/etc/secrets/coturn.env` and the config is written to
  `/run/coturn/turnserver.conf` at each service start, so secrets never appear in the
  Nix store.
- No reverse proxy, no database, no Redis. Exposed ports: TCP 22 (SSH), TCP/UDP 3478
  (TURN/STUN), UDP 49152-50151 (relay range, 1,000 ports — one per allocation). The VM
  sits in the `dmz` zone.
- Widen the relay range in `coturn.json` and `coturn.nix` together — `coturn.json`'s
  `ports`, its `network:nat` `natRules`, and `coturn.nix`'s `min-port`/`max-port` and
  `allowedUDPPortRanges` must all agree.
- coturn tracks `pkgs.coturn` (nixpkgs) via the `versions` block in `coturn.nix`;
  `appVersion` in `coturn.json` mirrors the pinned package version.

## Security

- Auth: `use-auth-secret`, with `static-auth-secret` set to `COTURN_SECRET` — a 64-char hex
  string generated once by the `coturn-init-secrets` oneshot unit.
- Hardening flags in the rendered config: `no-cli`, `no-multicast-peers`,
  `no-software-attribute`, `fingerprint`.
- systemd sandboxing on the `coturn` unit: `NoNewPrivileges`, `PrivateTmp`,
  `ProtectSystem = "strict"`, with write access limited to `/run/coturn`, `/var/lib/coturn`
  and `/var/log/coturn`.
- `denied-peer-ip` blocks relaying into RFC1918 and other special-use ranges by default
  (loopback, link-local, multicast/reserved, etc.), so the relay cannot be used to reach an
  arbitrary private address. `100.64.0.0/10` (RFC 6598 shared address space) is deliberately
  **not** blocked: mobile carriers use it for 5G CGNAT, and blocking it would break the
  relay for 5G clients.
- The one exception to the private-range deny is a consumer that itself needs to reach the
  relay from a private address — today the HPB's Janus. Its IP is added as an explicit
  `allowed-peer-ip`; see "Allow-listing a media server" below. Nothing else on a private
  range is reachable through the relay.

## Provided services (`provides`)

| Service (`provider:service`) | What a dependent gets | Hook(s) |
|------------------------------|-----------------------|---------|
| `coturn:turn` | `turnHost`/`turnHostInternal` stamped into the consumer's deployed config (`config["coturn:turn"]`); the consumer's IP added to coturn's allow-list if it runs a media server on a private address; the shared secret separately, via the management plane | `services/turn/{install,update}-service.sh` (run from the *consumer's* own install/update) |

Two endpoints, not one: `turnHost` is coturn's public name (`publicDomain:3478`, falling
back to the internal FQDN if `publicDomain` is unset); `turnHostInternal` is
`<vmname>.<zone0>.internal:3478`. A site's wildcard split-horizon answers every public name
with the reverse proxy, which runs no TURN, so one name cannot serve both sides. Consumers
get both endpoints and let ICE pick: the public one works from outside, the internal one
from any zone with a pinhole into `dmz`.

### Allow-listing a media server

`coturn_allow_peer` (called for each consumer from both `services/turn/install-service.sh`
and `update-service.sh`) resolves the consumer's internal hostname to an IP — retrying up to
6 times, 5s apart, since a just-created consumer's DNS pin can lag behind `cluster:vm` — then
appends or updates a `"<module> <ip>"` line in `/var/lib/coturn/allowed-peers` on the coturn
VM over SSH. At each service start coturn renders one `allowed-peer-ip=<ip>` line per entry,
which overrides the private-range deny for exactly those hosts. `coturn.service` is
restarted **only if the file's content changed** — most converges are a no-op here. If the
consumer's hostname can't be resolved, this only warns ("calls still work for clients that
reach the media server directly") rather than failing the converge.

## Connector ownership

- **`talk` connector** — declared here (`config["nextcloud:fileservice"].connector =
  "talk"`) but applied by Nextcloud: `services/fileservice/update-service.sh` reads
  `COTURN_SECRET` from the management plane and `publicDomain` from coturn's deployed
  config, writes `/etc/secrets/talk.env` on the Nextcloud VM and restarts
  `nextcloud-configure-talk-turn.service`, which runs `occ talk:stun:add` / `talk:turn:add`.
  Re-applied whenever coturn is installed or updated.
- **`coturn:turn` service** (provided by coturn) — for each consumer: publishes the secret
  to the management plane, stamps `turnHost`/`turnHostInternal` into the consumer's deployed
  config, and adds the consumer's IP to the allow-list as above.

coturn does only its own layer; there is no cross-VM SSH push from this module beyond what
these two mechanisms cover.

## Dependencies rationale

- `nextcloud:fileservice` — coturn has nothing to relay without a Nextcloud Talk instance;
  it is also the hard prerequisite the installer checks for.
- `network:nat` — `coturn.json`'s `natRules` (3478 TCP/UDP, and the 49152-50151 UDP relay
  range with `internalPort: 49152`, the range's start) are turned into WAN port-forwards by
  this service automatically. coturn is the only `natRules` consumer with a port range.
- `network:rules` — firewall pass rules for the `dmz` zone, plus the declared `home`
  client-zone pinhole so internal callers don't hairpin via the WAN IP.
- `cluster:vm`, `templates:nixos`, `backup:vm` — standard VM provisioning, base image and
  backup registration, as for any `kind: vm` module.

## Configuration & install-time overrides

- `publicDomain` defaults to `turn.<site domain>` and is persisted into the deployed config
  on first converge (`public-name.sh`'s `coturn_converge_public_name`, run by both
  `install.sh` and `update.sh`), so every reader agrees on the same name. It also registers
  a split-horizon host override, `publicDomain → coturn VM`, on the site resolver —
  deliberately not reusing `network:proxy`'s gateway derivation, because TURN is not HTTP:
  media must reach the relay itself, not a reverse proxy.
- `COTURN_EXTERNAL_IP` is auto-detected at install time from the coturn VM (external echo
  services) and written into `/etc/secrets/coturn.env`; editing it by hand is a fallback for
  when DMZ egress is blocked, not the normal path.
- `home` must be listed in `zones.json`'s `dmz.pinhole-allowed-from` for the declared
  client-zone `ingress` to compile. A site with further client zones adds them there and to
  coturn's `ingress`.
- Sizing, target node/storage, and `publicDomain` are overridden by copying `coturn.json` to
  `/home/tappaas/config` and editing it before installing — not by install-time flags.

## Secrets

- Runtime plane: `/etc/secrets/coturn.env` on the coturn VM — `COTURN_SECRET` (64-char hex)
  is auto-generated on first boot by `coturn-init-secrets`; `COTURN_EXTERNAL_IP` starts
  empty and is filled in as above.
- Management plane: `/home/tappaas/secrets/coturn.env` on tappaas-cicd — `install.sh` (and
  the `coturn:turn` service, for each consumer) read the secret from the VM over SSH and
  upsert it here. `pre-install.sh` creates the file (mode 600) before dependency installers
  run. Consumers with no SSH path to the coturn VM (Nextcloud Talk, `nextcloud-hpb`) read
  the secret from here, not from the VM.

## Sizing

2 vCPU / 2048 MB memory / 8G disk. With the HPB's Janus SFU, every participant Janus cannot
reach directly is relayed through coturn, so the relay carries more concurrent legs than in
a mesh-only deployment; the 1,000-port relay range is the practical ceiling on simultaneous
allocations.

## Backup & restore

`backup:vm` puts the whole VM in the site's Proxmox Backup job; the module keeps no backup of
its own. The only state a call depends on is `/etc/secrets/coturn.env` (`COTURN_SECRET`,
`COTURN_EXTERNAL_IP`), which `coturn:turn` also publishes to the management plane
(`/home/tappaas/secrets/coturn.env`). A VM restore brings it back; a VM rebuilt from scratch
generates a new secret, and the consumers align to it on their next converge.

## Deploy notes & known limitations (0.3.0)

- No `turns:` (TLS) listener: the site's single WAN IP already serves 443 through Caddy, so
  the usual "TURN on 443" fallback for locked-down guest networks isn't available; a 5349
  listener would need its own certificate distributed to the VM and is a follow-up.
- Verify with a real off-network call, not the Talk admin checkmark (see INSTALL.md).

## Related documents

- [README.md](./README.md) — end-user overview (what you get)
- [INSTALL.md](./INSTALL.md) — admin install / operate
- [UPGRADE.md](./UPGRADE.md) — upgrade procedure and pin-bumping
