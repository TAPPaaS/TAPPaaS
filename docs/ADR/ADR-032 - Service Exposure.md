# ADR-032 — Service Exposure: Machine Callers, Native Clients and Unpublished Modules

| | |
|---|---|
| **Status** | **Accepted** (operator, 2026-10-17) — **built**: P0–P4. Rate limiting is #851. |
| **Version** | 1.0 |
| **Date** | 2026-10-17 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007, @AndreasJe |
| **Closes / addresses** | **#845**. Amends ADR-021 R1 and extends ADR-023. Related: #129, #154, #597, #642, #643, #656, #806, #850. |
| **Changelog** | v1.0 (2026-10-17) — **P4 built, all phases done.** O3 answered: `identity-manager` ends app sessions after a reconcile takes access from someone, through a module's `revoke-sessions.sh <username>` (Jellyfin: deletes the person's devices with the TAPPaaS API key). T6 green. v0.4 (2026-10-17) — **P2 and P3 built.** P2: `caddy-manager set-gate` turns the gate on and off, and a gated handle always carries `header_up -Authorization` (added by caddy-manager from the handle's forward-auth, so network:proxy's re-renders keep it); accessControl asserts header auth on its providers; `authentik-manager service-account-ensure`; an `identityGate: false` rule needs a `description`. D1's *narrowed* clarified: a path rule never covers the whole route — its zones or networks narrow it further where its callers allow. T5 green. P3: Jellyfin published without the gate, T4 green from the internet. v0.3 (2026-10-17) — **Accepted** by the operator. O1 answered by the plugin: os-caddy takes extra Caddyfile config only globally, never inside one site, so a per-site `rate_limit` is not possible through it; P3 relies on the machine-generated passwords and Jellyfin's login lockout, and rate limiting moves to a CrowdSec issue. O3 deferred to P4. v0.2 (2026-10-17) — **smaller, after the operator's review and the P0 tests.** No new `proxyAuth` field: ADR-023 stays the model and gains three things — the gate authenticates machine callers (D1), a module without `network:proxy` is unpublished by design and an amended R1 says so (D2), and Jellyfin is published without the gate for friends and family, hardened (D3). Several ports per hostname are verified possible but not built (D4). LDAP for Jellyfin is dropped: the SSO plugin and Quick Connect cover its clients. NetBird is not the answer for friends and family (operator). NOMAD moves to the DMZ. P0 results recorded (T1–T3, on Jellyfin 10.11 and 12.2). v0.1 (2026-10-16) — first draft: a `proxyAuth` field with four values on every route. |

## Context

ADR-021 R1 says Caddy is always in the path and the identity gate is not optional. ADR-023 gave
routes their own zones, path rules, and `identityGate: false`. Three cases did not fit (#845):

1. **Several services on several ports — NOMAD (#129).** A Command Center plus apps, each a
   container on its own port, linked as *the current host + port*. It was made internal-only,
   reached at `nomad.<zone>.internal`, around Caddy.
2. **Native app clients — Jellyfin (#806, with @AndreasJe).** TV, phone and desktop apps log in to
   Jellyfin's own API with a username and password; they cannot do a browser sign-in in front of
   it. Behind the gate, friends and family cannot use Jellyfin's apps from outside at all.
3. **Machine callers — APIs and webhooks (@ErikDaniel007, #642, #643, #656).** A caller that cannot
   sign in in a browser gets `identityGate: false` on its path. That opens the path; it does not
   authenticate the caller.

### What the P0 tests showed (hrossen, 2026-10-16/17)

All three ran on Jellyfin 10.11 and again on 12.2, and were torn down without leftovers.

| Test | Result |
|---|---|
| **T1** A gate on another port of the same hostname (`jellyfin.<domain>:9443`, its own Authentik provider, external host with the port) | Works: the sign-in redirect, the callback on `:9443` and the session. The session does not open the 443 gate: each provider has its own cookie. |
| **T2** Machine credentials at the gate | An Authentik **app password** (HTTP Basic) and a **client-credentials JWT** (Bearer) both pass. Caddy can remove `Authorization` before the app (`header_up -Authorization`). A bad credential gets a **302** to the login, not a 401. An app password opens **every gate its user is allowed through**; a JWT only its own provider. Revoking a credential takes up to **60 s** (the outpost's cache). |
| **T3** Jellyfin native login against Authentik over LDAP | Works (LDAP outpost + LDAP-Auth plugin 23/24): login from the native-client API, refusals, Quick Connect, a removed group member refused at the next login. But **a Jellyfin session from before the removal keeps working.** |
| Sign in with Authentik on Jellyfin 12.2, through the gate and the SSO plugin | Works. Accounts the plugin creates get a random password (plugin 5.x), so none can be signed into with an empty one. |

## Requirements

- **E1. Every caller is authenticated by someone** — Caddy's gate or the app. A path nobody
  authenticates is allowed only with a stated reason, and narrowed (zones, networks, paths).
- **E2. Friends and family use Jellyfin's apps from their own homes**, without a VPN client.
- **E3. A module may stay unpublished**, as a choice, reached only from the zones its ingress allows.
- **E4. No new network path around the firewall.** Everything published enters through Caddy.

## Decision

### D1. The gate authenticates machine callers

A route behind `identity:accessControl` already accepts a machine credential in the
`Authorization` header (T2); this ADR makes that the way a machine caller gets through.

- **Each calling system gets an Authentik service account**, allowed by the same policy as people
  (the app's group binding). It uses the **client-credentials grant** and sends the JWT as
  `Authorization: Bearer`: a JWT opens only the provider it was issued for. An **app password**
  (Basic) works too, but it opens every gate its user may use, so it is for a service account that
  has access to one app only.
- `identity:accessControl` makes sure **intercept header auth** is on for every provider it creates.
- On a gated route, Caddy **removes the `Authorization` header** before the app, so the app never sees
  the caller's Authentik credential. A route whose app needs its own `Authorization` header behind
  the gate is a contradiction (the gate would take the header as its own) and is refused.
- Callers should know: a wrong or expired credential gets a 302 to the login page, not a 401; a
  revoked one stops working within a minute.

**`identityGate: false` stays**, for a caller that cannot hold a credential at all — a webhook that
signs its payload (Home Assistant, n8n). Such a rule must carry a `description` that says why;
validation refuses one without. It is narrowed by being a path rule, which never covers the whole
route, and further by its zones or networks where its callers allow (a cloud webhook comes from
anywhere; a provider with published ranges is a network list, #656).

### D2. A module without `network:proxy` is unpublished — by design

A module that does not depend on `network:proxy` has no published name. It is reached at
`<vm>.<zone>.internal`, from the zones its ingress rules allow, and authenticates its users itself
— or not at all, for a module like NOMAD that holds no user data. No new field: the dependency is
the declaration.

**ADR-021 R1 is amended** to: *Caddy is in the path of every published name. A module that is not
published is reached only from the zones its ingress allows.*

**Placement.** An unpublished module that runs third-party code on its own (installs and updates
containers) and keeps no user data lives in the **`dmz`** zone: a compromised one then reaches the
internet and nothing else on the site. NOMAD is the first (`zone0: dmz`); the home network reaches
it through its ingress rules.

### D3. Jellyfin is published without the gate, for friends and family

Jellyfin's apps must work from other people's homes, without a VPN (E2), and no gate lets a native
client through (A2). So Jellyfin is the one published module **without** forward-auth. Its own
login decides who gets in:

- **Web:** *Sign in with Authentik* (the SSO plugin, OIDC). Who may use Jellyfin is the Authentik
  group bound to its application. A friend gets an Authentik account in that group.
- **Apps and TVs:** **Quick Connect** — the TV shows a code; the friend approves it from a signed-in
  web session. Accounts the SSO plugin creates have a random password, so a code is how they reach
  an app. Clients without Quick Connect (Kodi, Infuse) are not supported for SSO accounts.
- **Local accounts** (`admin`, `stream`, `local`) keep their passwords; `admin` is not allowed to
  sign in from outside the site (Jellyfin's per-user *remote access* policy).

What being on the internet without a gate costs is mostly Jellyfin's own history of endpoints that
skip the authorization check (an unauthenticated file read open on 10.11 until #850). So the
hardening is part of the decision, not an option:

| Measure | Where |
|---|---|
| Jellyfin sees the client's real address: the firewall is a **known proxy**, so the per-user remote-access policy and the login lockout act per client, not per Caddy | Jellyfin `network.xml` |
| **Login attempts limited** per account (Jellyfin's lockout); per-client rate limiting with CrowdSec, later (O1) | Jellyfin |
| **Admin and diagnostic paths closed from outside**: `/metrics`, `/Startup/*`, `/System/Restart`, `/System/Shutdown`, `/System/Logs`, the dashboard — an ADR-023 `proxyAccess` rule to the site's zones | `network:proxy` |
| **Kept current**: Jellyfin follows its releases (12.x from a pinned nixos-unstable, #850); a security advisory is an update, not a wait for the next NixOS release | the module |
| **Removing someone ends their sessions**: deleting or disabling a user, or removing them from Jellyfin's group, also revokes their Jellyfin sessions and devices (T3 showed they survive) | `identity` (O3) |

The VEX triage of #850 is unchanged by this: the open jellyfin-ffmpeg findings need a crafted file
in the library or a signed-in user either way.

### D4. Several ports on one hostname — possible, not built

T1 showed a gate works on another port of a published hostname. A module whose apps link as
*host + port* (NOMAD) could publish each port as a route with its own gate. Each port then needs
its own WAN rule and caddy-reach rule, and the module's ports are on the internet. Not built until a
module needs it; NOMAD stays unpublished (D2).

## Use cases

| Module | Under this ADR |
|---|---|
| NOMAD | unpublished (D2), in the `dmz` zone, reached from home at `nomad.dmz.internal` |
| Jellyfin | published without the gate (D3): SSO for the web, Quick Connect for apps, hardened |
| Home Assistant, n8n webhooks | `identityGate: false` with a description of the signature they carry (D1) |
| A script calling a gated app | a service account and a client-credentials JWT (D1) |
| Nextcloud, Immich, Forgejo, Open WebUI, LiteLLM | unchanged: their own OIDC login, their own API keys and app passwords |

## Alternatives considered

| | Alternative | Why not |
|---|---|---|
| A1 | **A `proxyAuth` field with four values on every route** (v0.1) | More model than the cases need: machine callers are D1, unpublished modules are a dependency already, and one module needs the no-gate decision. |
| A2 | **The gate in front of Jellyfin with its clients' paths excluded** | The clients' paths are the API, so all of Jellyfin. The gate would cover only the web UI, which Jellyfin's login covers anyway. |
| A3 | **NetBird for friends and family** | Not workable for people outside the household (operator, 2026-10-17). Stays the way for the household's own devices. |
| A4 | **LDAP for Jellyfin** (Authentik LDAP outpost, LDAP-Auth plugin) | Works (T3), but SSO plus Quick Connect covers every client except Kodi and Infuse, without an outpost to run, reach and patch. Can be added later for those. |
| A5 | **Authentik domain-level forward-auth** for a module's names | One policy and one session for all names, broken with ports. |
| A6 | **mTLS for machine callers** | Untested in the plugin; nobody needs it yet. |
| A7 | **A second, internal reverse proxy (#154)** for unpublished modules | A second TLS and gate stack for modules that chose not to be published. #154 stays open on its own. |

## Consequences

- Machine callers authenticate as service accounts; `identityGate: false` shrinks to webhooks with a
  stated reason.
- Jellyfin is reachable from the internet with its own login in front. That is a larger attack
  surface than a gate; D3's measures and keeping it current are what limit it.
- `identity` gains session revocation in the apps that keep sessions (Jellyfin first).
- Unpublished is explicit in ADR-021, and modules like NOMAD are contained in the DMZ.

## Implementation plan

| Phase | What |
|---|---|
| **P0** | Tests T1–T3 — **done** (above). |
| **P1** | NOMAD in the `dmz` zone (repo default and hrossen); ADR-021 R1 amended. **Done.** |
| **P2** | D1: header auth asserted on accessControl providers; `Authorization` removed on gated routes; `identityGate: false` requires a description; a service-account helper (O2); docs. **Done** (T5). |
| **P3** | D3: Jellyfin leaves `identity:accessControl`; known proxy, login limits, admin paths closed, admin without remote access; rate limiting (O1, now #851). **Done** (T4). |
| **P4** | Session revocation on user removal, Jellyfin first (O3). **Done** (T6). |

## Testing

- **T1–T3** — done; results in *Context*.
- **T4 (P3)** — from outside the site, through the public name: a native client signs in with Quick
  Connect; the web signs in with Authentik; `/metrics`, `/Startup/*` and the dashboard get 403; the
  login is rate-limited; `admin` is refused from outside and works from home; Jellyfin's log shows
  the client's address, not the firewall's.
- **T5 (P2)** — **done, 12/12** (hrossen, a test route on `:9443`): a gated handle gets forward-auth
  and `header_up -Authorization` from caddy-manager; the provider intercepts header auth;
  `service-account-ensure` writes its credentials 0600 and is idempotent; the client-credentials
  JWT passes the gate as the service account and the app sees no `Authorization`; no credential
  gets a 302; `set-gate --off` removes the gate and the strip header (the app gets its own header
  again), `--on` restores both. The description rule: `test-proxy-path-rules.sh`.
- **T4 (P3)** — **done, 17/17** from the internet: Sign in with Authentik and a Quick Connect
  sign-in from outside; eleven admin paths 403 in any letter case; Jellyfin logs the client's own
  address.
- **T6 (P4)** — **done** (hrossen): a test user signed in through the public name on the web and on
  a "TV" (Quick Connect); `identity-manager user modify --remove-groups users` reported
  `Ended app sessions: jellyfin: t6test`, the hook ended the account's devices (four: Quick Connect
  and the SSO round trip each register one), and both tokens got 401 afterwards. A person without a
  Jellyfin account is no error. Unit: `identity-manager/test/unit/sessions.test.ts`.

## Open questions

1. **O1 — Rate limiting.** *Answered (v0.3):* the firewall's Caddy has `rate_limit` built in, but
   os-caddy imports extra config only globally (`caddy.d/*.global`, `*.conf`), never inside a site,
   so it cannot be scoped to Jellyfin through the plugin. Every Jellyfin password TAPPaaS sets is
   machine-generated (the SSO plugin's 64 random bytes, the install's 20 characters), and Jellyfin
   locks an account after repeated failures; per-client limiting comes with CrowdSec, its own issue.
2. **O2 — Service accounts.** Should `identity-manager` create a service account per calling system
   (with its credential in the vault), or do operators make them by hand?
3. **O3 — Revoking Jellyfin sessions.** *Answered (v1.0):* from `identity-manager`, after a reconcile
   that takes access from someone (deleted, disabled, out of a group), through a module hook
   `revoke-sessions.sh <username>`; Jellyfin's deletes the person's devices with the TAPPaaS API key.
   A change made directly in Authentik's admin UI does not run it.

## Documentation impact (ADR-013)

| File | Change |
|---|---|
| `src/foundation/network/services/proxy/fields.json` → `README.md` | `identityGate: false` needs a description; `Authorization` removed on gated routes |
| `src/foundation/identity/README.md` | machine callers: service accounts, client-credentials JWT, app passwords; session revocation |
| `src/home/jellyfin/README.md`, `INSTALL.md` | published without the gate; Quick Connect for friends and family; what is closed from outside |
| `src/home/nomad/README.md` | in the DMZ, and why |
| ADR-021 | R1 as amended by D2 |
