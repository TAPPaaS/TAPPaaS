# network:proxy service

Publishes a module through **Caddy** — the module's public face. It owns the
hostname, the certificate, the upstream handler and the firewall alias that
decides who may reach it. Nothing here touches a guest; the changes land on the
proxy and the firewall, and the workload never notices.

9 fields — all `in-place`, all `apply: "reconcile"`.

The module's public face. Nothing here touches a guest: the changes land on Caddy
and the firewall, and the workload never notices.
*The largest drift blind spot — see [recommendation 1](../../../tappaas-cicd/UPDATE-POLICY.md#1-give-networkproxy-a-reporter).*

## Why `reconcile` and not `set`

`update-service.sh` rewrites this module's whole Caddy site block and its OPNsense
alias from the declared values on every pass, then reloads. That is already
idempotent and already handles removal — a handler that should no longer exist is
deleted, which no scalar field diff can express. Flattening it into `set` fields
would lose that. The manifest declares the class, which is what makes `--set`
sanctioned; the apply stays where the domain knowledge is.

Because there is no `report-service.sh`, `module-manager module drift` reports
these fields as `not-reported` rather than comparing them — the converge is
trusted to have made config true. That is the blind spot recommendation 1 closes.

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`network:proxy` owns **9** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `proxyDomain`

Public domain name for the reverse proxy. Caddy obtains a TLS certificate for this domain.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `<vmname>.<tappaas.domain>` |
| Format | `^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$` |
| Example | `vaultwarden.test.tapaas.org` |
| Required by | *(none)* |
| Used by | `network:proxy` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** If not set, defaults to <vmname>.<domain> from configuration.json

**Why this change class.** The public hostname. Changing it re-issues the ACME certificate and moves the handler; the module itself is untouched, so no guest downtime — though clients on the old name stop resolving as soon as DNS follows.

### `proxyPort`

Target port on the module VM that the reverse proxy forwards traffic to

| Attribute | Value |
|---|---|
| Type | `integer` |
| Default | `80` |
| Minimum | `1` |
| Maximum | `65535` |
| Example | `8080` |
| Required by | *(none)* |
| Used by | `network:proxy` |
| Change class | `in-place` |
| Apply mode | `reconcile` |
| Normalizer | `integer` |

**About the field.** The port the service listens on inside the VM

**Why this change class.** The upstream port Caddy forwards to. A handler rewrite, applied live.

### `proxyUpstreamTls`

Reverse-proxy to an HTTPS upstream instead of plain HTTP. Set true for backends that only speak TLS — e.g. the OPNsense GUI on :8443. network:proxy renders the Caddy upstream as https:// with upstream certificate verification skipped (internal/self-signed backends).

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `false` |
| Allowed values | `true` — Upstream is HTTPS (skip upstream cert verification)<br>`false` — Upstream is plain HTTP (default) |
| Required by | *(none)* |
| Used by | `network:proxy` |
| Change class | `in-place` |
| Apply mode | `reconcile` |
| Normalizer | `boolean` |

**Why this change class.** Whether the hop from Caddy to the module is itself TLS. Declared as a string in module-fields.json, so the boolean normalizer is what makes 'true' and true one value.

### `proxyUpstreamHttp1`

Force HTTP/1.1 to the upstream (os-caddy HttpVersion=http1). Required for apps whose UI rides a WebSocket behind a TLS upstream — e.g. the UniFi OS console. Without it, Caddy negotiates HTTP/2 with the upstream, which cannot carry a WebSocket Upgrade and returns 500, so the SPA renders blank (issue #339).

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `false` |
| Allowed values | `true` — Force HTTP/1.1 to the upstream (WebSocket support)<br>`false` — Default upstream HTTP versions (HTTP/1.1 + HTTP/2) |
| Required by | *(none)* |
| Used by | `network:proxy` |
| Change class | `in-place` |
| Apply mode | `reconcile` |
| Normalizer | `boolean` |

**Why this change class.** Force HTTP/1.1 upstream, for a backend that cannot speak h2c.

### `proxyPreserveHost`

Force the upstream Host header to the public domain (Caddy header_up Host <domain>). Needed for apps that validate a WebSocket's Origin against the Host header — e.g. the UniFi OS console: Caddy otherwise sends the upstream's own hostname, so the browser's Origin (the public domain) ≠ Host and the WebSocket upgrade returns 500, leaving the SPA blank after login (issue #339). Usually paired with proxyUpstreamHttp1 for WebSocket apps behind a TLS upstream.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `false` |
| Allowed values | `true` — Send Host: <domain> upstream (WebSocket Origin check)<br>`false` — Caddy default upstream Host |
| Required by | *(none)* |
| Used by | `network:proxy` |
| Change class | `in-place` |
| Apply mode | `reconcile` |
| Normalizer | `boolean` |

**Why this change class.** Pass the original Host header through, for a backend that generates absolute URLs from it.

### `proxyTls`

How network:proxy obtains the public TLS certificate for this domain. OMIT IT to inherit the environment's domains.dnsMode (config/environments/<env>.json) — that is the normal case and the only way one setting governs a whole environment. Set it only to override that environment-wide choice for this one module. 'dns01' binds the TAPPaaS-wide wildcard certificate issued by os-acme-client (acme-setup.sh, issue #254) via Caddy's per-domain CustomCertificate, and requires a DNS provider that supports DNS-01 plus the wildcard already being in OPNsense Trust; until it is, the public HTTPS endpoint has no cert while the LAN endpoint still works. 'http01' uses classic ACME HTTP-01: Caddy obtains a per-domain cert via the :80 challenge, so the domain MUST be reachable from the internet on port 80, and no DNS API is needed.

| Attribute | Value |
|---|---|
| Type | `string` |
| Allowed values | `dns01` — Wildcard certificate via os-acme-client; bound by refid through Caddy CustomCertificate (no per-module ACME, w<br>`http01` — Per-domain ACME HTTP-01 via Caddy itself (no DNS-API needed, but the domain must be reachable from the interne |
| Required by | *(none)* |
| Used by | `network:proxy` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**Why this change class.** Which certificate strategy serves the domain (per-service or the environment wildcard).

### `proxyAllowedZones`

Zones (and the literal 'internet') permitted to reach this service through the reverse proxy (issue #206). network:proxy compiles this into an os-caddy access list (allow-list by client subnet) attached to the handler; non-matching clients get HTTP 403.

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | <internal default: every Active 'Service' zone plus home, work and mgmt — NOT the internet> |
| Example | `mgmt`, `home`, `work`, `srvHome`, `srvWork` |
| Required by | *(none)* |
| Used by | `network:proxy` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Zero-trust by default: when omitted, a service is reachable only from the internal trusted zones, never the internet. Add 'internet' to publish it publicly (no restriction). Zone names are resolved to subnets via zones.json. Changing this re-applies on the next install/update of the module.

**Why this change class.** Which zones may reach the published name — the difference between an internal service and one exposed to the internet. A live firewall/Caddy change, and the field most worth being able to set through a verb rather than by hand.

### `firewallType`

Type of firewall in use. Set to 'NONE' when the TAPPaaS OPNsense firewall is not deployed (e.g. using pfSense, UniFi, Cisco, or no firewall).

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `opnsense` |
| Allowed values | `opnsense` — TAPPaaS-managed OPNsense firewall (default)<br>`NONE` — No TAPPaaS firewall — manual reverse proxy and firewall rule configuration required |
| Example | `NONE` |
| Required by | *(none)* |
| Used by | `network:proxy` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** When set to 'NONE', network:proxy prints manual configuration instructions instead of calling caddy-manager

**Why this change class.** Which firewall implementation serves this estate. 'NONE' makes the service print manual instructions instead of calling a controller; that branch is the non-field logic update-service.sh keeps.

### `aliasType`

OPNsense alias type for the module's firewall alias (tappaas_module_<vmname>). 'host' (default) targets the FQDN <vmname>.<zone0>.internal resolved via Unbound/dnsmasq. 'network' targets the entire zone0 subnet from zones.json — use for modules representing multiple devices with no single resolvable hostname (e.g. an IoT speaker fleet, a set of physical appliances).

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `host` |
| Allowed values | `host` — Host alias → <vmname>.<zone0>.internal FQDN (default, single-VM modules)<br>`network` — Network alias → zone0 subnet CIDR from zones.json (multi-device modules) |
| Example | `network` |
| Required by | *(none)* |
| Used by | `network:proxy` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** When 'network', the alias content is derived from the zone0 subnet — no separate field is needed. The module's zone0 must define an 'ip' (subnet) in zones.json.

**Why this change class.** How the module is addressed in the generated firewall alias (host vs network).

<!-- END GENERATED FIELDS -->
