# Authentik 2025.2.1 → 2026.8.3 (#748) — investigation and plan

*Investigated 2026-10-03 on hrossen. Sources: upstream upgrade guide, per-line release notes
and the GitHub security advisories (links at the end).*

## Where we are

`identity.nix` pins `authentik = "2025.2.1"` (set 2026-02-21), two Podman containers
(`ghcr.io/goauthentik/server`, `server` + `worker`), PostgreSQL 16.15 and Redis from NixOS,
configured by `/etc/secrets/authentik.env` — written **once**, on first boot.

What hrossen holds: 5 applications (identity, litellm, nextcloud, openwebui, logging) on
5 OAuth2 providers — 3 plain OIDC, 2 forward-auth through the **embedded proxy outpost**;
one custom flow (`tappaas-recovery`); 8 groups, none with a parent, no duplicate names;
2 API tokens; no LDAP, SAML or external sources. Database: 84 MB, 5 users.

## Why it matters now

2025.2 is end of life. Every advisory published since applies to us. The ones that touch
what we run (all fixed in 2026.8.3):

| Advisory | Severity | What |
|---|---|---|
| CVE-2026-25227 | **Critical** | authenticated RCE through the policy/property-mapping test endpoint |
| CVE-2026-42849 | **Critical** | reflected XSS |
| CVE-2026-25748 | High | forward-auth bypass with a malformed cookie on **Caddy** (our proxy) |
| CVE-2026-40166 | High | a non-admin can read an OAuth `client_secret` |
| CVE-2026-40172 | High | superuser group assignment through a user PATCH |
| GHSA-3wf5-rj6w-7527 | High | OAuth2 redirect-URI poisoning |
| CVE-2025-29928 | High | deleting a session did not revoke it |
| CVE-2026-94609 / -94611 / -94606 | High | delegated-management escalation; credentials readable with view permission; email-MFA bypass |
| CVE-2025-64521 | Medium | a deactivated service account can still authenticate |

## The path: nine hops, no skipping, no way back

Upstream: never skip a release line (2026.8 now **refuses** an unsupported skip before it
migrates), move to each line's latest patch first, and there is **no downgrade** — the way
back is a database backup. So:

**2025.2.4 → 2025.4.4 → 2025.6.4 → 2025.8.6 → 2025.10.4 → 2025.12.6 → 2026.2.7 → 2026.5.7 → 2026.8.3**

Each hop: `pg_dump`, move the pin, rebuild, wait for the worker to finish its migrations,
`module test identity --deep` and an SSO login through each of the five applications.
Rollback at any hop: restore the VM snapshot `module update` takes (it holds the database),
or the dump into the previous version.

## What each hop needs from us

| Hop | Needs | Our side |
|---|---|---|
| 2025.4 | sessions move into the database: everyone logs in once | nothing |
| 2025.6 | theming may render differently | look at `tappaas-recovery` |
| 2025.8 | worker Celery → Dramatiq; upgrade the server before the worker | our two containers restart together — acceptable at our load (upstream: a few lost tasks) |
| 2025.10 | **Redis no longer used**; ~50 % more PostgreSQL connections; OAuth `email_verified` defaults to **false** | drop `AUTHENTIK_REDIS__*` and the Redis server (after this hop, not before); `max_connections = 100` is ample for 5 apps; **test login on litellm, nextcloud, openwebui** — add an `email_verified` mapping only if one refuses |
| 2025.12 | **groups `parent` → `parents` (many-to-many)**; group names unique; files under `/data` | `authentik_manager.py` `group_ensure` sends `"parent"` → send `"parents": [pk]`; `authentik_cli.py` prints `parent`; **volumes** `/var/lib/authentik/media:/media` → `…:/data/media` (and `/data` mount); no duplicate names on hrossen |
| 2026.2 | `User.ak_groups` deprecated for `User.groups` | the `groups` claim expression in `identity/services/identity/install-service.sh` and the comment in `nextcloud.nix` |
| 2026.5 | default listen `[::]` | check the guest has IPv6 enabled on loopback (it does: NetworkManager `ipv6 auto`) |
| 2026.8 | forwarded headers only from trusted CIDRs (default includes 10/8); new `AUTHENTIK_WEB__BASE_URL` (required in 2026.11) | Caddy on the firewall is 10.0.0.1 — inside the default; **set the base URL now** |

Not used by us, so not affected: the removed `admin/metrics`, `admin/workers`, `set_icon`,
`set_background`, `rbac/permissions/users`, `flows/instances/import` endpoints;
`private_key_type`; `blank://blank` launch URLs; PostgreSQL stays fine (upstream supports 14–18).

## One thing in our module that blocks this regardless

`/etc/secrets/authentik.env` is generated once (`ConditionPathExists = !…`). Removing the
Redis settings or adding `AUTHENTIK_WEB__BASE_URL` in `identity.nix` would reach a **new**
install only. The settings that change between versions belong in the container's
`environment` (declarative, rebuilt every update); the env file keeps only the secrets.

## How to carry it out

**Built 2026-10-03** (prerequisite + step mechanism; the hops themselves not yet run):
`identity/ak-step.nix` takes the version the guest runs (`/var/lib/authentik/tappaas-version`,
or 2025.2.1 for a guest from before it) and builds the next step; a fresh install goes to the
target. `identity.nix` builds `ak.version`, keeps Redis and the `/media` mount while the step
needs them, declares the settings (`akEnv`) and strips them from the env file on existing
guests; `authentik-version-record` writes the version only once the server runs that image
and answers ready; `authentik-step-precheck` (hourly) finds duplicate group names, and the
step into 2025.12 is then refused at evaluation, before anything changes. The controller
sends `parents` from 2025.12 on, `parent` before. Tested: 20 step cases; a dry build on
hrossen's guest computes **2025.2.4** as its first step. Still to do with the hops: the
`groups` claim (2026.2) and the base URL (2026.8).

The same shape as Nextcloud's walk (#709, `nc-major.nix`): the module steps **one release
line per update**, each step a normal `module update` with its snapshot and tests — so the
sweep can carry an estate forward and a failure stops at a known version. On hrossen it is
nine updates in one sitting. The code changes above land with the hop that needs them, and
each is backwards compatible for the hops before it (sending `parents` to a 2025.10 server
is the exception — it lands with the 2025.12 step).

Still open after the walk: `AUTHENTIK_WEB__BASE_URL` (required from 2026.11). The
`ak_groups` → `groups` claim expression is done (#794, 2026-10-07);
afterwards #750: the pin is listed where a tripwire can see it, and its age is reported at
each release boundary, so the next lapse is visible.

## Results on hrossen (2026-10-03)

| Hop | Version | Time | Result |
|---|---|---|---|
| 1 | 2025.2.3 | 112 s | ✅ — the first try, **2025.2.4, failed**: ghcr's tag is an arm64-only manifest (every other tag is multi-arch); the x86 guest pulled it and could not execute it. Rolled back by the update's own snapshot (SSO down 16:44–17:08). The step is 2025.2.3; a pre-check now refuses a tag without amd64 |
| 2 | 2025.4.4 | 118 s | ✅ sessions moved into the database — everyone logged in once |
| 3 | 2025.6.4 | 115 s | ✅ |
| 4 | 2025.8.6 | 117 s | ✅ worker on Dramatiq (315 tasks, no errors) |
| 5 | 2025.10.4 | 104 s | ✅ Redis gone; `email_verified` kept true by the TAPPaaS mapping, put on all five providers first |
| 6 | 2025.12.6 | 113 s | ✅ groups → `parents`, media on `/data/media` |
| 7 | **2026.2.7** | 123 s | ✅ — **hrossen runs this**; it fixes every advisory in the table above |
| 8 | 2026.5.7 | 111 s | ✅ after a fix — the first two tries **answered every request with an empty `200`** (login, OIDC, API) and were rolled back. Cause, found in the 2026.5.7 source: the worker is now a Rust binary whose health server binds Authentik's listen address (`:9000`) and answers every other path with an empty 200; with `--network=host` the two containers share the guest's ports, the worker won `:9000`, and the server only warned. Upstream's compose gives each container its own network and never meets it. Fix: the worker listens on `127.0.0.1:9001/9444/9301` (`akWorkerEnv`) |
| 9 | **2026.8.3** | 141 s | ✅ — **the target; hrossen runs it.** The new Rust server owns 9000/9443/9300, the worker its loopback ports, no `failed to listen`; API and `authentik-manager test` answer; forward-auth through Caddy redirects to the login flow (2026.8 trusts forwarded headers only from 10/8 &c. — Caddy is 10.0.0.1) |

At each hop: a `pg_dump`, the update's snapshot and tests, then the recorded version, the
running image and readiness compared, each application's OIDC discovery and the outpost
checked, and the identity and logging tests. **The walk is complete: 2025.2.1 → 2026.8.3
in nine hops, ~2 minutes each.** The identity module's test now also asks every OIDC
application for its discovery document and fails on an empty one. Lessons kept in the tooling: check a body, not a status (the empty-200 hop
looked green), and a failed OS switch should stop `module update` at once rather than five
minutes later in `update.sh`.

## Sources

- https://docs.goauthentik.io/install-config/upgrade/
- https://docs.goauthentik.io/releases/ (2025.4 … 2026.8)
- https://github.com/goauthentik/authentik/releases
- https://github.com/goauthentik/authentik/security/advisories
