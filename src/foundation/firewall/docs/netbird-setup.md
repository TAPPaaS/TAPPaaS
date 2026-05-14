# Netbird Setup — TAPPaaS Network Access

Netbird is a WireGuard-based mesh VPN. Rather than a traditional hub-and-spoke VPN,
each peer establishes encrypted tunnels directly to other peers. For TAPPaaS, we use
Netbird to give administrators secure remote access to all TAPPaaS zones and automatic
DNS resolution of `*.internal` hostnames — without any manual configuration on the
admin's machine.

OPNsense acts as the **routing peer**: as the TAPPaaS firewall and router, it has
an interface on every zone. It forwards traffic from Netbird peers into whichever
zone they need to reach. Think of it as a single secure gateway through which all
internal zones are accessible.

All TAPPaaS zones use `10.0.0.0/8` address space by default, so a single Netbird
Network resource covers every zone simultaneously. OPNsense already knows how to
route to each zone — Netbird just needs to know to send all `10.x.x.x` traffic
through OPNsense.

> Zone subnets and DNS suffixes are defined in `src/foundation/firewall/zones.json`.

---

## 1. Groups

Groups are the foundation for both routing and access control. Create these once —
they are reused for everything.

**TAPPaaS Gateways**
Add the OPNsense peer to this group. It must contain only peers, not network
resources.

**Admins**
Add all administrator laptops/desktops to this group.

---

## 2. TAPPaaS Internal Network

A single Network resource covering `10.0.0.0/8` routes all TAPPaaS zone traffic
through OPNsense. When an admin connects, Netbird installs this route on their
machine automatically.

In **app.netbird.io → Networks**:

- Create a network named `TAPPaaS Internal`
- Add a resource with address `10.0.0.0/8`
- Set the **Routing Peer** to the OPNsense peer (masquerade enabled)
- Set the **Access Groups** to `Admins`

> Masquerade ensures that hosts in every zone see traffic as coming from OPNsense's
> own IP on that zone's interface, so no return routes need to be configured on any
> host.

---

## 3. DNS Nameserver

A single nameserver handles DNS for all TAPPaaS zones. OPNsense's Unbound resolver
is authoritative for every `*.internal` zone.

Netbird automatically configures split DNS on admin machines: queries matching a
registered domain are routed to OPNsense, while all other queries use the system
default. No manual configuration is needed on the client.

In **app.netbird.io → DNS → Nameservers**:

- Create a nameserver named `TAPPaaS OPNsense DNS`
- Add nameserver: OPNsense management IP (default: `10.0.0.1`), port `53`
- Distribution Groups: `Admins`

Add a **Match Domain** for each active zone:

| Zone | Match Domain |
|------|-------------|
| Management | `mgmt.internal` |
| Service | `srv.internal` |
| DMZ | `dmz.internal` |
| Private | `private.internal` |
| IoT | `iot.internal` |

Only add domains for zones that are active in `zones.json`. When a new zone is
activated, add its domain here — no other Netbird changes are needed.

> Port `53` is used — not the Netbird default of `53053`.

---

## 4. Access Control Policies

Two policies are required. They serve distinct purposes and cannot be merged.

### TAPPaaS Admin ↔ Gateway

OPNsense must be able to reply directly back to admin peers — for DNS responses and
for return traffic from hosts in any zone. This bidirectional peer-to-peer policy
enables that.

- Source: `Admins`
- Destination: `TAPPaaS Gateways`
- Bidirectional: **on**
- Protocol: All

This policy is created once and never needs to change.

> Without this policy, DNS probes time out — OPNsense receives the query but its
> reply is blocked. Netbird marks the nameserver as unavailable and does not
> configure split DNS on the client.

### TAPPaaS Internal Access

This policy permits admin peers to use the `TAPPaaS Internal` network route.

- Source: `Admins`
- Destination: `TAPPaaS Internal` resource (`10.0.0.0/8`)
- Bidirectional: off (network resources cannot initiate connections)
- Protocol: All

---

## Result

Once configured, an admin peer connecting to Netbird will automatically receive:

- A single route for `10.0.0.0/8` via OPNsense, covering all TAPPaaS zones
- Split DNS for each registered `*.internal` domain pointing to OPNsense
- Full access to all hosts in all active zones by hostname or IP

When a new zone is activated, only the DNS nameserver needs updating — add the new
domain and nothing else changes.

