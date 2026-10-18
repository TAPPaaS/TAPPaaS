# console — Installation

Primary audience: TAPPaaS admin.

The console **service** comes with the mothership: `tappaas-cicd.nix` declares
`tappaas-console.service`, and the control-plane refresh builds `~/bin/console`
(`tappaas-cicd/ui/install.sh`); the service starts as soon as the bin exists. A fresh install
therefore ends with the console up on the mothership's `mgmt` address, port 9097.

## Before identity exists (ADR-034 D10)

`bootstrap.sh` writes a one-time token to `~/config/console-setup-token`, and the summary of
`tappaas-cicd/install.sh` prints the address and names that file — never the token, so it
reaches no log. Read it on the mothership and paste it into the console's token form (or
open the address with `?token=<token>` once):

```
http://<tappaas-cicd mgmt address>:9097/
cat ~/config/console-setup-token
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

## The assistant (ADR-034 D7)

The console integrates `litellm:models` (optional). With the AI stack installed, registering or
updating the module provisions the console's virtual key the way Open WebUI gets one: LiteLLM
keeps it as `litellm-svc-tappaas-cicd`, and `/etc/secrets/litellm-svckey.env` on the mothership
holds it with LiteLLM's address. Installed in the other order, `module-manager update console`
(or LiteLLM's own install, which wires pre-existing integrators) provisions it. The console
reads it within half a minute; no restart.

```bash
curl -s http://127.0.0.1:9097/api/v1/assistant/status   # available, the model, or why not
tappaas ask "what needs a person today?"
```

What it needs: the key above; TCP 4000 from the mothership to LiteLLM (mgmt reaches every zone,
so no pinhole is written; `rules-manager expected-pinholes console --for litellm:models` shows
why); a model LiteLLM offers the key (`console.json` `assistantModel` pins one, else LiteLLM's
`default`, else the first listed). The logs tool uses Loki's admin credential the mothership
already holds (`~/.loki-admin-password`). It sees what the console sees (the reads, Activity,
a host's logs, the managers' help and READMEs) and changes nothing: a proposal is a card the
operator previews and runs. Conversations stay in `/var/lib/tappaas/console/assistant/`.

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
