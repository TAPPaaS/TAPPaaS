# Netbird Setup — TAPPaaS Network Access

Netbird is a WireGuard-based mesh VPN. Each peer establishes encrypted
tunnels directly to other peers. For TAPPaaS, Netbird gives administrators
secure remote access to all TAPPaaS zones and automatic DNS resolution of
`*.internal` hostnames.

OPNsense acts as the **routing peer**: it has an interface on every zone
and forwards traffic from Netbird peers into any zone they need to reach.

All TAPPaaS zones use `10.0.0.0/8` address space, so a single Netbird
network resource covers every zone. OPNsense already routes to each zone —
Netbird only needs to send all `10.x.x.x` traffic through OPNsense.

> Zone subnets and DNS suffixes are defined in `zones.json`.

> **Note:** OPNsense has a native Netbird plugin (`os-netbird`) that can
> replace the manual peer setup. DNS sync from `zones.json` via
> `opnsense-controller` is planned. See tracking issue.

---

## 1. Groups

Create these groups once — they are reused for everything.

**TAPPaaS Gateways**
Add the OPNsense peer. Must contain only peers, not network resources.

**Admins**
Add all administrator laptops and desktops.

---

## 2. TAPPaaS Internal Network

In **app.netbird.io → Networks**:

- Name: `TAPPaaS Internal`
- Resource address: `10.0.0.0/8`

> **Note:** For standard TAPPaaS deployments where services are exposed
> via Caddy, `10.0.0.0/24` (mgmt only) is sufficient. Use `10.0.0.0/8`
> only if direct IP access to non-mgmt zones is required.

- Routing Peer: OPNsense peer (masquerade: **on**)
- Access Groups: `Admins`

> Masquerade ensures hosts in every zone see traffic from OPNsense's own
> IP on that interface — no return routes needed on any host.

---

## 3. DNS Nameserver

In **app.netbird.io → DNS → Nameservers**:

- Name: `TAPPaaS OPNsense DNS`
- Nameserver: `10.0.0.1`, port `53`
- Distribution Groups: `Admins`

Add a single **Match Domain**: `internal`

> This covers all TAPPaaS zones now and future.
> No manual sync with `zones.json` needed when zones are added.

> Port `53` is used — not the Netbird default of `53053`.
> OPNsense uses Dnsmasq (not Unbound) as the DNS resolver.

---

## 4. Access Control Policies

Two policies are required. They cannot be merged.

### TAPPaaS Admin ↔ Gateway

Allows OPNsense to reply to admin peers — for DNS responses and return
traffic from any zone.

- Source: `Admins`
- Destination: `TAPPaaS Gateways`
- Bidirectional: **on**
- Protocol: All

> Without this policy, DNS probes time out. Netbird marks the nameserver
> as unavailable and does not configure split DNS on the client.

### TAPPaaS Internal Access

Allows admin peers to use the `TAPPaaS Internal` network route.

- Source: `Admins`
- Destination: `TAPPaaS Internal` (`10.0.0.0/8`)
- Bidirectional: **off**
- Protocol: All

---

## 5. Reaching Caddy-proxied services

Services published through Caddy (the OPNsense reverse proxy) are guarded by
per-zone IP access lists built from `zones.json` CIDRs. NetBird peers need one
extra consideration here.

> **Source-IP limitation.** The routing peer's **masquerade only rewrites
> traffic it *forwards* to another host.** Caddy runs **on OPNsense itself**, so
> a request to a proxied service *terminates on OPNsense's own interface* — there
> is no forwarding hop to masquerade. Caddy therefore sees the peer's real
> NetBird source (e.g. `100.70.x.x`), not a `10.x` zone IP. (Outbound NAT does
> not help either: it rewrites traffic *leaving* an interface, and this traffic
> is locally delivered.)

TAPPaaS handles this with a **`netbird` overlay zone** in `zones.json`
(`ip: 100.64.0.0/10`, `state: Manual`, `vlantag: 0` — no interface/DHCP/rules).
`access-list.sh` resolves it like any other zone and includes it in the default
internal allow-set, so tunnel peers are admitted alongside `mgmt`. Per-peer
authorization stays with NetBird's own access policies (only `Admins` get the
route to OPNsense), so allowing the whole overlay CIDR at Caddy is safe.

> **Default CIDR.** `100.64.0.0/10` is NetBird's full CGNAT allocation range, so
> it covers any sub-range the management server assigns (e.g. `100.70.0.0/16`)
> with no per-deployment tuning. Narrow it only if you deliberately restrict
> NetBird to a smaller network; peers assigned outside the configured CIDR are
> 403'd again.

> A service that overrides `proxyAllowedZones` to a narrow list (e.g.
> `["mgmt"]`) must add `"netbird"` to keep tunnel access — the default-include
> only applies when `proxyAllowedZones` is absent.

If you prefer not to expose proxied services to the overlay at all, the
operator workaround is to reach them from a wired LAN (mgmt) connection instead.

---

## Result

After setup, an admin peer connecting to Netbird automatically receives:

- A route for `10.0.0.0/8` via OPNsense (all TAPPaaS zones)
- Split DNS for each `*.internal` domain pointing to OPNsense
- Full access to all hosts by hostname or IP

When a new zone is activated in `zones.json`, add its domain to the
Netbird nameserver. No other Netbird changes are needed.
