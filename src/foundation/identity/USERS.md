# TAPPaaS Identity — Users, Groups & Roles (operator guide)

Primary audience: TAPPaaS admin.

How people get a login on a TAPPaaS install, what that login can reach, and how to
reset a password. Reference (Diataxis) — the design rationale lives in
[ADR-007a — People](../../../docs/ADR/ADR-007a%20-%20People.md) (the people model) and
[ADR-006](../../../docs/ADR/ADR-006-identity-users-and-roles.md) (the SSO plumbing:
forward-auth vs OIDC, the access gate). Issues #56, #320, #477.

One person = **one Authentik login**. People are *declared as config* under
`config/people/` and reconciled into Authentik by **`people-manager`**; the identity
controller CLI **`authentik-manager`** is the runtime path (passwords, ad-hoc
inspection). SSO is automatic across modules; access to each app is gated per-app.

> Two tools, two jobs:
> **`people-manager`** owns *who exists and what they belong to* (config → Authentik).
> **`authentik-manager`** drives *the live Authentik service* (credentials, apps, raw
> reads). Never hand-edit the JSON under `config/people/` — drive it through the verbs.

## The model

`Organization → Group → User`, plus a cross-cutting `Role`:

| Entity | What it is | In Authentik |
|--------|------------|--------------|
| **Organization** | The legal/identity entity that owns environments and apps (`family` · `company` · `foundation` · `customer`) | naming scope for its groups |
| **Group** | A collection of users within one org — the RBAC primitive; carries roles every member inherits (`team` · `department` · `family-members` · `access-set` · `ad-hoc`) | a group (1:1) |
| **User** | A person. Belongs to ≥1 group, holds direct + inherited roles, has a lifecycle state | a user (1:1) |
| **Role** | A cross-cutting permission label (`root` / `admin` / `user`, or your own) | a group marked `attributes.tappaas.kind="role"` |

A user's **effective roles** = their own `roles` ∪ the `roles` of every group in their
`memberOf`. Prefer granting roles via a group; use direct `roles` sparingly.

Config lives one JSON file per entity under `${TAPPAAS_CONFIG:-/home/tappaas/config}/people/`:

```
config/people/
  roles/*.json          # cross-cutting role labels
  organizations/*.json  # tenant / company / family
  groups/*.json         # teams, departments, access-sets (carry roles)
  users/*.json          # people: memberOf groups + roles + lifecycle state
```

Every write is checked for **reference integrity** before it lands — an unknown role, a
dangling `memberOf`, an org whose owner is not a user is rejected and no file is written
(the write is atomic, so a rejected edit leaves nothing behind). Full JSON-Schema
validation against `src/foundation/schemas/{role,organization,group,user}-fields.json`
is the separate `validate-people.sh` gate.

## What a fresh install has

`people-manager bootstrap` (run for you by `rest-of-foundation.sh` on a fresh install)
seeds the minimal org:

- **roles** `root`, `admin`, `user`
- **org** — your installation name, owned by the installer
- **groups** `users` (everyone; carries the `user` role) and `authentik Admins`
- **users** `root` (the platform-root account) and the **installer** (you)

**`authentik Admins` is Authentik's own built-in superuser group**, adopted by name
rather than invented (#476). Membership in an `is_superuser` group is the *only* thing
that grants the Authentik admin UI — the `admin` / `root` **roles** are labels TAPPaaS
passes to apps and confer nothing there. The installer (the site owner) is a member, so
day-2 user administration never needs the `akadmin` break-glass login; `root` deliberately
is not.

Group names are free-form identifiers (internal spaces allowed, so an Authentik-created
group can be named). The bootstrap ships flat names (`users`); for org-scoped groups the
convention is `<org>__<name>` — e.g. `acme__staff`.

## Manage people — `people-manager`

One CLI, the ADR-007 verb vocabulary, for all four kinds
(`role` · `org` (alias `organization`) · `group` · `user`):

```
people-manager <kind> list   [--json] [--deep]
people-manager <kind> show   <name> [--json]
people-manager <kind> add    <name> [field flags] [--force]  [--no-reconcile]
people-manager <kind> modify <name> [field flags]           [--no-reconcile]
people-manager <kind> delete <name> [--force]               [--no-reconcile]
people-manager reconcile [--apply]
people-manager validate
```

Field flags:

| Kind | Scalars | Lists (also `--add-<f>` / `--remove-<f>`) |
|------|---------|-------------------------------------------|
| `role`  | `--displayName` `--description` | — |
| `org`   | `--displayName` `--type` `--owner` (a user) `--parentOrg` (an org) | — |
| `group` | `--displayName` `--type` `--ownerOrg` (an org) | `--roles` |
| `user`  | `--displayName` `--email` `--state planned\|active\|suspended\|terminated` | `--roles`, `--groups` (→ `memberOf`) |

A list flag with a comma-separated value **replaces** the list (`--roles "admin,user"`);
`--add-<f>` / `--remove-<f>` (repeatable) edit it incrementally with set semantics. Only
the comma separates, so `--add-groups "authentik Admins"` is one member, not two.

### Add someone

```bash
people-manager user add jane --email jane@example.org --groups users                # ordinary user
people-manager user add jane --email jane@example.org --groups users --roles admin  # …or an admin
authentik-manager user-set-password jane            # give them a password to log in with
```

(The two `add` forms are alternatives — `add` refuses an existing user without `--force`.)
`--displayName` defaults to the username if you omit it.

**`add` / `modify` / `delete` are live when they return** (#482): each one writes the
validated config *and then pushes it* to Authentik. There is no second command to
remember — `jane` exists in Authentik as soon as the `add` succeeds, and only needs a
password.

### Change what someone can reach

```bash
people-manager user modify jane --add-roles admin           # grant a role directly
people-manager user modify jane --add-groups acme__staff    # or (preferred) via a group
people-manager user modify jane --remove-roles admin
people-manager group modify acme__staff --add-roles editor  # every member inherits it
```

### Groups, roles, orgs

```bash
people-manager org   add acme --displayName "Acme BV" --type company --owner jane
people-manager group add acme__staff --displayName "Acme Staff" --ownerOrg acme --type team --roles user
people-manager role  add editor --displayName "Editor" --description "May edit content"
people-manager group delete acme__staff        # refused while a user is still a member
people-manager role  delete editor --force     # delete despite references
```

References must resolve, so create in dependency order: the org's `--owner` must already
be a user, a group's `--ownerOrg` must already be an org.

`delete` guards on inbound references (a role still used, a group still in someone's
`memberOf`, an org still an `ownerOrg`/`owner`/`parentOrg`); `--force` overrides.
`add` refuses to overwrite an existing entity without `--force`.

⚠️ A `--force`d delete *can* leave a dangling reference behind — and the integrity gate
then rejects **every** subsequent write until you repair it (`people-manager group modify
acme__staff --remove-roles editor`). Prefer removing the references first.

## How a change reaches Authentik

Each write verb does three things, in this order:

1. **Validate, then write.** The reference-integrity gate runs first, and the file write
   is atomic — a rejected edit never reaches Authentik and leaves nothing on disk.
2. **Push the deletion, if it was one.** `reconcile` plans from what config *contains*,
   so a just-deleted entity is invisible to it; `delete` therefore removes the user,
   group or role from Authentik explicitly. An Organization has no Authentik object, so
   there is nothing to push. Groups Authentik ships itself (`authentik Admins`,
   `authentik Read-only`) are dropped from *config only* — never deleted from Authentik.
3. **Reconcile everything.** Not just this entity: `config/people/` is the desired state,
   so the moment we are already talking to Authentik is the right moment to converge all
   of it. Anything else staged with `--no-reconcile` goes live too.

**If the push fails** — identity service down, an action rejected — the command exits
non-zero and says so, and **the config write stays on disk**. Fix the service, then re-run
`people-manager reconcile --apply`. Do not redo the edit.

### Staging several edits — `--no-reconcile`

`--no-reconcile` on `add` / `modify` / `delete` writes config *without* pushing, for
batching a set of related changes into one push, or for editing while Authentik is down:

```bash
people-manager user  add  jane --email jane@example.org --groups users --no-reconcile
people-manager group add  acme__staff --displayName "Acme Staff" --ownerOrg acme --no-reconcile
people-manager user  modify jane --add-groups acme__staff --no-reconcile
people-manager reconcile              # preview the accumulated plan
people-manager reconcile --apply      # push it all at once
```

`reconcile` on its own is still how you inspect and repair drift: with no flag it prints
the plan, with `--apply` it converges Authentik to config.

### Inspect

```bash
people-manager user list                 # names
people-manager user show jane            # one entity, resolved
people-manager group list --deep         # groups with their members
people-manager org show acme --json
people-manager reconcile                 # preview: what would change in Authentik
people-manager validate                  # reference integrity of config/people
validate-people.sh                       # deeper: JSON-Schema validation
```

## Lifecycle — suspend and offboard

`user --state` is the lifecycle knob; it governs presence and access in Authentik:

| State | Effect in Authentik |
|-------|----------------------------------|
| `planned` | no identity presence at all — declared, not provisioned |
| `active` | present with full access (the default) |
| `suspended` | account **disabled**, all managed roles and memberships stripped — reversible |
| `terminated` | the account is **deleted** — the one governed deletion |

```bash
people-manager user modify jane --state suspended    # disabled in Authentik immediately
```

Reconcile is **additive for existence** (roles/groups are created, never implicitly
deleted) and **authoritative for access within the managed set** — memberships are added
or removed to match config, but entities absent from `config/people/` are never touched.

## Passwords and credentials

Credential delivery at user-creation time is not automated yet (it waits on SMTP), so
**after creating a user, set a password for them.** The identity controller CLI does this
directly against Authentik:

```bash
authentik-manager user-set-password <username>                    # generates + prints a password
authentik-manager user-set-password <username> --password 'newpw' # set one explicitly
```

Share a generated password over a secure channel; the user changes it after first login.
The same command is the **password reset** path — for someone else, or for yourself:

```bash
authentik-manager user-set-password jane
```

Nicer when the Authentik brand has a recovery flow configured (`brand.flow_recovery`) —
print a one-time enrollment/recovery link instead of a password, and send them that:

```bash
authentik-manager user-recovery-link jane
```

Without a recovery flow it exits 2 and tells you to fall back to `user-set-password`.

`authentik-manager` reads its URL + API token from `~/.authentik-credentials.txt`
(bootstrapped automatically; `url=` + `token=`), so no extra flags are needed. Override
with `--url` / `--token` / `--credential-file`, or `AUTHENTIK_URL` / `AUTHENTIK_TOKEN`.
Check the connection with `authentik-manager test`.

**Locked out entirely?** `akadmin` is Authentik's built-in break-glass admin. Log in at
`https://identity.<domain>`, or reset it the same way:
`authentik-manager user-set-password akadmin`.

## What a login can reach

Access to each app is a **per-app allow-list**, independent of authentication. When a
module installs, the identity service binds its Authentik Application to the `users`
group — plus `<module>-admins` when the module declares an in-app admin role (created on
demand at module-install time, not by `people-manager`).

⚠️ **Authentik fails open**: an Application with *no* policy binding admits every
authenticated user. The binding at install is therefore mandatory — that is the access
gate.

Two integration modes, chosen by what the module declares in `dependsOn`. Never stack
them on one app (double login, no benefit):

| Mode | `dependsOn` | How it works | In-app account |
|------|-------------|--------------|----------------|
| **OIDC** (e.g. Nextcloud) | `identity:identity` | the app is an OIDC client of Authentik; groups arrive in the `groups` claim | created just-in-time on first login |
| **Forward-auth** (e.g. Open WebUI) | `identity:accessControl` | Caddy asks the Authentik outpost, then injects `X-Authentik-*` headers | none — the URL is simply gated |

The user's groups travel in both modes; **the app decides what each group means**.
Authentik only carries them.

## Authentik admin UI

`https://identity.<domain>` — full user, group, application and flow administration for
anyone in `authentik Admins`. Changes made there are *not* in `config/people/`, so for a
managed entity the next reconcile may converge them away — and since every write verb now
reconciles, that can be the very next `people-manager` command anyone runs.
Prefer the verbs; use the UI for inspection and for Authentik-native settings (flows,
brands, stages) that TAPPaaS does not model.

## Verify the live state

```bash
authentik-manager test                   # token + reachability
authentik-manager list-users             # what Authentik actually has
authentik-manager list-groups
authentik-manager list-roles
authentik-manager get-user --name jane
people-manager reconcile                 # config vs live: the drift, as a plan
```
