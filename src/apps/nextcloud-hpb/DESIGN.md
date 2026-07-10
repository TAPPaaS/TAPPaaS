# nextcloud-hpb — Design notes

Implementation detail moved out of README/INSTALL (Diataxis: explanation).

## Architecture

```
Browser/Phone ─wss://<proxyDomain>/spreed─▶ Caddy (OPNsense) ─▶ nextcloud-hpb :8080 (srv)
                                                                │ TURN creds from coturn (dmz)
                                           Nextcloud (srv) ◀────┘ registers HPB as Talk
                                                                  signaling server
```

- `services.nextcloud-spreed-signaling` (Go, from nixpkgs) + NATS loopback (in-process — no
  external NATS needed for a single node).
- Listens on `0.0.0.0:8080`; Caddy on OPNsense proxies `wss://` to this port. Firewall: TCP 22
  (SSH) + 8080.
- No PHP — signaling runs entirely in the Go process, off the Nextcloud workers.
- Stateless beyond its secrets — re-generated on reinstall if absent; no application data to
  restore (VM-level backup via `backup:vm`).

## Secret planes

| Plane | Location | Written by |
|-------|----------|-----------|
| Runtime | `/var/lib/nextcloud-hpb/secrets/` on the HPB VM | NixOS `hpb-init-secrets` on first boot |
| Management | `/home/tappaas/secrets/nextcloud-hpb.env` on tappaas-cicd | `install.sh` at install time |
| coturn dep | `/home/tappaas/secrets/coturn.env` on tappaas-cicd | `coturn/install.sh` |

`install.sh` reads `HPB_SECRET` from the runtime plane, saves it to the management plane, and
writes `HPB_SECRET`, `HPB_URL`, `TURN_SECRET` and `TURN_SERVER` into `/etc/secrets/hpb.env` on
the Nextcloud VM. The `nextcloud-configure-hpb.service` (in nextcloud.nix) reads all four to
register `wss://<HPB_URL>/spreed` plus the TURN/STUN relay.

## Backend allow-list and TURN wiring

`nextcloud-hpb.nix` ships placeholder defaults for the Nextcloud backend URL and the TURN host.
The signaling pre-start regenerates `server.conf` from the nix on every (re)start, so live edits
to `server.conf` do not survive. `install.sh` therefore rewrites the deployed
`/etc/nixos/nextcloud-hpb.nix` (backend `urls` → Nextcloud's public URL, `turn:` host → coturn's
public or internal host) and applies it with
`nixos-rebuild switch -I nixos-config=/etc/nixos/nextcloud-hpb.nix` (no
`/etc/nixos/configuration.nix` exists — the module nix IS the config). Talk validates against
the Nextcloud PUBLIC base URL, so an internal placeholder is rejected with `invalid_backend`.

Nextcloud intentionally does not store `proxyDomain`; it is derived as `<vmname>.<domain>` and
mirrored by `install.sh` when composing the allow-list.

## Split-horizon DNS

`install.sh` adds an OPNsense DNS override mapping the HPB public domain to `10.2.10.1` (SRV
zone gateway) so internal hosts resolve it to the local Caddy proxy instead of hairpinning via
the WAN IP. Only the public DNS record remains a manual step.

## Connector ownership

The Talk HPB connector (shared `HPB_SECRET`, `wss://<domain>/spreed`) is owned by Nextcloud per
ADR-COM-0002 (`config["nextcloud:fileservice"].connector = "hpb"`). `dependsOn coturn:turn`
supplies the TURN secret. See [UPGRADE.md](./UPGRADE.md) for upgrade/pin handling.

## Deploy notes & known limitations (0.1.0)

- Validated via test variant (test.sh 14/0/0); the Talk HPB signaling connection check is
  confirmed green.
- An earlier status note ("Development — the NixOS signaling config is still being finalised")
  predates that validation; the module json currently reports status `Testing`.
- External multi-party calls require a publicly reachable coturn (WAN endpoint).
- Earlier docs described manually copying `hpb.env` to the Nextcloud VM; this is now automated
  by `install.sh`.
