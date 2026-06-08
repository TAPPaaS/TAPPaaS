# ADR-006: Identity — Users, Roles & SSO Provisioning

**Status:** accepted
**Date:** 2026-06-08
**Deciders:** @LarsRossen
**Related:** #56 (default user & role profiles); builds on #45 (accessControl forward-auth) and the variant model in [ADR-005](ADR-005-variant-domain-architecture.md)

---

## Context

Issue #56 asks us to define and implement the standard **role profiles** and
**default users** for TAPPaaS, and to provide an `add-user` workflow. The identity
module (Authentik) today has the plumbing but none of the people-facing machinery:

| Area | State today |
| ---- | ----------- |
| Authentik provisioning | REST API via the `authentik-manager` CLI (no blueprints) |
| Forward-auth (accessControl) | ✅ Implemented (#45) — Caddy ForwardAuth → outpost → `X-Authentik-*` headers |
| OIDC provider creation | ⚠️ Scaffolded only — `authentik_manager.oidc_app_ensure()` raises `NotImplementedError` |
| Users / Groups / Roles | ❌ None — `services/identity/*-service.sh` are empty stubs |
| Variant-awareness | ❌ Single Authentik instance; ignores `tappaas.variants` |
| Email / SMTP | ❌ `AUTHENTIK_EMAIL__*` env stubbed but commented out; no relay anywhere in the cluster |

The design must answer three things: **what the roles are**, **how a single login maps
to what a user can do** (including per-client isolation when variants exist), and **how a
user actually ends up with a working account in a downstream app** (the Nextcloud question).

### Guiding requirements (from the operator)

- A person has **one login**; their **role** determines what they can do.
- **No variants installed** → a set of default roles.
- **Variants installed** → those roles exist **per client**, except **Installer**
  (TAPPaaS-wide administration) which stays global.
- There must be an **`add-user`** script that sets up a basic user.

---

## Decision

### 1. The Authentik primitive mapping (resolves "single login, role decides")

Authentik has three primitives that are easy to conflate. We use them deliberately:

| Primitive | Real purpose | We use it for |
| --------- | ------------ | ------------- |
| **User** | One account, one login | The person |
| **Group** | Membership label that (a) flows to apps in `X-Authentik-Groups` / the OIDC `groups` claim and (b) gates app access via policy bindings | **Roles** |
| **Role** (RBAC) | Permissions *inside the Authentik admin* | Only the Installer's superuser capability |

"One login, role decides" = **one User with multiple Group memberships**. Roles are Groups.

### 2. Role profiles (the #56 deliverable)

| Role | Group | `is_superuser` | Authority | Scope |
| ---- | ----- | :---: | --------- | ----- |
| **Installer** | `tappaas-installers` | ✅ | Full Authentik admin + platform root; provisions all users | **Always global** |
| **Admin** | `<scope>-admins` | — | App-level role passed to apps; managed by the Installer | Default, or per-variant |
| **Module Admin** | `<scope>-<module>-admins` | — | App-level; the module reads the groups claim/header to grant in-app admin | Per-module (opt-in) |
| **User** | `<scope>-users` | — | Ordinary access | Default, or per-variant |

In v1, **Admin and Module-Admin are app-level roles only** — they are groups that flow to
applications, *not* Authentik-admin capabilities. Only the Installer can administer
Authentik and run `add-user`. (Delegated per-client admin is deferred — see Consequences.)

### 3. Group hierarchy: parent-per-scope, unique child names

Authentik groups carry a `parent` pointer (for the admin UI tree and attribute
inheritance), but the `X-Authentik-Groups` header / `groups` claim lists groups by
**name** — so child names must be globally unique to stay unambiguous downstream. We
combine both: a **parent group per scope** with **uniquely-named children**.

```
tappaas-installers                       ← global superuser, top-level (is_superuser)
tappaas         (parent, variant="")     ← default / no-variant scope
  ├─ tappaas-admins
  ├─ tappaas-users
  └─ tappaas-<module>-admins             ← created on demand when a module opts in
acme            (parent, variant="acme") ← one parent group per installed variant
  ├─ acme-admins
  ├─ acme-users
  └─ acme-litellm-admins
```

The **default variant `""` is the `tappaas` parent**, so "no variants → default roles"
and "variants → per-client roles" are the *same mechanism* with more parents. Each group
stores `attributes.tappaas = { variant, role, module? }` so tooling reconciles by
attribute, not by string-parsing names.

### 4. Two integration modes — and never stack them

How a role reaches an app depends on whether the app speaks OIDC:

| Mode | Dependency | How it works | Account provisioning | Use for |
| ---- | ---------- | ------------ | -------------------- | ------- |
| **Forward-auth** | `identity:accessControl` | Caddy ForwardAuth → outpost → `X-Authentik-*` headers | **None by itself** — gates the URL only | Apps with no native SSO (e.g. Open WebUI) |
| **OIDC** | `identity:identity` | App is an OIDC client of Authentik (code flow) | **JIT on first login** (the app creates the account from token claims) | Apps with native OIDC (e.g. Nextcloud) |

**Critical rule:** for an OIDC-capable app, use OIDC **and do not** also put a forward-auth
outpost in front of it — that produces a double login with no benefit (the OIDC app uses
the code flow, not the headers). Pick one mode per app. (See the Nextcloud example.)

A module **chooses its mode by what it depends on**: `identity:accessControl` → forward-auth,
`identity:identity` → OIDC.

**Mode A — Forward-auth (the gate).** Authentik is literally the front door; the app has no
separate login and trusts the injected headers:

```
Browser ─► https://openwebui.test2.tapaas.org
        ─► Caddy (ForwardAuth=1) ─► asks Authentik outpost "authenticated?"
             └─ no ─► 302 to Authentik login ─► user signs in
        ◄─ Authentik: yes + X-Authentik-Username: lars, X-Authentik-Groups: tappaas-users
        ─► Caddy injects headers, proxies upstream ─► Open WebUI trusts header → lars in
```

**Mode B — OIDC (delegated login).** Authentik is the identity provider, but the app keeps
its own session and owns a real account (files, quota, per-user data):

```
Browser ─► https://nextcloud.test2.tapaas.org   (Caddy proxies straight through, no gate)
        ─► Nextcloud shows "Log in with Authentik" ─► redirect to Authentik (OIDC) ─► sign in
        ◄─ ID token { sub, preferred_username: lars, email, groups: [tappaas-users] }
        ─► user_oidc creates/loads lars's account, starts a Nextcloud session
```

### 5. Three orthogonal knobs (how login, access, and role compose)

The design separates three concerns that are easy to conflate. They compose independently:

| Knob | Question it answers | Mechanism |
| ---- | ------------------- | --------- |
| **Mode** | *How* do you log in, and does the app provision an account? | The module's `dependsOn` (forward-auth vs OIDC) |
| **Access** | *Are you allowed into this app at all?* | An Authentik **PolicyBinding(group → Application)** |
| **In-app role** | *What can you do once inside?* | Group membership the app interprets (header / `groups` claim) |

A user's groups travel in **both** modes — as `X-Authentik-Groups` (Mode A) or the `groups`
claim (Mode B). The **app decides what each group means**; Authentik just carries it.

**Access enforcement is identical in both modes:** when a module installs, bind its
Authentik Application to the allowed groups — `<scope>-users`, `<scope>-<module>-admins`,
`<scope>-admins`, `tappaas-installers`. ⚠️ **Authentik defaults to allow-all when an
Application has no policy binding**, so this binding is **mandatory** at install — without it,
access (and variant isolation, §below) fails *open*.

### 6. Module-admin groups are opt-in

`<scope>-<module>-admins` is created **only if the module declares an in-app admin concept**,
via a module-JSON flag:

```json
"identity": { "providesAdminRole": true }
```

Rationale — most modules either have no admin role or their admin is just the Installer.
Auto-creating an admin group for every module would multiply groups by *modules × variants*
(e.g. 10 modules × 5 clients = 50 mostly-meaningless groups), cluttering Authentik and every
user's group list. Opt-in keeps the group set meaningful.

| Module | In-app admin? | Group |
| ------ | ------------- | ----- |
| Nextcloud | Yes (manages apps, settings, users) | ✅ `<scope>-nextcloud-admins` → mapped to Nextcloud's `admin` group |
| Open WebUI | Yes (admin vs user) | ✅ `<scope>-openwebui-admins` |
| Static website | No | ❌ none |

Promoting a user is then just another membership — same single login, more authority:
`add-user lars --role module-admin:nextcloud`.

### 7. Credential delivery: email via Authentik SMTP (link fallback)

`add-user` creates the account and asks Authentik to **email an enrollment link**; the
user sets their own password + MFA. Authentik talks SMTP directly via `AUTHENTIK_EMAIL__*`
(already stubbed in `identity.nix`) — it does **not** use the local postfix. Because no
SMTP relay exists in the cluster yet (see below), `add-user` is **email-first with a
printed one-time-link fallback**, so it works before SMTP is wired and improves to silent
email once it is.

### 8. Tooling

- **`add-user <user> --email <e> [--variant <v>] --role installer|admin|user|module-admin:<module> [--role …]`**
  — idempotent: ensure user → ensure scope/parent + child groups → add memberships →
  email enrollment (or print link). Mirrors the existing `*-manager` reconcile style.
- **`roles-ensure`** — reconcile that guarantees `tappaas-installers` plus the scope groups
  for the *current* variant set exist. Invoked from `identity/update.sh`, and hooked into
  `variant-manager add/remove` and module install.
- **`authentik-manager`** gains `user-ensure`, `group-ensure`, `user-add-to-group`,
  `user-email-recovery` / `recovery-link`, `app-bind-groups`, and list/reconcile helpers;
  plus the real **`oidc-app-ensure`** (replacing the Phase-D stub).

---

## SMTP — central config in `configuration.json`

**What Proxmox actually does.** PVE's only notification target is the builtin
`mail-to-root` of type **`sendmail`** → the local **postfix** (`relayhost=` empty) →
**direct-to-MX delivery**. There is **no relay/smarthost** to reuse. It does work — the
maillog shows `status=sent` to `lars@hrossen.dk` via `aspmx.l.google.com` (the recipient's
Google Workspace MX accepted it directly), with occasional transient DNS deferrals that
retried successfully.

**Why we can't just "copy Proxmox" for Authentik.** Postfix resolves each recipient's MX
and connects there per-message. Authentik's SMTP client points at a **single**
`AUTHENTIK_EMAIL__HOST:PORT` — it does **not** do per-recipient MX lookup — so it cannot
replicate direct-MX. It needs exactly one endpoint (a smarthost or a provider).

**Decision — one source of truth in `configuration.json`.** Per the operator's
instruction, the SMTP endpoint is defined once under `tappaas.smtp` and every consumer is
configured *from* it (Authentik today; Proxmox postfix `relayhost`, OPNsense, and any future
module later):

```json
"tappaas": {
  "smtp": {
    "host": "",                       // smarthost/provider FQDN; "" = unset → link fallback
    "port": 587,
    "from": "tappaas@<your-domain>",
    "username": "",                   // "" = unauthenticated relay
    "useTls": true,
    "secretRef": "smtp-password"      // password lives in /etc/secrets, never in config
  }
}
```

A small renderer (an `smtp-manager` verb, or part of `update`) projects this block into each
consumer: `AUTHENTIK_EMAIL__HOST/PORT/USERNAME/PASSWORD/USE_TLS/FROM` for Authentik (vars
already stubbed in `identity.nix:298`), and `relayhost` + `sasl_passwd` for postfix. Update
the block once → re-render everywhere.

**Endpoint choice (operator).** The block is the mechanism; the *value* is a choice:

| Choice | Effort | Notes |
| ------ | ------ | ----- |
| **External provider** (you already run Google Workspace for `hrossen.dk`; a Workspace/Gmail SMTP relay, or SES/Mailgun/Postmark…) | Lowest | Best deliverability for user-facing enrollment mail. Recommended. |
| **Cluster smarthost** — one postfix that accepts from the cluster and does direct-MX like the nodes do now | Medium | Truest "same as Proxmox"; also upgrades Proxmox/OPNsense notifications. Good follow-up. |
| **Leave `host` empty** | None | `add-user` prints the one-time enrollment link instead of emailing. |

Difficulty to wire Authentik→SMTP once `tappaas.smtp` is set = **LOW**. Because `add-user`
has the printed-link fallback, **SMTP is a prerequisite for the nicest UX, not for shipping
the role system.**

---

## Worked example: Nextcloud user `lars`

> *"If I install the nextcloud module and add user `lars` as a `tappaas-user`, will he be
> able to log into Nextcloud, will he have an account there, and will it work with Authentik
> as the front-end at `nextcloud.test2.tapaas.org`?"*

**Short answer: yes — via OIDC, once the Authentik OIDC side is implemented — and Nextcloud
must use OIDC, *not* the forward-auth gate.**

What we found in the module:

- `nextcloud.nix` already **bundles the `user_oidc` app** and ships a
  `nextcloud-configure-oidc.service` that runs `occ user_oidc:provider authentik …` with
  `--mapping-uid=preferred_username --mapping-email=email --mapping-groups=groups`. It is
  gated on `/etc/secrets/nextcloud.env` (waiting for `OIDC_CLIENT_ID/SECRET/DISCOVERY_URI`).
- `nextcloud.json` depends on **`identity:identity`** (OIDC), **not** `identity:accessControl`
  (forward-auth) — correctly, per the "never stack" rule above.
- The **only missing piece** is the Authentik side: `oidc_app_ensure()` is a
  `NotImplementedError` stub, so nothing populates `nextcloud.env`.

So end-to-end, once Phase 4 below is done:

1. `install-module.sh nextcloud` →`identity:identity` install-service calls
   `oidc-app-ensure nextcloud` → Authentik creates an OAuth2/OpenID **Provider + Application**
   (redirect `https://nextcloud.test2.tapaas.org/apps/user_oidc/code`, scopes
   `openid email profile`, a `groups` claim) and binds access to `tappaas-users` +
   `tappaas-nextcloud-admins` + `tappaas-admins` + `tappaas-installers`. It writes
   `client_id/secret/discovery_uri` into `/etc/secrets/nextcloud.env`; the Nextcloud service
   registers the provider.
2. `add-user lars --email lars@… --role user` → Authentik user `lars` in group `tappaas-users`.
3. `lars` opens `https://nextcloud.test2.tapaas.org` → clicks **Log in with Authentik** →
   authenticates once → **`user_oidc` JIT-creates his Nextcloud account on first login**
   (research-confirmed default: `auto_provision=true`), display name/email from his claims,
   and his `tappaas-users` group synced into Nextcloud.

**Will he have an account?** Yes — created automatically on first login (not before; Authentik
has no write path into Nextcloud's user table). **Front-end login at the public URL?** Yes,
through Authentik via OIDC. **Caveats:** keep the local Nextcloud `admin` reachable via
`…/login?direct=1` as a lockout escape hatch; do **not** enable Nextcloud server-side
encryption with OIDC (the module already warns — it causes data loss); and Nextcloud must
**not** also be placed behind the accessControl forward-auth (double login).

For contrast, **Open WebUI** (no native OIDC) uses **forward-auth/`accessControl`**: Authentik
gates the URL and passes headers; group-based access is enforced by the same PolicyBinding,
but there is no separate downstream account to provision.

---

## Single sign-on & variant isolation

These follow directly from the three knobs (§5) — **authentication is global, authorization
is per-application** — and both are properties of the **single shared Authentik instance**.

### Does SSO work across modules? — Yes

All modules authenticate against the same Authentik, which holds **one session** per user (a
cookie on the identity domain). After the first login that session is reused everywhere:

- **Forward-auth apps** — transparent. The outpost sees the live session and passes the user
  through with **zero interaction**.
- **OIDC apps** — the app redirects to Authentik's `/authorize`; with a valid session Authentik
  immediately returns a token with **no credential re-entry** — one click on "Log in with
  Authentik" (or zero if the app auto-redirects, e.g. Nextcloud `allow_multiple_user_backends=0`).

SSO spans **modes and variants**: sign into Open WebUI (forward-auth), then Nextcloud (OIDC)
logs you in without re-authenticating. (Single-logout propagates where the app supports it —
`user_oidc` single-logout is on by default.)

### If a `client1` user opens another variant's (or the default's) app — Authentik rejects it

Yes — at the **access** step, not the authentication step. Say `lars ∈ client1-users` opens the
default-variant `https://nextcloud.test2.tapaas.org`:

- That Application allows `tappaas-users`, `tappaas-nextcloud-admins`, `tappaas-admins`,
  `tappaas-installers`. `lars`'s only group is `client1-users` → **not in the allow-list**.
- **Forward-auth:** the outpost evaluates the binding → **denies** → lars sees Authentik's "you
  do not have access" page; he never reaches the app.
- **OIDC:** the `/authorize` redirect evaluates the binding → Authentik **refuses to issue a
  token** → "you do not have access to this application"; **no Nextcloud account is created**.

So Authentik authenticates *who he is* (SSO succeeds — he's a valid TAPPaaS user) but **denies
authorization** for an app outside his scope. The **Installer** (`tappaas-installers`) is in
every app's allow-list, so it reaches all variants by design.

⚠️ **This isolation is only as good as the binding.** Authentik allows *all* users into an
Application that has **no** policy binding, so the per-app group binding (§5) is **mandatory** —
a module installed without it would be reachable by every TAPPaaS user across every variant.
The install path must always apply it, and `identity/test.sh` must assert cross-variant denial
as a regression guard.

---

## Implementation plan (phased)

- **Phase 0 — SMTP + recovery flow.** Add `AUTHENTIK_EMAIL__*` (from `/etc/secrets`) to
  `identity.nix`; ensure an enrollment/recovery flow + email stage exist (idempotent, in
  `roles-ensure`). Decide the relay (external provider recommended; cluster smarthost is a
  follow-up). Non-blocking thanks to the link fallback.
- **Phase 1 — Authentik API surface.** Extend `AuthentikManager`: `group_ensure`,
  `user_ensure`, `user_add_to_group`, `user_email_recovery`/`recovery_link`,
  `app_bind_groups`, list/reconcile helpers + `authentik-manager` subcommands. Idempotent
  reconcile-in-place. *(Load-bearing — everything depends on it.)*
- **Phase 2 — `roles-ensure` reconcile.** Guarantees `tappaas-installers` + the scope groups
  for the current variant set; hooked into `identity/update.sh`, `variant-manager add/remove`.
- **Phase 3 — `add-user` script.** Orchestrates ensure-user → ensure-groups → add-to-groups
  → email enrollment (link fallback). Default `tappaas` scope works end-to-end here.
- **Phase 4 — module integration & access bindings.** Implement `oidc-app-ensure` (replace the
  stub) and wire the empty `services/identity/install-service.sh` to: create the per-module
  `<scope>-<module>-admins` group (opt-in via a module-JSON flag), bind app access
  (variant-aware), and — for OIDC apps — write `<module>.env` and trigger the app's configure
  service. This is the phase that closes the Nextcloud loop.
- **Phase 5 — tests + docs.** `identity/test.sh` cases: idempotent reconcile; default vs
  per-variant group creation; **SSO reuse across modules**; **cross-variant denial** (a
  `client1` user is rejected from another scope's app — the fail-open guard); access gating;
  OIDC provider present. Plus operator docs.

---

## Consequences

**Positive**
- One login per person; roles are just group memberships — simple mental model.
- Default and per-client roles are one mechanism (parent-per-scope), so variants scale cleanly.
- Access gating is uniform (PolicyBinding group→app) regardless of auth mode.
- Nextcloud works the day Phase 4 lands — the module side is already built.

**Limitations / deferred**
- **Delegated per-client admin** (an Acme Admin managing only Acme's users *inside Authentik*)
  needs per-object Authentik RBAC and is **out of scope for v1**. v1: the Installer provisions
  everyone; "Admin" is an app-level role. Revisit with Authentik RBAC roles later.
- **SMTP relay** must be chosen/provided for silent email; until then `add-user` prints the
  enrollment link.
- **Module-admin groups are opt-in** (a module declares it has an admin role) to avoid
  littering Authentik with admin groups for apps that have no admin concept.
- **OIDC vs forward-auth is per-app and mutually exclusive** — module authors must pick the
  right `dependsOn` (`identity:identity` for OIDC apps, `identity:accessControl` for the rest).
