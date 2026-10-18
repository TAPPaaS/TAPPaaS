# console — Installation

Primary audience: TAPPaaS admin.

The console **service** comes with the mothership: `tappaas-cicd.nix` declares
`tappaas-console.service`, and the control-plane refresh builds `~/bin/console`
(`tappaas-cicd/ui/install.sh`); the service starts as soon as the bin exists. A fresh install
therefore ends with the console up on the mothership's `mgmt` address, port 9097.

## Before identity exists (ADR-034 D10)

`bootstrap.sh` writes a one-time token to `~/config/console-setup-token`, and the summary of
`tappaas-cicd/install.sh` prints the address with it:

```
http://<tappaas-cicd mgmt address>:9097/?token=<token>
```

While `config/identity.json` does not exist, the console accepts `mgmt` and the admin VPN with
that token (and nothing else), and serves the **Setup** wizard: the rest of the install from
the records, step by step. Once identity is installed it refuses the token and deletes its file
(after the identity step, and at start).

## The published face

Register the module once identity is installed. The route's name is the module's
`proxyDomain`; give it the console's name for the site's domain:

```bash
module-manager add console --proxyDomain console.<domain>
```

`network:proxy` publishes `console.<domain>` to `mgmt` and `admin` only, upstream
`tappaas-cicd.mgmt.internal:9097`; `identity:accessControl` puts the Authentik gate in front.
Who may log in is Authentik's: members of `users` by default. The console's role table reads the
groups by their TAPPaaS names (ADR-034 D3): `installer` (Installer: every verb), `admin` (the
`admin` role: Admin, no destructive verb) and `users` (read). The identity bootstrap creates
`installer` with the installer in it, and an existing site gets it from `module-manager update
identity`; the installer has the `admin` role already (`identity/USERS.md`).

## The owner's route — `status.<domain>` (not yet declared)

ADR-034 D2 gives the console a second route, `status.<domain>`, from the trusted client zones
of the default environment, gated like the first, on which the backend caps every caller at
read and serves the owner's view (Overview in plain words, Physical, Modules; no actions, no
jumps). The backend side is built. The declaration is not, because of a gap in the proxy:
`proxyRoutes` (ADR-023, #597, `network/services/proxy`) publishes a further name with its own
`proxyAllowedZones`, but **never behind forward-auth** — `identity:accessControl` gates only
the module's primary handler and its `proxyAccess` paths. Declared today, the route would reach
the backend without `X-Authentik-*` headers, and the backend would refuse every request on it
(401: a route without the gate). What it waits for, in `console.json`:

```json
"network:proxy": {
  "proxyPort": 9097,
  "proxyAllowedZones": ["mgmt", "admin"],
  "proxyRoutes": [
    { "name": "status", "port": 9097, "proxyAllowedZones": ["<the default environment's client zones>"] }
  ]
}
```

with `identity:accessControl` (or ADR-032's `proxyAuth: gate` per route) putting the gate in
front of it too. Until then the owner's view can be tried on the mothership with a `Host:
status.<domain>` header through the gate's headers (`console serve --trust-local-headers`,
development only).

## Verify

```bash
./test.sh                                   # the service answers; the route is gated
curl -s http://127.0.0.1:9097/api/v1/status # on the mothership
```
