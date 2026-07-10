# identity — Design notes

Implementation detail for the identity module (created during the Diataxis restructure,
issue #247). Catalog info: [README.md](./README.md); install: [INSTALL.md](./INSTALL.md);
users & roles: [USERS.md](./USERS.md); test coverage: [TEST.md](./TEST.md). Design
rationale: [ADR-006](../../../docs/ADR/ADR-006-identity-users-and-roles.md).

## Stack (identity.nix)

- Authentik server + worker as podman containers (version pinned in `identity.nix`,
  currently `2025.2.1`); web UI + API on ports 9000 (HTTP) / 9443 (HTTPS).
- PostgreSQL 16 and Redis run natively on the VM.
- VM firewall open: 22 (SSH), 9000, 9443.
- **Secrets are auto-generated on first boot** by the `generate-authentik-secrets`
  systemd service (guarded by `ConditionPathExists=!/etc/secrets/authentik.env`): the
  Authentik secret key, the `akadmin` bootstrap password and the
  `AUTHENTIK_BOOTSTRAP_TOKEN` all land in `/etc/secrets/authentik.env` (mode 600).
  Nothing is prompted for and nothing is stored in the repo.

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
  outpost, and flips the consumer's existing Caddy handler to `ForwardAuth=1`. Requires
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
reconciled by `people-manager sync` (run at foundation install and on update from
`config/people/`). The identity module's scripts no longer ensure them, and the legacy
`roles-ensure.sh` / `user.sh` test tiers were removed (see [TEST.md](./TEST.md)).
