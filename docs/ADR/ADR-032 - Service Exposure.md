# ADR-032 — Service Exposure: Ports, Native Clients and Machine Callers

| | |
|---|---|
| **Status** | **Proposed** |
| **Version** | 0.1 |
| **Date** | 2026-10-16 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007, @AndreasJe |
| **Closes / addresses** | **#845**. Amends ADR-021 R1 and extends ADR-023. Related: #129, #154, #597, #642, #643, #656, #806. |
| **Changelog** | v0.1 — first draft, from the three cases in #845 and research into what Authentik's forward-auth, the os-caddy plugin and Jellyfin's clients can do. |

## Context

ADR-021 R1 says Caddy is always in the path and the identity gate is not optional. ADR-023 gave
routes their own zones, path rules, and `identityGate: false`. Three cases have since shown that
"the gate" means more than one thing, and that the model has no word for them.

1. **Several services on several ports — NOMAD (#129).** A Command Center plus apps, each a
   container on its own port, linked as *the current host + port*. Caddy publishes a hostname on
   443, and `identity:accessControl` gates one hostname per module. The apps can not be published,
   so NOMAD was made internal-only: reached at `nomad.<zone>.internal`, around Caddy, outside R1.
2. **Native app clients — Jellyfin (#806, with @AndreasJe).** The web UI signs in through
   Authentik behind forward-auth, but TV, phone and desktop clients can not do a browser sign-in in
   front of the app. So they can not reach Jellyfin from outside at all.
3. **Machine callers — APIs and webhooks (@ErikDaniel007, #642, #643, #656).** A caller that can
   not sign in in a browser gets `identityGate: false` on its path. That opens the path; it does not
   authenticate the caller.

### What exists today

How a module's routes are authenticated is implied by its dependencies, not declared:

| What the module does | Who authenticates | Example |
|---|---|---|
| Depends on `identity:accessControl` | Authentik forward-auth at Caddy, one proxy provider (`forward_single`) per hostname | Jellyfin |
| Depends on `identity:identity` only | The app itself, by OIDC against Authentik | Nextcloud, Forgejo, Immich, Open WebUI, LiteLLM |
| A `proxyAccess` rule with `identityGate: false` | Nobody at Caddy; the app, if it checks a key | HA and n8n webhooks |
| No `proxyDomain` | Nobody at Caddy; reached at `.internal` | NOMAD |

### What the components can do

These are the findings from the research for #845.

**Authentik forward-auth**

- **One gate per hostname (`forward_single`) is how we use it and it fits.** Each hostname has its
  own policy (who may use it) and its own session.
- **Domain-level mode (`forward_domain`)** gates every name under a cookie domain with one
  provider. It shares one access policy and one session cookie across all of them: a user allowed
  into one app is allowed into all. With a non-standard port it is very likely broken.
- **A gate on another port.** A `forward_single` provider whose external host includes the port
  (`https://nomad.example.org:8090`) matches by `X-Forwarded-Host`, which Caddy sends with the port.
  This should work, but it is **untested** (T1).
- **Machine credentials at the gate.** With *intercept header auth* on (the default), the outpost
  accepts `Authorization: Basic` with a user's **app password**, a Basic pair with the username
  `goauthentik.io/token` and a JWT, or `Authorization: Bearer` with a JWT that Authentik issued
  for that provider (client-credentials grant). A bad header gets 401, not a redirect.
- **Limits.** Authentik can not require a token on one path and allow a session on another; it only
  has *unauthenticated paths*, as regexes. It caches a result for 60 seconds and creates a session,
  so a revoked credential keeps working for a short while. It does not remove the `Authorization`
  header, so the app sees the caller's Authentik credential unless Caddy removes it.

**os-caddy (Caddy on the firewall)**

- A domain can listen on another port (`FromPort`). Forward-auth is set per handler. There is one
  forward-auth provider (the Authentik outpost) for the whole Caddy.
- Rate limiting and CrowdSec are not known to be available in the plugin (O2).

**Jellyfin**

- Native clients only know username and password (`/Users/AuthenticateByName`). None do OIDC.
- **Quick Connect** (a code shown on the TV, approved from a signed-in session) works in most
  clients, but not in Kodi or Infuse.
- The SSO-Auth plugin used for #806 (9p4/jellyfin-plugin-sso) was **archived on 2026-05-12**.
- The working pattern elsewhere (SWAG, YunoHost, Cloudron, the Authentik docs) is: no
  forward-auth on the Jellyfin host; Jellyfin's own login, with the users kept in the directory
  through **LDAP** (`jellyfin-plugin-ldapauth` against an LDAP server — here Authentik's LDAP
  outpost); Quick Connect for TVs; rate limiting and banning on the login path.
- Jellyfin has had unauthenticated CVEs as recently as 10.11; an internet-facing Jellyfin must be
  kept current.

## Requirements

- **E1. Every route says how its callers are authenticated.** Not implied by a dependency.
- **E2. Every caller is authenticated by someone.** Caddy's gate or the app. A route nobody
  authenticates is allowed only when it says why, and it is narrowed (zones, networks, paths).
- **E3. One gate per hostname and port.** Each with its own policy and session.
- **E4. A module may publish several services on several hostnames or ports**, without each one
  becoming a module of its own.
- **E5. A module may be internal-only**, as a declared choice, not a missing field.
- **E6. No new network path around the firewall.** Everything published still enters through
  Caddy on the firewall (ADR-021 D2/D3).

## Decision

### D1. `proxyAuth` — one field, four values, on every route and path rule

Each route (the primary and each `proxyRoutes` entry) and each `proxyAccess` rule carries
`proxyAuth`:

| Value | Who authenticates | Caddy does | Use for |
|---|---|---|---|
| **`gate`** | Authentik at Caddy | forward-auth; browsers sign in; machine callers send an Authentik credential (D3) | apps with no login of their own, or one we do not trust on the internet |
| **`app`** | the app | no forward-auth; the hardening of D4 when the route is reachable from the internet | apps with OIDC (Nextcloud, Forgejo, Immich), apps with native clients (Jellyfin), APIs with their own keys (LiteLLM) |
| **`none`** | nobody | no forward-auth; **requires** `reason` and a narrowing (zones other than `internet`, networks, or a `none` route with path rules) | callers that can not hold a credential, e.g. a webhook that is signed in its payload |
| *(module)* **`internal`** | the app | no route at all | D5 |

Defaults keep today's behaviour: `gate` where the module depends on `identity:accessControl`,
otherwise `app`. A path rule inherits its route's value.

`identityGate: false` becomes `proxyAuth: none` (or `app`, when the app checks a key). It is kept
as an alias for one release and migrated by a config migration (ADR-025).

Validation (refuse before writing): `gate` without `identity:accessControl`; `none` without a
`reason` or with `internet` and no path; `app` on a route reachable from the internet on a module
whose catalog entry does not say it has a login of its own (`auth.own: true`).

### D2. Several services — a route per service, a gate per route

A module publishes each service as a `proxyRoutes` entry. Each entry gets a hostname and,
under `gate`, its **own** Authentik provider (`forward_single`, external host = that hostname and
port) — never a domain-level provider (E3).

- **Default: one hostname per service** (`<route>.<domain>` or an explicit `proxyDomain`), on 443.
  This needs nothing new beyond #597 (several hostnames per module).
- **When the app links by port** (NOMAD builds links as *current host + port*), a route may set
  **`proxyListenPort`**: Caddy serves the module's hostname on that port (`FromPort`), the WAN rule
  and the caddy-reach rule open that port to the same zones, and the provider's external host is
  `https://<host>:<port>`. Only after T1 shows the forward-auth callback works on a non-443 port.

NOMAD stays internal (D5) until there is a reason to publish it. If that happens, its apps become
`proxyListenPort` routes on its hostname, each `gate`.

### D3. Machine callers — a credential at the gate, a key at the app, or a stated exception

A caller that can not sign in through a browser has three ways in, in this order of preference:

1. **On a `gate` route: an Authentik credential.** The caller gets an Authentik **app password**
   (a user or a service account) and sends it as `Authorization: Basic`, or uses the
   client-credentials grant and sends the JWT. `identity:accessControl` turns *intercept header
   auth* on for every provider it makes. Who may call is the provider's policy, as for people.
   Caddy removes the `Authorization` header before the app, unless the route sets
   `proxyPassAuthorization: true` (T2). Revocation takes up to a minute (the outpost's cache).
2. **On an `app` route: the app's own key.** LiteLLM virtual keys, Nextcloud app passwords, Immich
   API keys. The app authenticates; Caddy narrows (zones, networks, paths).
3. **`none`, with a `reason`.** For webhooks: the zones or provider networks (ADR-023, #656)
   narrow it, and the payload's signature is the app's job.

The gate can not *require* a token on `/api` while it allows a session elsewhere (it would also
accept a browser's session cookie there). That is acceptable: either credential is a person or
service account allowed by the same policy.

Client certificates (mTLS) are not adopted now: the plugin has no per-handler client-CA setting
we have tested, and no caller has asked for them.

### D4. Apps that do their own login — `app`, with hardening at Caddy

An `app` route that is reachable from the internet gets, from network:proxy:

- **A rate limit on the login paths** the catalog entry names (`auth.loginPaths`, e.g.
  `/Users/AuthenticateByName` for Jellyfin), if os-caddy can express it (O2); otherwise
  CrowdSec or fail2ban on the firewall, fed by Caddy's access log (O2).
- **Admin and metrics paths closed from the internet**, as a `proxyAccess` rule
  (`auth.adminPaths` → the site's internal zones and `netbird`).
- **A version floor**, from the module's pin, enforced by the normal update cadence (ADR-028).

For **native-client apps**, identity is still Authentik's, through LDAP:

- **`identity:ldap`** — a new identity service: an Authentik LDAP outpost, a bind account per
  consuming module, and the group that may use the app. Reachable only from the consuming module's
  VM.
- **Jellyfin** moves from `identity:accessControl` to `identity:ldap` and `proxyAuth: app`:
  the LDAP-Auth plugin, users from the Authentik group, **Quick Connect** on for TVs. The web UI
  signs in the same way (the archived SSO plugin and #806's forward-auth are removed).
  Clients without Quick Connect (Kodi, Infuse) use the username and password.

### D5. Internal-only — a declared exception to R1

A module may declare **`exposure: "internal"`**. It has no `proxyDomain`, no Caddy route and no
external DNS. It is reached at `<vm>.<zone>.internal`, from the zones its ingress rules allow, and
authenticates its users itself, or not at all on a trusted zone. R3's "not published" message is
not shown for it, because it is intended.

**ADR-021 R1 is amended** to: *Caddy is in the path of every published name. A module declared
`internal` has no published name and is reached only from the zones its ingress allows.*

NOMAD is the first such module. A module with `exposure: internal` that sets a `proxyDomain` is
refused.

## Use cases

| Module | Today | Under this ADR |
|---|---|---|
| NOMAD | no `proxyDomain`, R3 warns | `exposure: internal`; later, if published: one hostname, the apps as `proxyListenPort` routes, each `gate` |
| Jellyfin | `gate`, SSO plugin (archived), clients can not log in from outside | `app` + `identity:ldap`, Quick Connect, rate limit on login, admin and `/metrics` internal |
| Home Assistant | webhook path `identityGate: false` | the webhook path `none` + `reason`; the rest `app` (HA's own login) |
| n8n | webhook host `none` route + path rule | same, `proxyAuth: none` + `reason` on the rule |
| LiteLLM | OIDC UI, API key | `app`; API callers use LiteLLM keys (D3.2) |
| An app with no login of its own, used by a script | not possible without `identityGate: false` | `gate`; the script sends an Authentik app password (D3.1) |

## Alternatives considered

| | Alternative | Why not |
|---|---|---|
| A1 | **Domain-level forward-auth** for a module's names | One policy and one session for all names; broken with ports. Fails E3. |
| A2 | **Forward-auth in front of Jellyfin with its clients' paths excluded** | The clients' paths are the API, i.e. all of Jellyfin. The gate would cover only the web UI, which Jellyfin's own login already covers. |
| A3 | **Jellyfin only over NetBird** | Secure, but every TV and family phone needs a NetBird client. Kept as the choice for sites that do not want Jellyfin on the internet: `proxyAllowedZones: ["netbird", …]`. |
| A4 | **Keep `identityGate: false` as the only machine path** | Opens instead of authenticating (E2). |
| A5 | **mTLS for machine callers** | Untested in the plugin; nobody needs it yet. Can be added as a fifth `proxyAuth` value. |
| A6 | **A second, internal reverse proxy (#154)** for internal-only modules | A second TLS and gate stack for modules that chose not to be published. Out of scope; #154 stays open on its own. |

## Consequences

- Every route's authentication is visible in its module JSON, and validated.
- `identity:accessControl` gains header auth on its providers; `network:proxy` gains
  `proxyAuth`, `proxyListenPort`, `proxyPassAuthorization`, and hardening for `app` routes.
- A new identity service (`identity:ldap`), and an LDAP outpost to keep running and patched.
- Jellyfin becomes reachable from the internet with its own login in front. That is a larger attack
  surface than a gate; D4 and the update cadence are what limit it.
- `none` routes need a `reason`; the existing ones are migrated.

## Implementation plan

| Phase | What | Notes |
|---|---|---|
| **P0** | Tests T1–T3 on hrossen | decides `proxyListenPort` and header stripping |
| **P1** | `proxyAuth` field, defaults, validation, `identityGate` alias and migration; `exposure: internal` (NOMAD) | no behaviour change |
| **P2** | Header auth on accessControl providers; `Authorization` stripping; docs for app passwords | D3.1 |
| **P3** | `identity:ldap`; Jellyfin on LDAP + Quick Connect; `app` hardening (rate limit or CrowdSec, admin paths) | with @AndreasJe |
| **P4** | `proxyListenPort` | only if T1 passes and a module needs it |

## Testing

- **T1 — forward-auth on a non-443 port.** A test route on `FromPort` 8443 with a
  `forward_single` provider at `https://<host>:8443`: the sign-in redirect returns to the right
  host and port, and the session holds.
- **T2 — the `Authorization` header.** Through a `gate` route with an app password: the upstream
  sees no `Authorization` header when stripped, and the caller's header when
  `proxyPassAuthorization` is set; a wrong password gets 401, not a redirect.
- **T3 — LDAP for Jellyfin.** Authentik LDAP outpost + LDAP-Auth plugin: a user in the group logs
  in from a native client and with Quick Connect; a user outside the group is refused; a removed
  user is refused at the next login.
- Unit: `proxyAuth` validation, defaults, the migration from `identityGate`.
- Module tests: Jellyfin's login rate limit and admin paths from WAN; NOMAD has no Caddy route.

## Open questions

1. **O1 — Is `app` acceptable for Jellyfin on the internet**, or do sites default to A3 (NetBird)
   and opt in to public exposure?
2. **O2 — Rate limiting.** Does os-caddy expose Caddy's `rate_limit`, or is CrowdSec (os-crowdsec,
   reading Caddy's log) the way? This decides D4's mechanism.
3. **O3 — Service accounts.** Should accessControl create an Authentik service account per
   calling system (with its app password in the vault), or do operators make them by hand?

## Documentation impact (ADR-013)

| File | Change |
|---|---|
| `src/foundation/network/services/proxy/fields.json` → `README.md` | `proxyAuth`, `proxyListenPort`, `proxyPassAuthorization`; `identityGate` deprecated |
| `src/foundation/identity/README.md` | header auth and app passwords; `identity:ldap` |
| `src/home/jellyfin/INSTALL.md` | LDAP sign-in, Quick Connect, what is reachable from outside |
| `src/home/nomad/README.md` | `exposure: internal` |
| ADR-021 | R1 as amended by D5 |
