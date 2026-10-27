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

## How the console knows who is calling

Once identity is installed, every request through the route carries the gate's signed token
(`X-Authentik-Jwt`), next to the `X-Authentik-Username` and `X-Authentik-Groups` headers. The
console verifies the token against the route's Authentik proxy provider: an HS256 signature with
the provider's client secret, the provider's client id as audience, the application's issuer,
and an expiry no more than a minute past. The user and the groups are the token's; a request
from the firewall's address without a valid token is refused (401). The console reads the
provider's key from Authentik with the controllers' credentials
(`~/.authentik-credentials.txt`) and keeps it in memory; only the console's own routes
(`console.<domain>`, `status.<domain>`) are looked up, so a token from another gated app does
not open the console. When Authentik cannot be reached and no key is cached, requests get 503
until it can.

**Remaining risk.** Caddy reaches the console over plain HTTP on `mgmt`. Root on a machine in
`mgmt` that can intercept that traffic (ARP spoofing the firewall's address) can copy a user's
token and replay it until it expires: the provider's token validity, one hour by default. Keep
`mgmt` to TAPPaaS's own machines: no guests placed in `mgmt`, no other devices on `mgmt` switch
ports, and the nodes and `mgmt` guests patched.

## The published face

Register the module once identity is installed. It publishes `console.<domain>` through
Caddy to `mgmt` and the admin VPN only, behind the Authentik gate, with its own certificate
(HTTP-01). The steps in order, with the values of the test site hrossen as the example:

| | hrossen |
|---|---|
| domain | `hrossen.dk` (environment `mgmt`, `dnsMode` `per-service`) |
| WAN addresses | `80.248.138.190`, `2a13:e740:292:978c::aba` |
| mgmt, its gateway (the site's resolver) | `10.0.0.0/24`, `10.0.0.1` |
| DMZ gateway (Caddy, split-horizon answer) | `10.6.0.1`, `2a13:e747:a210:8261:98:34ff:fe69:901a` |
| admin overlay | `10.255.1.0/24` |

### 1. The service on the mothership

The console's code arrives with the release the mothership follows. The next run of
`update-tappaas.service` — the nightly timer, or now with `site-manager update` — pulls it,
builds `~/bin/console` in the control-plane refresh (`ui/install.sh`), and its self-rebuild
(`tappaas-self-rebuild.sh`) activates the NixOS generation that declares
`tappaas-console.path` and `tappaas-console.service`; the path unit starts the service as soon
as the bin exists. On a site where identity is installed the setup token is refused and its
file deleted at the first start. Check:

```bash
systemctl is-active tappaas-console.service
curl -s http://127.0.0.1:9097/api/v1/status | jq -r .data.version
```

The same run updates `identity`, whose `update.sh` creates the `installer` group and puts the
site owner in it.

### 2. Who may log in

The console is for members of the Authentik group `installer`, and only for them. The gate
(`identity:accessControl`) binds the console's application to `installer` alone, so anyone
else is refused at the Authentik login and never reaches the console. Behind the gate the
console checks the group again and answers 403 to a caller outside it, naming the group. An
installer may do everything, destructive verbs included (each behind the object's name typed).
Membership of `admin` or `users` gives no access: `admin` makes someone an admin of the apps,
not an operator of the site, and `users` is everyone with an account. Service accounts follow
the same rule: one in `installer` gets the console, one outside it gets 403, whatever scopes its
token carries. Differentiated roles (a read-only view, a status page for the household) are a
later step.

On a site where the console module is already registered, its next update
(`module-manager update console`) replaces the
binding to `users` with `installer`.

Check that the operator is in `installer` before the first login:

```bash
identity-manager group list --deep          # installer, with the site owner in it
```

If the group is not there, `module-manager update identity` creates it with the site owner in
it. Make another person an installer, or take it away again:

```bash
identity-manager user modify <user> --add-groups installer
identity-manager user modify <user> --remove-groups installer
```

The change reaches Authentik at once (the verb reconciles); the person signs in again to get
a token with the new group.

### 3. The public DNS record

Caddy obtains the certificate by HTTP-01, so `console.<domain>` must resolve publicly to the
WAN: an A record for its IPv4 address and an AAAA for its IPv6 address, or a wildcard
`*.<domain>` doing the same. It is made at the domain's DNS host, by hand. Check against the
authoritative server, and that the WAN passes TCP 80 for the challenge (bootstrap's
`setup-caddy` rules `TAPPaaS: Allow HTTP/HTTPS to Caddy`, IPv4 and IPv6):

```bash
dig +short @"$(dig +short NS <domain> | head -1)" console.<domain> A    # the WAN IPv4
dig +short @"$(dig +short NS <domain> | head -1)" console.<domain> AAAA # the WAN IPv6
```

Inside the site the name answers with the DMZ gateway once the module is added (step 5); it
needs nothing by hand.

### 4. The admin tunnel (#856)

From the admin VPN the console is reached by name only with a tunnel config that carries the
site's DNS and the routes to the DMZ gateway (config v2, `network-manager/ADMIN-VPN.md` §6).
An older tunnel resolves the name publicly and arrives from the internet: it is sent to the
Authentik login, and once signed in it gets 403.

```bash
network-manager wgvpn list                  # each peer's config version
network-manager wgvpn config <peer> [<endpoint:51821>] > tappaas-admin.conf
```

Re-import the re-issued config on the device once. Until then, a hosts-file line on the
device takes the name over the mgmt route the old tunnel has (Caddy answers on the
firewall's mgmt address too); remove it after the re-import:

```
10.0.0.1  console.<domain>
```

### 5. Add the module

```bash
module-manager add console --proxyDomain console.<domain>
```

Before anything is created, the zone references (`mgmt`, `admin`) and the module's own
`check-config.sh` are checked: a zone list with `internet` or `all` is refused, now and on any
later `module-manager modify console --set proxyAllowedZones=…`. Then, nothing on any guest:

- `network:proxy`: a Caddy handler for `console.<domain>` to `tappaas-cicd.mgmt.internal:9097`;
  the access list `tappaas-console`, mgmt's and the admin overlay's networks (and their IPv6
  networks where a zone has one); the split-horizon A record (and AAAA) for the name, pointing
  at the DMZ gateway; the certificate, issued by HTTP-01 on the first request.
- `identity:accessControl`: an Authentik proxy application `console`, bound to `installer`
  only (the module's `gateGroups`), and forward-auth on the handler.
- `litellm:models`, when the AI stack is installed (it is on hrossen): the assistant's key,
  below.

`add` has no dry run. What can be checked first without changing the site: the steps above,
`module-manager validate --blueprint ~/TAPPaaS/src/foundation/console`, and
`./check-config.sh console.json` from the module's directory.

### 6. Verify

```bash
module-manager test console                 # the zone list, the service, its reads, the gated route
systemctl show tappaas-console -p User -p ProtectSystem -p ActiveState   # tappaas, strict, active
dig +short console.<domain>                 # from mgmt or the tunnel: the DMZ gateway
curl -sI https://console.<domain>/          # from mgmt or the tunnel: 302 to the Authentik login
```

From any other zone (`home`, a guest network) or from the internet, the same anonymous request
is redirected to the Authentik login as well, and a signed-in one gets 403 from the access list:
Caddy runs the gate before the access list, so from there the console itself is never reached.
The login page is public anyway. Log in from a browser on mgmt or the tunnel as a member of
`installer`: the header shows the user and role (`installer`), and the *Open in* jumps (Proxmox,
OPNsense, Grafana, PBS, Authentik, UniFi) open the object in view in a new tab.

### Removing it

```bash
module-manager delete console --force
```

`--force` because the console is a foundation module; the module has no VM, so nothing is
destroyed. Its services are taken down in reverse: the Authentik application, the access
list, the Caddy handler and the split-horizon records, and the assistant's LiteLLM key. The
service stays on the mothership, where it accepts only the firewall and loopback, so with no
route it is reached from nowhere else. The public DNS record is yours to remove.

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
./test.sh                                   # the zone list; the service answers; the route is gated
curl -s http://127.0.0.1:9097/api/v1/status # on the mothership
```
