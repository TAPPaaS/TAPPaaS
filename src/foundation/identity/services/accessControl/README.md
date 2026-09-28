# identity:accessControl service

Single sign-on in front of a published module: Authentik forward-auth on the module's
reverse-proxy route, so a request has to log in before it reaches the app (#45).

## What a consumer gets

- **An Authentik application for the module** — a Proxy Provider and an Application,
  attached to Authentik's embedded outpost.
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
`identity-manager`.

## Fields

`identity:accessControl` declares no fields.
