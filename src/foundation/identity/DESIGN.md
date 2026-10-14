# identity — Design notes

Implementation detail for the identity module (created during the Diataxis restructure,
issue #247). Catalog info: [README.md](./README.md); install: [INSTALL.md](./INSTALL.md);
users & roles: [USERS.md](./USERS.md); test coverage: [TEST.md](./TEST.md). Design
rationale: [ADR-006](../../../docs/ADR/ADR-006-identity-users-and-roles.md).

## Why Authentik — SSO alternatives analysis

Migrated from the documentation site's solution-design "Single Sign-On" page so the
selection rationale lives with the module. Open-source SSO platforms surveyed when the
identity module was designed:

| Solution | Assessment |
|----------|------------|
| **Keycloak** | Most popular and widely adopted; OIDC, SAML, OAuth2, LDAP, social logins and enterprise features — but heavier and more complex to operate than TAPPaaS needs |
| **Authentik** | Modern interface with OIDC, SAML, LDAP and forward-auth proxy support; flexible and gaining popularity |
| **Authelia** | Lightweight authentication portal focused on MFA and access policies; too narrow to serve as the platform IdP |
| **Gluu** | Enterprise-ready with strong federation capabilities, but more complex setup |
| **Zitadel** | Cloud-native, developer-friendly, modern approach to SSO |
| **IdentityServer** | Popular in .NET environments for API and microservices |
| **Apereo CAS** | Mature platform, strongest in academic and enterprise sectors |

Authentik was chosen for its:

- Modern, user-friendly interface (admin UI matters for a single-operator platform)
- Comprehensive protocol support — OIDC, SAML, LDAP, plus the embedded-outpost
  forward-auth proxy (the two hooks TAPPaaS actually uses: `identity:identity` OIDC and
  `identity:accessControl` forward-auth, see below)
- Flexibility and ease of configuration via a complete REST API (drives all the
  automated wiring in this module)
- Active development and a growing community
- Light resource footprint suitable for self-hosted environments (the VM runs on
  2 cores / 4 GB)

Scope boundary: Authentik covers applications that speak OIDC or can sit behind
forward-auth. Credentials for legacy and external services without SSO support belong
in the password manager — see the combined Authentik + VaultWarden strategy in the
[Security design](https://tappaas.org/what/security-design/) and the
[vaultwarden app](../../security/vaultwarden/README.md). The password manager itself is
deliberately not an Authentik client: the vault must neither open with Authentik nor stop
opening without it (vaultwarden DESIGN.md).

## Stack (identity.nix)

- Authentik server + worker as podman containers; the release's target version is the
  last of the release lines in `identity.nix` (`2026.8.3`); web UI + API on ports 9000
  (HTTP) / 9443 (HTTPS).
- PostgreSQL 16 runs natively on the VM (Redis only below Authentik 2025.10).
- VM firewall open: 22 (SSH), 9000, 9443.
- **Secrets are auto-generated on first boot** by the `generate-authentik-secrets`
  systemd service (guarded by `ConditionPathExists=!/etc/secrets/authentik.env`): the
  Authentik secret key, the `akadmin` bootstrap password and the
  `AUTHENTIK_BOOTSTRAP_TOKEN` all land in `/etc/secrets/authentik.env` (mode 600).
  Nothing is prompted for and nothing is stored in the repo.

## The login page

The login page shows the site, not Authentik: `identity/update.sh` runs
`authentik-manager brand-ensure` with `site.json` `displayName` (else `name`). The default
brand gets a logo with the site's name and "powered by TAPPaaS" — a light and a dark variant,
picked by Authentik's `%(theme)s` file name — the name as page title and a site-initial
favicon; the login flow's heading becomes "Sign in". Authentik's own footer ("Powered by
authentik") stays.

`site.json` `branding.logo` (and `branding.logoDark`) replace the generated logo with the
site's own file — see README *The sign-in page*. Every logo is uploaded under a name that
carries a hash of its content, so a changed file is uploaded once and an unchanged one never
again; old files stay in Authentik's media until removed by hand.

Uploads need Authentik's file storage, which it enables only when `/data` is a mount point,
so the container mounts `/var/lib/authentik/data` at `/data` (media in `data/media`).

## Backup

The platform's: `backup:vm` puts the whole VM in the site's Proxmox Backup job, with the
site's schedule and retention (ADR-012). The snapshot is taken with the guest agent freezing
the filesystem, so the database, `/etc/secrets` and Authentik's media are captured together,
and PostgreSQL recovers from it as after a power cut. Restore is a VM restore:
[RESTORE.md](../backup/RESTORE.md).

The module keeps no backups of its own. Until 2026-10 it ran a nightly `pg_dump`, a Redis
snapshot and a tar of `/etc/secrets` and `/var/lib/authentik` into `/var/backup` — a pattern
copied from other modules, not something Authentik requires. Nothing read them, the tar had
been empty from the start, and the copies sat on the disk the VM backup already takes. A
tmpfiles `R` rule removes the directories from VMs that still have them.

## Upgrading Authentik: one release line per update (#748, #797)

Authentik refuses to skip a release line, moves to each line's latest patch before the
next, and cannot go back. `ak-step.nix` therefore builds **one step per update** along
the release lines in `identity.nix`: an older patch goes to its line's latest, a line's
latest to the next line. A guest on 2025.2.x reaches 2026.8.3 in **eight updates** — eight
nights on a site with a daily update schedule, or eight runs of
`module-manager update identity` to do it now.

What the guest runs comes from **build facts** collected on the guest before every build
(`build-facts.sh`, written to `/etc/nixos/tappaas-build-facts.env`): the version
`authentik-version-record` wrote after the last successful start — without it, the version
of the guest's server container — `none` for a fresh install, `unknown` for a database with
neither. The container's version is also a floor: no step goes below what the guest runs,
because Authentik cannot go back. (The env file every guest has is no evidence of a version:
reading it as "2025.2.1" once stepped a 2026.8.3 guest down to 2025.2.3, hrossen 2026-10-08.) The build runs on the mothership
(#774), where the guest's files do not exist; reading them there made every guest look
fresh and jump straight to the target (#797). Missing or `unknown` facts stop the build
before it switches — the old version keeps serving and the update says why. The guest's
pre-check (`authentik-step-precheck`) can block a step the same way (2025.12 refuses
duplicate group names).

A step Authentik refuses anyway ends `authentik-version-record`'s wait at once — on its
"version skips are not allowed", or three server restarts — so the update fails and rolls
back in about a minute instead of waiting 45.

## Credential bootstrap (issue #312)

`lib/ensure-authentik-creds.sh` is the single source of truth for materialising
`~/.authentik-credentials.txt` (url= / token=, mode 600) on tappaas-cicd:

- Fast path: file present and `authentik-manager test` passes → no-op.
- Otherwise: waits for the Authentik API (up to 5 min), fetches the bootstrap token from
  the identity VM over SSH, writes the file, then polls (up to 3 min) until Authentik
  accepts the token (the worker binds it to `akadmin` asynchronously on first boot).

Both `identity/update.sh` and `services/accessControl/install-service.sh` source it, so
a consumer install self-heals when the cicd-side credential is missing or stale (e.g.
after a cicd rebuild).

## One-time global wiring (issue #45, Phase B — done by update.sh)

`install.sh` simply sources `update.sh` (idempotent, reconcile-in-place):

1. Bootstrap + verify the cicd-side Authentik credentials (above).
2. Caddy global AuthProvider = Authentik: `AuthToDomain=identity.mgmt.internal`,
   `AuthToPort=9000`, `AuthToUri=/outpost.goauthentik.io/auth/caddy` (via the OPNsense
   Caddy API; `AuthToTls` is left at its default `http://` — the API rejects setting it).
3. Ensure the 12 `X-Authentik-*` copy-headers (Username, Groups, Entitlements, Email,
   Name, Uid, Jwt, Meta-Jwks, Meta-Outpost, Meta-Provider, Meta-App, Meta-Version) and
   attach their UUIDs to `general.CopyHeaders`; reconfigure + reload Caddy.
4. Set the embedded outpost's `authentik_host` to the public `https://identity.<domain>`.
5. Register the identity self-application + Proxy Provider and attach it to the embedded
   outpost (so `https://identity.<domain>/outpost.*` works).

## The two consumer service hooks (ADR-006 §4 — never both on one app)

- **`identity:accessControl`** (forward-auth, header-based apps): creates/updates an
  Authentik Proxy Provider + Application for the consumer, attaches it to the embedded
  outpost, binds the `users` group to it (mandatory — without a binding every Authentik
  user passes the gate, #805), and flips the consumer's existing Caddy handler to
  `ForwardAuth=1`. Requires
  the consumer's `network:proxy` service to have run first.
- **`identity:identity`** (native OIDC apps): ensures the optional `<module>-admins`
  group (when `identity.providesAdminRole`), creates/updates an OAuth2/OpenID Provider +
  Application, binds the allowed groups to the app (mandatory — an unbound Authentik app
  is allow-all), writes `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` / `OIDC_DISCOVERY_URI`
  into the consumer VM's secrets env, and optionally restarts its configure service.

  Module JSON contract (object `identity`, all optional — defaults suit Nextcloud):
  `providesAdminRole` (bool), `oidcRedirectPaths` ([str], default
  `["/apps/user_oidc/code"]`), `scopes` ([str], default openid/email/profile),
  `secretsEnv` (str, default `/etc/secrets/<base>.env`), `configureService` (str).

For both hooks, `update-service.sh` re-execs `install-service.sh` (fully idempotent) and
`delete-service.sh` removes the Authentik app/provider, leaving role groups intact.

## Role/user lifecycle ownership (ADR-007)

The role groups (`user`/`admin`/`root`) and the team group `users` are owned and
reconciled by `identity-manager sync` (run at foundation install and on update from
`config/identities/`). The identity module's scripts no longer ensure them, and the legacy
`roles-ensure.sh` / `user.sh` test tiers were removed (see [TEST.md](./TEST.md)).

### Who can administer Authentik (#476)

Authentik grants its admin UI on exactly one condition: membership in a group flagged
`is_superuser`. TAPPaaS roles do not qualify — `identity-manager` creates every role and
group with `is_superuser: false`, because a role is a label forwarded to apps (OIDC
`groups` claim / `X-Authentik-*` headers), not an identity-provider permission.

So TAPPaaS **adopts Authentik's own built-in `authentik Admins` group by name** instead
of inventing a second superuser group, and makes the **site owner** a member — the owner
user of the organization that owns the default environment (`site.json` `.owner` →
`organizations/<org>.json` `.owner`). `root` is not a member: it is a label-only
break-glass identity.

Ownership is split so neither half can silently fail:

- `update.sh` runs `authentik-manager group-ensure "authentik Admins" --superuser`. This
  adopts the existing built-in group, and re-creates it **with** `is_superuser` if it was
  deleted — without it, `identity-manager`'s `ensure-group` would recreate a plain group of
  the same name and the grant would become a silent no-op.
- `config/identities/` carries the group + the owner's `memberOf` entry, so every later
  `identity-manager reconcile` preserves the membership. Fresh installs get both from the
  `minimal-org` bootstrap; existing installs get them from `update.sh`, which also applies
  the membership directly (a targeted `add-member`, not a full `reconcile --apply` — a
  module update must not push whatever else an operator has staged in `config/identities/`).

Because the group name is Authentik's, it contains a space; `Group.name` and
`User.memberOf` therefore permit internal spaces, and `identity-manager`'s list flags split
on commas only.
