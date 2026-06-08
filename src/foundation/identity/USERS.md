# TAPPaaS Identity — Users & Roles (operator guide)

How to give people logins and roles on a TAPPaaS install. Design rationale is in
[ADR-006](../../../docs/ADR/ADR-006-identity-users-and-roles.md); this is the
practical reference (issue #56).

One person = **one Authentik login**. What they can do is decided by their
**roles**, which are just Authentik **group memberships**. SSO is automatic across
all modules; access to each app is gated per-app (ADR-006).

## Roles

| Role | Group | Authority |
|------|-------|-----------|
| **Installer** | `tappaas-installers` | Full Authentik admin + platform root. **Global** (never per-variant). |
| **Admin** | `<scope>-admins` | App-level admin role (passed to apps). |
| **User** | `<scope>-users` | Ordinary access. |
| **Module Admin** | `<scope>-<module>-admins` | In-app admin for one module (opt-in). |

`<scope>` is `tappaas` for the default install, or the variant (client) name when
you run multi-tenant — e.g. `acme-admins`, `acme-nextcloud-admins`.

## Create the role groups

Done automatically when the identity module installs and whenever you add a variant.
To (re)reconcile by hand — idempotent:

```bash
roles-ensure.sh                 # installers + default scope + every variant
roles-ensure.sh --variant acme  # just the acme scope
```

## Add or update a user

```bash
# A basic user on the default install
add-user.sh lars --email lars@example.org

# With a role
add-user.sh lars --email lars@example.org --role admin

# A client's user / module admin (multi-tenant)
add-user.sh jane --email jane@acme.org --variant acme --role user
add-user.sh jane --email jane@acme.org --variant acme --role module-admin:nextcloud

# A platform installer
add-user.sh root --email root@example.org --role installer
```

`add-user.sh` is **idempotent and additive** — re-running adds roles, never removes
them. Pass `--role` multiple times to grant several at once, `--no-credential` to
only change roles without (re)issuing a credential.

### Credential delivery

`add-user.sh` finishes by either:

- printing a **one-time enrollment link** (when a recovery flow + SMTP are set up —
  deferred to the SMTP issue; the link is then emailed automatically), or
- setting and **printing a temporary password** (the fallback today) — share it over
  a secure channel; the user changes it after first login.

## Removing a role / user

Role groups are managed in Authentik. To drop a role, remove the user from that
group in the Authentik admin UI (`https://identity.<domain>`). Deleting the user
there removes the login entirely. (A scriptable `remove-user` is a future addition.)

## Which modules use which login path

- **OIDC apps** (e.g. Nextcloud) — `dependsOn: identity:identity`. The app provisions
  a real account on first login; roles flow via the `groups` claim. Installing the
  module wires this automatically (ADR-006 Phase 4).
- **Forward-auth apps** (e.g. Open WebUI) — `dependsOn: identity:accessControl`.
  Authentik gates the URL and passes headers; no separate in-app account.

Never put both on the same app (double login). See ADR-006 §4.
