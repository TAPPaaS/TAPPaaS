# identity-controller

The **Authentik identity controller** for TAPPaaS. It drives the Authentik
identity server over its admin REST API to converge users, groups/roles,
application bindings, proxy/OIDC applications, and the embedded forward-auth
outpost onto a desired state. It talks to the Authentik API directly over
`httpx` and has no firewall/OPNsense dependency.

It ships two identical entry points (the same CLI under two names):

- `authentik-manager`
- `identity-controller`

## Credentials

The CLI reads `~/.authentik-credentials.txt` (key=value), overridable with
flags or environment variables:

```
url=https://identity.<domain>
token=<api-token>
```

Global flags (apply to every command):

| Flag | Meaning |
|------|---------|
| `--credential-file <path>` | Credentials file (default `~/.authentik-credentials.txt`). |
| `--url <url>` | Authentik base URL (or `AUTHENTIK_URL`). |
| `--token <token>` | API token (or `AUTHENTIK_TOKEN`). |
| `--no-tls-verify` | Skip TLS certificate verification. |

## Commands

All write commands are **idempotent** (create-if-missing, no-op if already in
the desired state).

### Connectivity

| Command | Purpose |
|---------|---------|
| `test` | Verify the token and connectivity. |

### Users

| Command | Purpose |
|---------|---------|
| `user-ensure <username> [--email <e>] [--name <display>] [--group <g> ...] [--attr k=v ...]` | Create/update a user; group membership is additive; `--group`/`--attr` repeatable. |
| `ensure-user --name <n> --email <e> --display <d> [--inactive]` | Create user if missing; reconciles only the active flag. |
| `get-user --name <n>` | Print one user object as JSON (or `null`). |
| `list-users` | JSON array of users (name/active/email/displayName/groups/roles). |
| `user-add-to-groups <username> --group <g> ...` | Add an existing user to groups (additive; `--group` required, repeatable). |
| `user-remove-from-groups <username> --group <g> ...` | Remove a user from groups. |
| `disable-user --name <n>` | Set `is_active=false`. |
| `user-delete <username>` / `delete-user --name <n>` | Delete a user. |
| `user-set-password <username> [--password <p>]` | Set a password (generates and prints one if `--password` omitted). |
| `user-recovery-link <username>` | Print a one-time recovery/enrollment link. |

### Groups & roles

In Authentik a *role* is a group marked as a role; the CLI offers both spellings.

| Command | Purpose |
|---------|---------|
| `group-ensure <name> [--parent <p>] [--superuser] [--attr k=v ...]` | Create/update a group; `--superuser` marks `is_superuser`. |
| `ensure-group --name <n> --display <d>` | Create a group if missing. |
| `ensure-role --name <n> --display <d>` | Create a role-marked group if missing. |
| `list-groups` | JSON array of `{name, displayName}` (excludes roles). |
| `list-roles` | JSON array of role-marked groups. |
| `add-member --user <u> --group <g>` | Add a user to a group. |
| `remove-member --user <u> --group <g>` | Remove a user from a group. |
| `assign-role --user <u> --role <r>` | Assign a role to a user directly. |
| `unassign-role --user <u> --role <r>` | Remove a role from a user. |

### Applications & outpost

| Command | Purpose |
|---------|---------|
| `proxy-app-ensure <slug> [--name <n>] --external-host <url> [--description <d>] [--attach-outpost]` | Create/update a proxy application (+ provider); optionally attach the embedded outpost. |
| `oidc-app-ensure <slug> [--name <n>] --redirect-uri <u> ... [--scope <s> ...] [--description <d>] [--show-secret]` | Create/update an OIDC application (+ provider); `--redirect-uri` required, repeatable; `--show-secret` prints the client secret. |
| `app-bind-groups <slug> --group <g> ...` | Bind groups to an application (restrict who may access it). |
| `app-delete <slug>` | Remove an application and its provider. |
| `outpost-attach <slug>` | Attach a proxy application to the embedded outpost. |
| `outpost-set-authentik-host <host>` | Set the outpost's `authentik_host` (full URL, e.g. `https://identity.example.org`). |

## Examples

```bash
# Sanity check the connection:
authentik-manager test

# Ensure a role and a user in it:
authentik-manager ensure-role --name editors --display "Editors"
authentik-manager user-ensure alice --email alice@example.org --group editors

# Publish an app behind forward-auth and gate it to the editors role:
authentik-manager proxy-app-ensure wiki --external-host https://wiki.example.org --attach-outpost
authentik-manager app-bind-groups wiki --group editors
```

## Who calls it

The TAPPaaS people/identity manager invokes `authentik-manager` to reconcile
Authentik against the declared people/role configuration.
