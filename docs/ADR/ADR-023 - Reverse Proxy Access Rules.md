# ADR-023 — Reverse Proxy Access Rules

| | |
|---|---|
| **Status** | **Proposed** — under review, not implemented. The design is agreed first, then built. |
| **Version** | 0.1 |
| **Date** | 2026-09-14 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Parent** | [ADR-021 — Split-Horizon DNS and Service Reachability](<ADR-021 - Split-Horizon DNS and Service Reachability.md>) — ADR-021 decides *how a caller reaches Caddy*; this ADR decides *what Caddy lets through once it is there* |
| **Closes / addresses** | **#642** (a published route exposes every path of the app) and **#643** (`proxyRoutes` hosts inherit the primary access list) — merged into one design. Builds on **#206** (zones → Caddy access list) and **#597** (`proxyRoutes`). Related: **#419** (an unresolvable zone is a hard error), **#367** (netbird in the default list). |
| **Changelog** | v0.1 — first draft. Documents the Caddy proxy setup as built, merges #642 (paths) and #643 (per-route zones) into one rule model, works two examples, and records the alternatives and issues from the #642/#643 review. |

## Context — how the Caddy proxy works today

### The parts

| Part | Where it runs | Role |
|---|---|---|
| **Caddy** (`os-caddy` plugin) | on the OPNsense firewall | Terminates TLS for every published name and proxies to the service VM. Listens on every firewall interface; internal callers reach it at the DMZ gateway (ADR-021 D2). |
| **os-caddy data model** | OPNsense config | *Domains* → *Handles* → *Access lists*. The plugin renders `/usr/local/etc/caddy/Caddyfile` from a template on every apply. TAPPaaS never writes the Caddyfile itself. |
| **`caddy-manager`** | mothership (`opnsense-controller`) | Drives the os-caddy model through the OPNsense API (`api/caddy/ReverseProxy/*`). |
| **`network:proxy`** | `src/foundation/network/services/proxy/` | Per-module install / update / delete. Reads the module's `network:proxy` config and calls `caddy-manager`. `access-list.sh` holds the zone logic. |
| **`identity:accessControl`** | `src/foundation/identity/services/accessControl/` | Optional Authentik forward-auth. Sets `ForwardAuth=1` on the module's handler. |

### What a module gets

For a module with `dependsOn: network:proxy`, `install-service.sh` creates:

| os-caddy object | Value | Keyed by |
|---|---|---|
| Domain | `proxyDomain` (default `<vmname>.<domain>`); TLS per-service HTTP-01 or the environment's wildcard cert | description `TAPPaaS: <module>` |
| Handle | **one catch-all** (`HandleType: handle`, no `HandlePath`) → `reverse_proxy <vmname>.<zone>.internal:<proxyPort>` | description `TAPPaaS: <module>` |
| Access list | `tappaas-<module>`: the CIDRs of `proxyAllowedZones`, matcher `remote_ip`, answers **403**. Omitted when the list contains `internet`. | name |
| Extra routes (#597) | per `proxyRoutes` entry: domain `<name>.<domain>` + one catch-all handle on the entry's port. **Uses the same access list as the primary.** | description `TAPPaaS: <module>#<name>` |

The access list attaches to the **handle**, never to the domain. `identity:accessControl` finds the handle by exact description and sets `ForwardAuth=1`.

What Caddy renders today for `hass` (`proxyAllowedZones: ["mgmt","home"]`), with names simplified (the plugin uses UUIDs):

```
hass.example.org {
    handle {
        @tappaas-hass { not remote_ip 10.0.0.0/24 10.3.10.0/24 }
        handle @tappaas-hass { respond 403 }
        reverse_proxy hass.srv.internal:8123
    }
}
```

A request goes: DNS → Caddy (TLS) → access list (zone check, 403 if outside) → forward-auth if wired → upstream VM.

### How it got here

| Issue | What it added |
|---|---|
| **#206** | `proxyAllowedZones`: a module-level zone list compiled into one access list. **Zero-trust by default**: unset means internal zones only, never the internet; the literal `internet` removes the restriction. |
| #367, #419 | netbird joins the default list; a zone name that does not resolve is a hard error, not a smaller list. |
| **#597** | `proxyRoutes`: one VM can publish several hostnames on different ports. Each route inherits the primary's TLS, upstream flags **and access list**. |
| **#643** | Reports the consequence of that inheritance: `internet` on one route publishes **every** route of the module. |
| **#642** | Reports the other missing piece: a route is always the **whole** app. There is no path matching, so a single callback path cannot be published on its own. |

### The problem

Some modules have **one** small endpoint that a cloud service must call from the internet, on the same port as a UI that must stay internal:

| Module | Public caller | Endpoint | Must stay internal |
|---|---|---|---|
| `hass` | IFTTT, Netatmo, Withings, OwnTracks, … | `/api/webhook/<id>` (authenticated only by the ID) | login page, REST and WebSocket API |
| `n8n` (placeholder) | Microsoft Graph, GitHub, … | `/webhook/*` | the editor, which holds every stored credential |
| `litellm` | API clients | `/v1/*` | `/ui` and the key-management API |
| a chat bot | Microsoft Bot Framework | `/api/messages` on its **own** port | the admin UI on another port |

The only option today is `proxyAllowedZones: ["internet"]`, which publishes the whole module on every hostname it has.

Humans can reach internal services remotely over the VPN overlay. Cloud services cannot join a VPN; they need a public HTTPS URL. So this gap cannot be closed by telling users to use the VPN.

### What the os-caddy plugin can express

Checked against the plugin's model (`Caddy.xml`) and template (`Config/Caddyfile`) in `opnsense/plugins`, `www/caddy`:

| Capability | Available | Notes |
|---|---|---|
| Path on a handle (`HandlePath`) | yes | one path per handle, must start with `/` |
| `HandleType` | `handle`, `handle_path` | `handle_path` strips the prefix; TAPPaaS needs `handle` (keeps the path) |
| `HandleDirective` | `reverse_proxy`, `redir` | **no `respond`**: a handle cannot just return 403 |
| Access list per handle | yes | `client_ip` / `remote_ip` matcher, **invertible**, optional response code (TAPPaaS uses 403) |
| Forward-auth per handle | yes | `ForwardAuth` is a handle field |
| Render order | path handles first, then catch-all | `render_handles()` |
| Custom Caddyfile snippets | yes | imports `caddy.d/*.global` and `caddy.d/*.conf`, outside the plugin model |
| Method matcher, rate limit | **no** | not in the model |

So the missing `respond` directive is a **plugin limit**, not a Caddy limit. Plain Caddy does it in one line.

## Decision

### D1. One rule model: a route's default zones plus path exceptions

Every route — the primary and each `proxyRoutes` entry — has the same shape:

- **`proxyAllowedZones`** — who may reach the route. The **default** for every path. Unchanged semantics.
- **`proxyAccess`** (new, optional) — a list of **path exceptions**. Each rule gives a set of paths a different zone list.

A request that matches a rule's path gets **that rule's** zones. **Every other path falls back to the route's own `proxyAllowedZones`.**

```json
"network:proxy": {
  "proxyPort": 8123,
  "proxyAllowedZones": ["mgmt", "home"],
  "proxyAccess": [
    { "paths": ["/api/webhook/*"], "zones": ["internet"] }
  ],
  "proxyRoutes": [
    { "name": "…", "port": 1234,
      "proxyAllowedZones": ["…"],
      "proxyAccess": [ { "paths": ["…"], "zones": ["…"] } ] }
  ]
}
```

This merges the two issues. #643 becomes "a `proxyRoutes` entry may set its own `proxyAllowedZones`". #642 becomes "any route may carry `proxyAccess` rules".

**Why the fallback matters.** Other paths fall back to an ordinary access list, which TAPPaaS already produces. So the design needs no "deny everything else" directive from the plugin. That was the open point in #642. It is only needed when an author asks for it explicitly (D3).

Rules can loosen or tighten. Loosen: a webhook path open to `internet` on an internal app. Tighten: `/ui/*` limited to `mgmt` on an app open to wider zones.

### D2. Field reference

**`proxyAllowedZones`** — allowed at module level (primary route) and, new, in each `proxyRoutes` entry.

- In an entry, absent means **inherit the primary's list** (today's behaviour, so no existing config changes).
- Values are zone names plus the literals `internet` (no restriction) and `netbird`, as today. Plus `none` (D3).

**`proxyAccess`** — list of rules, allowed at module level and in each `proxyRoutes` entry. Absent or empty means no exceptions, exactly as today.

| Rule key | Required | Meaning |
|---|---|---|
| `paths` | yes | Caddy path matchers. Each starts with `/`. A trailing `*` is a prefix match; otherwise the match is exact. `/api/webhook/*` matches `/api/webhook/abc`, not `/api/webhook`. |
| `zones` | yes | Same values as `proxyAllowedZones`. `["internet"]` = anyone. |
| `identityGate` | no | Default: inherit the route's forward-auth. Set `false` to serve these paths **without** Authentik, for machine callers that cannot log in. Only meaningful on a module using `identity:accessControl`. |

**Precedence.** When two rules' paths overlap, the **longest path wins** — Caddy's own ordering, not the order in the list. The same path in two rules is a validation error.

**Validation** (install/update refuses, with the reason):

- `paths` empty, or an entry not starting with `/`, or containing whitespace.
- A path of `/` or `/*` in a rule. That is the whole route, so set the route's `proxyAllowedZones` instead.
- `zones` empty, or naming a zone that does not resolve (#419 applies per rule).
- Warn, don't refuse: a rule whose zones equal the route default (no effect). Also a `proxyRoutes` entry that points at the **same port** as the primary, is more open than the primary, and has no `proxyAccess`. That is the #643 trap: it publishes the whole app under a second name.

### D3. `none` — deny all, only when asked

`"proxyAllowedZones": ["none"]` on a route means **no one**, except through its `proxyAccess` rules. It compiles to one shared **inverted** access list (`0.0.0.0/0`, `::/0`, answers 403), which the plugin can already express.

Use it for a hostname that exists only to expose one path, like the n8n webhook host in Example B. `none` inside a rule's `zones` is an error, since a rule that admits no one should simply be deleted.

### D4. How it renders — one handle per path, an access list on every handle

For each route, `network:proxy` creates:

1. **One handle per path** in each rule: `HandleType: handle`, `HandlePath: <path>`, the rule's access list (none for `internet`), `ForwardAuth` per `identityGate`.
2. **One catch-all handle**: no path, the route's own access list, `ForwardAuth` as today.

**Invariant I1 — an access list goes on every handle, never on the domain.** Caddy sorts handles at the same level with path matchers **before** handles with other matchers (`sortRoutes` in `caddyconfig/httpcaddyfile/directives.go`). A domain-level access list is an IP matcher, so a path handle would be tried first and **skip the zone check entirely**. TAPPaaS already attaches lists to handles; this ADR makes that a tested rule.

**Naming** (deterministic, so reconcile can prune):

| Object | Name / description |
|---|---|
| Catch-all handle | `TAPPaaS: <module>` / `TAPPaaS: <module>#<route>` — **unchanged**, so `identity:accessControl` still finds it by exact match |
| Path handle | `TAPPaaS: <module>[#<route>] <path>` |
| Route default list | `tappaas-<module>` (primary, unchanged) / `tappaas-<module>#<route>` |
| Rule list | `tappaas-<module>[#<route>]:<sorted zones joined by +>` — derived from content, so reordering rules does not churn lists |
| Deny-all list | `tappaas-none` (shared) |

Use `#` and `:` as separators, never `-`. A dash collides: module `hass` + route `hooks` and a module named `hass-hooks` would both give `tappaas-hass-hooks`.

**Reconcile** creates missing objects, updates changed ones, and **prunes** path handles and access lists that are no longer declared. Pruning uses the module's description/name prefix. `caddy-manager` gains the two missing verbs: prune handles by description prefix, and prune access lists by name prefix. `delete-service.sh` removes all of them.

### D5. What does not change

- **ADR-021 R1 holds.** Caddy stays in every path, TLS still terminates there, and DNS is untouched.
- **ADR-021's model holds.** Identity is the gate for people. Zone lists are the coarse public/internal split. This ADR makes that split **per path** because machine callers cannot pass an identity gate. Do not use path rules to separate two groups of *people* (ADR-021 Case 3): that belongs in Authentik.
- **Modules without `proxyAccess`** and routes without their own `proxyAllowedZones` render exactly as today.
- **Change class** (ADR-020): both fields are `in-place`, `apply: reconcile`. `modify --set` is the sanctioned way to change them.

## Examples

Reference-site style addresses: `mgmt` 10.0.0.0/24, `home` 10.3.10.0/24, VMs in `srv`. Matcher names are simplified.

### Example A — Home Assistant: one webhook path public, same hostname

The goal: IFTTT (or Netatmo, Withings, …) must reach `/api/webhook/<id>`. The UI and API stay reachable only from `mgmt` and `home`.

```json
"network:proxy": {
  "proxyPort": 8123,
  "proxyAllowedZones": ["mgmt", "home"],
  "proxyAccess": [
    { "paths": ["/api/webhook/*"], "zones": ["internet"] }
  ]
}
```

Rendered:

```
hass.example.org {
    handle /api/webhook/* {
        reverse_proxy hass.srv.internal:8123              # internet rule: no access list
    }
    handle {
        @tappaas-hass { not remote_ip 10.0.0.0/24 10.3.10.0/24 }
        handle @tappaas-hass { respond 403 }
        reverse_proxy hass.srv.internal:8123
    }
}
```

| Caller | Request | Result |
|---|---|---|
| IFTTT (internet) | `POST /api/webhook/9f3c…` | proxied → automation runs |
| internet | `GET /auth/authorize` | **403** (falls to the catch-all) |
| internet | `GET /api/webhook/../auth/token` | **403** (Caddy cleans the path to `/auth/token` before matching) |
| laptop in `home` | `GET /` | proxied → UI |
| phone on `guest` Wi-Fi | `GET /` | **403** |

Why the same hostname:
- Home Assistant builds webhook URLs from its `external_url`, so the URL it shows the user is already correct.
- No new DNS record or certificate is needed. The hostname is already public, because every published TAPPaaS service needs public DNS for its certificate (ADR-021 R3).

**Home Assistant side:**
- New webhook triggers are *local only* by default. That needs `local_only: false` for the public ones.
- Check how Home Assistant sees the caller's address behind Caddy (`use_x_forwarded_for` / `trusted_proxies`). If it sees only Caddy's address, an internet call looks local, and "local only" protects nothing.

### Example B — n8n: a separate webhook hostname, nothing else on it

The goal: Microsoft Graph (the Teams trigger) posts to `/webhook/…`. The editor, which holds every stored credential, stays internal. The webhook host serves webhooks and nothing else. That also keeps the editor's login page off the public name.

```json
"network:proxy": {
  "proxyPort": 5678,
  "proxyRoutes": [
    { "name": "n8n-hooks", "port": 5678,
      "proxyAllowedZones": ["none"],
      "proxyAccess": [
        { "paths": ["/webhook/*"], "zones": ["internet"] }
      ] }
  ]
}
```

Rendered:

```
n8n.example.org {                                          # primary: internal default zones
    handle {
        @tappaas-n8n { not remote_ip <internal default zone CIDRs> }
        handle @tappaas-n8n { respond 403 }
        reverse_proxy n8n.srv.internal:5678
    }
}

n8n-hooks.example.org {
    handle /webhook/* {
        reverse_proxy n8n.srv.internal:5678                # internet rule: no access list
    }
    handle {
        @tappaas-none { remote_ip 0.0.0.0/0 ::/0 }         # inverted list = matches everyone
        handle @tappaas-none { respond 403 }
        reverse_proxy n8n.srv.internal:5678                # never reached
    }
}
```

| Caller | Request | Result |
|---|---|---|
| Microsoft Graph | `POST n8n-hooks…/webhook/…` | proxied |
| anyone, any zone | `GET n8n-hooks…/` (editor) | **403** |
| laptop in `home` | `GET n8n…/` | proxied → editor |
| internet | `GET n8n…/` | **403** |

**n8n side:** `N8N_WEBHOOK_URL=https://n8n-hooks.example.org/`, so n8n puts the hooks hostname in the webhook URLs it registers with Graph.

**Variant — callback on its own port.** When the app already serves the callback on a separate port, no path rule is needed. Only the per-route zone list is (the pure #643 case). Example: a Teams bot on `3978`:

```json
"proxyPort": 8080,
"proxyRoutes": [ { "name": "bot", "port": 3978, "proxyAllowedZones": ["internet"] } ]
```

## Alternatives considered

| # | Alternative | Verdict |
|---|---|---|
| A1 | **Status quo** — `proxyAllowedZones: ["internet"]` on the module. | Rejected. Publishes the login page, the whole API and every other hostname of the module to fix a single webhook. |
| A2 | **#642 and #643 as filed** — flat `proxyPaths` + per-route `proxyAllowedZones`; unlisted paths get 403 for everyone. | Folded in, not adopted as-is. It works, but always needs a second hostname, and its "403 for the rest" needs a directive the plugin lacks. D1 gives the same result, with `none` (D3) as the explicit form of A2's fallback. |
| A3 | **App-native separate port** — the app serves callbacks on their own listener. | Preferred **where the app offers it** (n8n's webhook processors in queue mode, a bot on 3978). That is D2's per-route zones with no path rules. **Home Assistant offers no second port** (one `server_port`), so it cannot cover the main case. |
| A4 | **A separate proxy or sidecar on another port** in front of the app. | Rejected. The app has one entrance, so something still has to filter by path. This just moves the filter to a box TAPPaaS does not manage. |
| A5 | **Bypass the plugin** — write Caddy config directly. | Rejected as the main path, kept as an escape hatch. The **admin API** (`localhost:2019`) is in-memory and wiped by the next plugin apply, which TAPPaaS triggers on every module install. **`caddy.d/*.conf`** survives reloads but can only add **whole new sites**: repeating a plugin-managed hostname is a Caddy error. It also needs SSH/file access on the firewall (TAPPaaS uses only the API today), is invisible in the GUI and config backup, and one syntax error takes down every published name. |
| A6 | **Contribute `respond` (and a method matcher) to os-caddy.** | Worth doing in parallel; not a dependency. It would replace D3's inverted-list trick with a plain `respond 403`. |
| A7 | **Relay** — the call lands on a relay that forwards it over an outbound connection (Nabu Casa Cloudhooks), or on a self-hosted receiver that calls the app internally. | Strongest isolation: the app is never published. Out of scope: a bigger design, and the public attack surface moves to the relay. Home Assistant's own cloud does it this way, which confirms the need is real. |
| A8 | **VPN only.** | Right for people, not a solution for cloud callers, which cannot join the overlay. |

## Consequences

**Good**

- A module can publish exactly the endpoint a cloud service needs, instead of the whole application. For `hass` that means one webhook path instead of the login page and full API.
- One model for both issues: every route has default zones plus path exceptions.
- The fallback is an ordinary access list, so the design needs nothing new from the os-caddy plugin. It uses handle paths, per-handle access lists, inverted lists and per-handle forward-auth, all of which exist today.
- Fully backward compatible: absent fields render exactly as today.
- Path filtering here is routine proxy routing, not deep inspection. It reads the request path next to the Host header Caddy already routes on.

**Costs and risks**

| Risk | Mitigation |
|---|---|
| **Reachable is not authorized.** A public webhook is protected only by the app: a secret ID in the URL, or a signed request. The URL can end up in the provider's logs. There's no MFA, no rotation, and failed guesses don't lock anyone out. A user-chosen ID like `garage_open` is guessable. | Document per module: use generated IDs, never wire locks or doors to a bare webhook, and have the automation check the payload. The proxy narrows *what* is exposed; it does not authenticate. |
| **No rate limiting and no method filter.** os-caddy has neither. | Accept for now; A6 upstream. Home Assistant's own `allowed_methods` limits webhook triggers to POST/PUT. |
| **Proxy and app read a path differently** (encoded `..`, `%2F`, double slashes). | Caddy cleans the path before matching, so tricks land outside the rule and get the route default. `test-service.sh` must prove it with encoded and `..` paths. |
| **Domain-level access list skipped by path handles** (Caddy sort order). | Invariant I1, with a test that no TAPPaaS domain carries an access list. |
| **Forward-auth on a machine path** would lock out the caller. **Forward-auth missing on the catch-all** would expose the app. | `identityGate: false` is explicit per rule. `identity:accessControl` keeps targeting the catch-all by exact description. Tests assert both. |
| **Same-port second hostname** (#643 used without #642) publishes the whole app under another name. | D2 validation warning. |
| **More objects per module** — more handles and access lists, and more chances for a bad write. One bad handle stopped all 23 published names for about two hours on 2026-09-06. | #589's post-write service check stays in force. Reconcile prunes by prefix, so undeclared objects do not linger. |
| **Home Assistant "local only" webhooks** behave differently behind a proxy. | Called out in the `hass` docs (Example A). |

## Implementation plan

| Phase | Scope | Candidate release |
|---|---|---|
| **P1** | Per-route `proxyAllowedZones` (the #643 part): `access-list.sh` takes the zone list and list name as arguments; `proxy_add_routes` resolves each entry's own list; `delete-service.sh` and a new `caddy-manager` prune verb clean up. About 100–150 lines, reuses existing code. | 2.0 if still open, else early 2.1 |
| **P2** | `proxyAccess` path rules, `none`, `identityGate`: `caddy-manager add-handler --path` sets `HandlePath`; handles keyed by description + path; path-handle and access-list pruning; update-service's compare-and-recreate covers the handle set. | 2.1 |
| **P3** | D2 validation, docs (below), `hass` and `litellm` INSTALL guidance. | with P2 |

**Before P2 starts:** on the test system, create one path handle and one inverted deny-all list by hand. Read the generated `/usr/local/etc/caddy/Caddyfile` and run `caddy validate`. This confirms D3 and I1 against the real plugin, not the template as read.

## Testing

- **Unit (fast):**
  - `test_caddy_manager.py`: the handle payload carries `HandlePath` and `HandleType: handle`.
  - Rule compilation as a pure function: rules → handles and access lists, including longest-path precedence, `internet` → no list, and `none` → the shared inverted list.
  - Naming: no collision between `hass#hooks` and `hass-hooks`.
- **Validation (fast):** every refusal and warning in D2, one case each.
- **Invariant I1:** after install, no TAPPaaS domain carries an access list, and every handle of a zone-restricted route does.
- **`test-service.sh` (deep):** from an allowed and a disallowed source:
  - a listed path is proxied;
  - an unlisted path gets the route default;
  - on a `none` route, an unlisted path gets 403 from everywhere;
  - encoded and `..` variants of a listed path do not reach an unlisted one;
  - on a forward-auth module, an `identityGate: false` path answers without Authentik while `/` still redirects to it.

## Documentation impact (ADR-013)

| Document | Change |
|---|---|
| `services/proxy/fields.json` → regenerated `README.md` | `proxyAccess`; `proxyAllowedZones` allowed in `proxyRoutes` entries; `none`; the `proxyRoutes` note stops saying routes always inherit the access list |
| `src/foundation/network/DESIGN.md` | handle layout, invariant I1, naming and pruning |
| `src/apps/hass/INSTALL.md` | publishing webhooks only (Example A), `local_only`, trusted proxies |
| `src/apps/litellm/INSTALL.md` | "publish to the internet" can publish `/v1/*` without `/ui` |
| `docs/ADR/README.md` | index row |

## Open questions

1. **Does the plugin render D3 and I1 as read?** Settled by the pre-P2 check above. Accept this ADR only after that.
2. **Is `none` needed, or is fallback-to-default always enough?** Example B argues for it. Without it, internal users could also open the n8n editor through the hooks hostname: harmless, but surprising.
3. **Should `identityGate: false` need a second confirmation** (for example a warning on every install) because it removes the identity gate ADR-021 relies on?
4. **Upstream contribution to os-caddy** (A6): `respond`, a method matcher, rate limiting. Who files it, and when?
5. **Release split:** P1 in 2.0 and P2 in 2.1, or both in 2.1?
