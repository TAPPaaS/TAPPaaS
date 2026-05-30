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

## Result

After setup, an admin peer connecting to Netbird automatically receives:

- A route for `10.0.0.0/8` via OPNsense (all TAPPaaS zones)
- Split DNS for each `*.internal` domain pointing to OPNsense
- Full access to all hosts by hostname or IP

When a new zone is activated in `zones.json`, add its domain to the
Netbird nameserver. No other Netbird changes are needed.
