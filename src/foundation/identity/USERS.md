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

## Manage users — `user.sh`

One command with verbs **add / modify / delete / show / list**.

```bash
# add — create a login and grant roles
user.sh add lars  --email lars@example.org                       # basic user (default)
user.sh add lars  --email lars@example.org --role admin
user.sh add jane  --email jane@acme.org --variant acme --role user
user.sh add jane  --email jane@acme.org --variant acme --role module-admin:nextcloud
user.sh add root  --email root@example.org --role installer
user.sh add lars  --email lars@example.org --role admin --no-credential  # skip credential

# modify — grant/revoke roles or update profile (additive + subtractive)
user.sh modify lars --add-role admin
user.sh modify jane --variant acme --remove-role user --add-role admin
user.sh modify lars --email lars@new.org --name "Lars R" --credential  # re-issue credential

# show / list
user.sh show lars
user.sh list                 # users in the default scope
user.sh list --variant acme  # users in a client's scope

# delete — remove the login entirely (prompts unless --yes)
user.sh delete lars
```

`add` is **idempotent and additive** (re-running adds roles, never removes). Roles
are scoped: pass `--variant <client>` so `admin`/`user`/`module-admin:<m>` resolve to
that client's groups (`installer` is always global).

### Credential delivery

`add` (and `modify --credential`) finishes by either:

- printing a **one-time enrollment link** (when a recovery flow + SMTP are set up —
  deferred to the SMTP issue; the link is then emailed automatically), or
- setting and **printing a temporary password** (the fallback today) — share it over
  a secure channel; the user changes it after first login.

## Removing a role or user

- Drop a role: `user.sh modify <user> [--variant v] --remove-role <role>`.
- Delete the login entirely: `user.sh delete <user>` (login + MFA gone; re-addable).

You can also manage everything in the Authentik admin UI at `https://identity.<domain>`.

## Which modules use which login path

- **OIDC apps** (e.g. Nextcloud) — `dependsOn: identity:identity`. The app provisions
  a real account on first login; roles flow via the `groups` claim. Installing the
  module wires this automatically (ADR-006 Phase 4).
- **Forward-auth apps** (e.g. Open WebUI) — `dependsOn: identity:accessControl`.
  Authentik gates the URL and passes headers; no separate in-app account.

Never put both on the same app (double login). See ADR-006 §4.
