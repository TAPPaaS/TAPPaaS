# Nextcloud — Design notes

Implementation and deployment detail moved out of README/INSTALL (Diataxis: explanation).

## Architecture

- NixOS native `services.nextcloud` (PHP-FPM + internal nginx), VM listens on port 80; Caddy on
  OPNsense terminates TLS.
- PostgreSQL (NixOS native, pinned `postgresql_15`) with a dedicated `nextcloud` database/user.
- Redis (NixOS named server `nextcloud`) for file locking + APCu cache, via unix socket
  `/run/redis-nextcloud/redis.sock`.
- Office editing is handled externally by the `euro-office` module (port 9980 is deliberately
  closed on this VM).
- Version pinning: the single `ncMajor` value at the top of `nextcloud.nix` drives both the
  Nextcloud package and its app-set. Majors must be bumped sequentially — see
  [UPGRADE.md](./UPGRADE.md).

## Provided service

| Provides | Consumed by |
|----------|-------------|
| `fileservice` | `coturn`, `nextcloud-hpb`, `euro-office` (each `dependsOn nextcloud:fileservice`) |

Nextcloud is the core of the collaboration hub. Consumer wiring is applied by
`services/fileservice/install-service.sh` when a consuming module installs (ADR-COM-0002); the
Talk HPB/TURN connector wiring (signaling backend allow-list, egress to the reverse proxy) is
config-derived at deploy time.

## Secrets

- Admin and DB passwords are auto-generated on first boot into `/var/lib/nextcloud/admin-pass`
  and `/var/lib/nextcloud/db-pass` (mode 0600). `install.sh` copies the admin password to
  `/home/tappaas/secrets/nextcloud.env` on tappaas-cicd.
- `pre-install.sh` pre-creates `/home/tappaas/secrets/nextcloud.env` (mode 0600) before the
  dependency service installers run.
- OIDC: `/etc/secrets/nextcloud.env` on the VM (`OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`,
  `OIDC_DISCOVERY_URI`) activates `nextcloud-configure-oidc` on next boot.
- euro-office connector: `services/nextcloud/install-service.sh` (in euro-office's flow) writes
  `/etc/secrets/onlyoffice.env`; the declarative `nextcloud-configure-eurooffice` service applies
  it. The `onlyoffice` app ships as a Nix `extraApp`.

## Trusted domains and public URL

`update.sh` sets `trusted_domains` (internal FQDN and public domain), `overwrite.cli.url` and
`overwriteprotocol=https` via `nextcloud-occ`. `install.sh` sources `update.sh` and calls the same
function once the VM is up. `localhost` is not written: loopback is always trusted.

**These occ values do not survive a NixOS rebuild by themselves.** Nix does not pin
`trusted_domains`, and a rebuild rewrites `/var/lib/nextcloud/config/config.php`, losing the
occ-set keys. That is why the converge lives in `update.sh` rather than `install.sh`:
`update-module.sh` runs the dependency updaters — including the `templates:nixos` rebuild —
*before* the module's `update.sh`, so the domain is restored after every rebuild on the sanctioned
update path.

To close the gap for rebuilds that happen *outside* that path (an OS auto-update, a manual
`nixos-rebuild`, a `--force` run whose post-step never got to run), `apply_domain_config()` also
writes the resolved internal FQDN and public domain to `/etc/secrets/nextcloud-domain.env` on the
VM. The declarative `nextcloud-configure-trusted-domains.service` (`nextcloud.nix`) reads that file
and re-applies the same `occ` calls after `nextcloud-setup.service` on *every* boot — the same
self-healing pattern used for the HPB signaling config (`nextcloud-configure-hpb`). A rebuild that
never went through `update.sh` still self-heals on its own next boot, once the env file has been
written at least once.

The write is verified by reading `config.php` back, and the converge fails if the value is absent.
`nextcloud-occ` exits 0 over a non-TTY SSH session while relaying no output at all, so its exit
code is not evidence that anything was written. `test.sh` asserts the module's `proxyDomain` is
present in `trusted_domains`, and `update-module.sh` runs that suite before and after every update.

`nextcloud-occ` must be called directly (it self-switches to the nextcloud user); wrapping it in
`systemd-run` nests systemd-run as a non-root user and polkit denies it.

## Backup design

Daily automated backups via `backup:vm`: PostgreSQL dump at 02:00, data-dir tar at 02:30,
30-day retention in `/var/backup/nextcloud/`.

## Install-time overrides

Besides copying the json to `/home/tappaas/config`, any field can be overridden on the command
line, e.g.:

    install-module.sh nextcloud --node tappaas1 --zone0 srv --vmid 340 --memory 8192

## Deploy notes & known limitations (0.1.0)

- Validated on the cluster via a named test variant (`--variant test`). A base/production deploy
  is the canonical path; named-variant deploys depend on the foundation provider-variant
  resolution (see the `deploy-engine: pass resolved provider variant` upstream issue).
- Measured install duration: ~9 min on a fresh VM (clean exit-0 deploy 2026-06-11, test variant
  on srv), dominated by the first-time NixOS rebuild building Nextcloud, the eurooffice connector
  and `uppush` from source (uncached). A stalled `uppush`/codeberg `/archive` fetch can inflate
  this substantially (build-time SPOF — see backlog).
- External multi-party Talk calls additionally require a publicly reachable coturn (WAN
  endpoint).
