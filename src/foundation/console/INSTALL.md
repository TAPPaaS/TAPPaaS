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
that token (and nothing else). Once identity is installed it refuses the token — delete the file:
`rm ~/config/console-setup-token`.

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

## Verify

```bash
./test.sh                                   # the service answers; the route is gated
curl -s http://127.0.0.1:9097/api/v1/status # on the mothership
```
