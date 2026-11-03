# identity:accessControl service

Single sign-on in front of a published module: Authentik forward-auth on the module's
reverse-proxy route, so a request has to log in before it reaches the app (#45).

## What a consumer gets

- **An Authentik application for the module** — a Proxy Provider and an Application,
  attached to Authentik's embedded outpost, with the `users` group bound to it. The
  binding is the gate: Authentik lets every user through an application with no
  binding (#805).
- **Forward-auth on its route**: the Caddy handler that `network:proxy` created for the
  module is switched to forward-auth, so an unauthenticated request is redirected
  through Authentik. The global Authentik endpoint and the headers Caddy passes on are
  set up once, by the identity module's own install.
- **Delete** removes the Application and the Provider. The Caddy handler is left to
  `network:proxy`, whose delete removes the whole route.

## How to use it

List it **after** `network:proxy` — it layers onto the route that service creates:

```json
"dependsOn": ["network:proxy", "identity:accessControl"]
```

Who may log in to the app is decided by Authentik's groups and policies, managed with
`identity-manager`: members of `users` by default, or the groups in the module's `gateGroups`.

A module that also declares `identity:identity` keeps both (the ADR-006 §4 exception,
#806): its OIDC app holds the slug `<module>` and is the tile, and the gate becomes
`<module>-gate`, hidden from Authentik's app list. A proxy app left under `<module>`
from before is removed on the next update. List `identity:identity` after
`identity:accessControl`.

Forward-auth gates the public name only. Native clients that log in to the app's own
API (TV and mobile apps) cannot pass it; they need a route that does not go through
the proxy, such as the module's `<vmname>.<zone>.internal` address.

## Test

`test-service.sh` checks four things:
- the proxy application exists, and its provider is on the embedded outpost;
- the application has a group binding;
- the module's Caddy handler has ForwardAuth on;
- an anonymous request to the public URL gets the Authentik login.

A 403 from the module's zone filter hides that last check from cicd. It is reported
as a warning, not a failure.

## Fields

| Field | What it does |
|---|---|
| `gateGroups` | The Authentik groups whose members pass the gate. Unset: `users`, added to whatever else is bound. Set: exactly these groups (others are unbound; a service account's binding stays). NOMAD sets `["admin"]`: its Command Center starts containers. |

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`identity:accessControl` owns **1** declared field(s). Each table below carries the field's full definition and, where the service applies it, what a change to it does (in place, a restart, a rebuild).

### `gateGroups`

The Authentik groups whose members pass the module's gate. Unset: the team group `users` is bound, and other bindings an operator made on the gate's application are left as they are. Set: exactly these groups are bound — a binding to any other group is removed, a binding to a user (a service account) stays.

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | `<unset: users, additive>` |
| Example | `admin` |
| Required by | *(none)* |
| Used by | `identity:accessControl` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** A role reaches Authentik as a group of the same name (identity/USERS.md), so `admin` is everyone with the admin role. Use it for a module whose UI can change the machine it runs on (NOMAD's Command Center starts containers).

**Why this change class.** Who may sign in to the module. Applied on the module's next update; members of a group that is no longer bound are refused at the gate from then on.

<!-- END GENERATED FIELDS -->
