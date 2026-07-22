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

## 6. Firewall: let the overlay reach OPNsense itself

Section 5 covers traffic Caddy **forwards** to other hosts. Traffic that
*terminates on OPNsense itself* — DNS on port 53 (the NetBird nameserver from
§3), ICMP ping, and the web GUI — is a different case:

> **Why a rule is needed.** Forwarded traffic works because the routing peer's
> masquerade rewrites it. Traffic **terminating on OPNsense** has no forwarding
> hop to masquerade, so it arrives on the NetBird WireGuard interface with the
> peer's real `100.64.x.x` source and hits the interface's **default-deny**.
> Without an explicit pass rule, NetBird peers cannot resolve DNS through
> OPNsense, ping it, or reach its GUI — even though proxied services work.

Add a **floating pass rule** for the overlay CIDR:

- **Firewall → Rules → Floating → +**
  - **Action**: Pass
  - **Interface**: the NetBird/WireGuard interface (leave unset for a true
    floating rule that matches on all interfaces)
  - **Direction**: in
  - **TCP/IP Version**: IPv4
  - **Protocol**: any (or restrict to TCP/UDP + ICMP if you prefer)
  - **Source**: `100.64.0.0/10` (NetBird's full CGNAT range — see the Default
    CIDR note in §5; narrow only if you deliberately shrink the overlay)
  - **Destination**: `This Firewall` (self)
  - **Description**: `TAPPaaS: allow NetBird overlay to OPNsense`
  - **Apply changes.**

Per-peer authorization still lives in NetBird's own access policies (§4 — only
`Admins` get the route to OPNsense), so admitting the whole overlay CIDR at the
firewall is safe.

> **Not yet automated.** The `opnsense-firewall` CLI creates only
> interface-bound rules; a NetBird overlay pass rule must currently be a
> *floating* rule (the WireGuard interface is not an assigned OPNsense
> interface), so create it via the GUI above or the firewall filter API until
> the CLI grows floating-rule support.

---

## macOS client setup

On macOS (Sequoia and later), **use the NetBird.app directly — do not install
the LaunchDaemon**. The LaunchDaemon approach is for headless servers
(OPNsense, LXC containers), not desktop clients.

1. **Register as a User Device via SSO** (not a setup key): open
   `/Applications/NetBird.app` and log in with your account. This creates a
   User Device entry in the NetBird dashboard, not a Server.
2. **Auto-start:** System Settings → General → Login Items & Extensions →
   Open at Login → add NetBird.app.
3. **Connect** via the menu bar icon or `netbird up`.

> **Why not the LaunchDaemon?** Two Sequoia-specific gotchas break it:
>
> - **Background Task Management (BTM)** rejects the daemon: the shipped plist
>   lacks `AssociatedBundleIdentifiers`, and conflicting BTM registrations
>   (legacy "Wiretrustee UG" vs. current "NetBird GmbH" signing identity) cause
>   `backgroundtaskmanagementd` to actively remove the registration.
>   `launchctl bootstrap` fails with `Bootstrap failed: 5: Input/output error`.
> - **Symlinked binary path:** the plist points `ProgramArguments` at
>   `/usr/local/bin/netbird`, a symlink into NetBird.app — Sequoia's launchd
>   does not reliably follow symlinks for system daemons.

To diagnose BTM interference, watch the system log while the daemon tries to
register:

```sh
log show --predicate 'eventMessage contains[c] "netbird"' --last 2m --info
# BTM rejection shows as: removing uuid=..., name=NetBird GmbH, type=developer
```

If the daemon does not start after a reboot (BTM approval may need re-granting
after a fresh macOS install or major update): verify NetBird.app is still in
Login Items, then start it manually with `open /Applications/NetBird.app`
followed by `netbird up`, and check with `netbird status`.

---

## Result

After setup, an admin peer connecting to Netbird automatically receives:

- A route for `10.0.0.0/8` via OPNsense (all TAPPaaS zones)
- Split DNS for each `*.internal` domain pointing to OPNsense
- Full access to all hosts by hostname or IP

When a new zone is activated in `zones.json`, add its domain to the
Netbird nameserver. No other Netbird changes are needed.
