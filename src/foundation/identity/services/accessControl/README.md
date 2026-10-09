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
`identity-manager`: members of `users` by default.

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

`identity:accessControl` declares no fields.
