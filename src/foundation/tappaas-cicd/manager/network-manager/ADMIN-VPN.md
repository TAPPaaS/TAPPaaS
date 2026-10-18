# TAPPaaS management tunnel (`admin-vpn`) — Mac & Linux setup

A WireGuard tunnel that gives an operator **the whole management plane from anywhere** —
Proxmox UIs (`tappaas1/2/3:8006`), the OPNsense UI, PBS (`:8007`), SSH to any host, and the
published names that admit the `admin` zone (the console at `console.<domain>`, Grafana) —
without exposing any of it to the public internet. This is the ADR-010 `admin-vpn` role
(§6); it replaces "just set up some tunnel" and the commercial-SaaS alternatives.

Your device's WireGuard session **always terminates on OPNsense** (the cluster router),
never on the satellite. It lands in the dedicated `admin` overlay zone (`10.255.1.0/24`),
which is granted the `mgmt` zone (`10.0.0.0/24`) by one least-privilege firewall rule.

There are **two topologies** — pick the one that matches your site. The **client config
and the OPNsense side are identical**; only the tunnel `Endpoint` differs:

```
Topology A — behind CGNAT / no public IP (via satellite)
  [your Mac/Linux] --wg--> satellite:51821 --blind UDP relay--> OPNsense admin-WG --> mgmt
                    Endpoint = <satellite-public-ip>:51821

Topology B — cluster HAS a public IP (direct)
  [your Mac/Linux] --wg--> cluster-WAN:51821 -----------------> OPNsense admin-WG --> mgmt
                    Endpoint = <cluster-public-ip>:51821
```

> The satellite is a **blind relay** — it forwards opaque UDP and never holds admin keys or
> sees the traffic (same trust stance as the TLS passthrough). Terminating on OPNsense is what
> keeps an off-premises node out of the cleartext path.

---

## 0. Prerequisites

- **The OPNsense termination is already up.** `network-manager wgvpn setup` runs
  automatically during the tappaas-cicd bootstrap (right after the `network` module), so the
  `tappaas-admin` WireGuard server, the `admin → mgmt` rule, and the WAN `:51821` pass already
  exist. §1 is only for (re-)running it by hand — it is idempotent.
- `tappaas-cicd` reachable (you run the peer commands there), with `~/.opnsense-credentials.txt`.
- **Topology A only:** a provisioned satellite carrying the `admin-vpn` role
  (`module-manager module add satellite …`, see [satellite/INSTALL.md](../../../satellite/INSTALL.md)) — this opens the
  `:51821` blind relay on the satellite and the `edge → admin-WG` allowance, giving a CGNAT
  site inbound reach.
- **Topology B:** just a public IP on the cluster WAN — nothing to configure, bootstrap
  already opened the WAN `:51821` rule (§1).
- WireGuard on your workstation (§4).

---

## 1. Server side — done at bootstrap (idempotent to re-run)

The OPNsense termination is brought up automatically during the tappaas-cicd install
(topology-agnostic, **no satellite required**). To (re-)apply or inspect it by hand, on
`tappaas-cicd`:

```bash
network-manager wgvpn setup      # idempotent
network-manager wgvpn list       # server pubkey, rule + WAN-rule status, peers
```

`setup` ensures the `tappaas-admin` WireGuard **server** on OPNsense (port `51821`,
tunnel `10.255.1.1/24`), the least-privilege pass rule
`admin 10.255.1.0/24 → mgmt 10.0.0.0/24` on the `wireguard` interface, **and** a WAN pass for
**UDP `51821` → This Firewall**, then applies. A server that already exists keeps its port
(one made earlier may listen on `51820`): the WAN rule, `list` and the Endpoint of `add-peer`
and `config` all follow the port the server really has, and `list` finds the WAN rule by that
port, whatever its description. It prints the **server public key** — you'll
need it in the client config:

```
admin-vpn ready: server=tappaas-admin port=51821 pubkey=U/rnce…PVs=
  rule: 10.255.1.0/24 -> 10.0.0.0/24 (interface wireguard)
  wan : UDP 51821 -> This Firewall (interface wan) — direct/Topology-B reach
```

> **Why open `:51821` on WAN unconditionally is safe.** WireGuard silently drops any packet
> not authenticated by a registered peer (no handshake, no response, no banner), so the port
> is inert until you enroll a device (§3). On a CGNAT site the rule is never even reached; on
> a public-IP site it *is* your Topology-B path — so bootstrap opens it and Topology B needs
> no manual firewall step.

## 2. Generate your device keypair (on the workstation)

Same on macOS and Linux:

```bash
wg genkey | tee ~/tappaas-admin.key | wg pubkey > ~/tappaas-admin.pub
cat ~/tappaas-admin.pub   # copy this — you hand it to the server in §3
```
(macOS: `brew install wireguard-tools` first. The private key never leaves your device.)

## 3. Register your device as a peer (on `tappaas-cicd`)

`add-peer` registers the device **and prints its client config**. It fills the
`Endpoint` automatically: if a satellite carrying the `admin-vpn` role is configured
(Topology A), it uses that satellite's recorded public IP; otherwise it leaves a
placeholder. Pass `--endpoint <ip>:51821` to override (e.g. Topology B's cluster WAN IP):

```bash
network-manager wgvpn add-peer --name lars-mac \
    --pubkey '<contents of tappaas-admin.pub>' \
    [--endpoint <cluster-or-satellite-public-ip>:51821]   # optional; auto-found for a satellite
```

It reports the auto-assigned admin IP (on stderr) and emits the config (on stdout, so
`… > tappaas-admin.conf` saves it straight to a file):

```ini
# tappaas-admin client config v2: mgmt, the site's DNS, the published names
[Interface]
PrivateKey = <PASTE-YOUR-PRIVATE-KEY>          # from ~/tappaas-admin.key
Address    = 10.255.1.3/32                     # the auto-assigned admin IP
DNS        = 10.0.0.1                          # the site's resolver: mgmt's gateway (§6)
MTU        = 1340                              # admin WG is double-encapsulated over the relay — keep ≤1340

[Peer]
PublicKey           = U/rnce…PVs=              # the OPNsense admin-WG server key (from §1)
Endpoint            = <satellite-or-cluster-public-ip>:51821
AllowedIPs          = 10.0.0.0/24, 10.6.0.1/32, 2a13:e747:a210:8261:98:34ff:fe69:901a/128
PersistentKeepalive = 25                       # keeps the CGNAT pinhole open
```

`AllowedIPs` is the mgmt plane plus the DMZ gateway's IPv4 and IPv6 addresses, where Caddy
answers for every published name (§6). All of it comes from `config/zones.json` and the
firewall: mgmt's and dmz's `ip`, whose first address is the zone's gateway, and the
firewall's global IPv6 address on the dmz interface. A site without IPv6 gets no `/128`, and
the config says so in a comment above `AllowedIPs`.

Paste your private key from `~/tappaas-admin.key` into `PrivateKey`. (Omit `--endpoint`
and the config prints with an `Endpoint` placeholder to fill in yourself. To re-print an
existing peer's config later: `network-manager wgvpn config <name> [<host:port>]`.)

## 4. Bring the tunnel up

### macOS
- **GUI (recommended):** install **WireGuard** from the Mac App Store → *Import tunnel(s)
  from file* (save the §3 output as `tappaas-admin.conf`) → toggle **Activate**.
- **CLI:** `brew install wireguard-tools`, save the config to
  `/opt/homebrew/etc/wireguard/tappaas-admin.conf`, then `sudo wg-quick up tappaas-admin`
  (`sudo wg-quick down tappaas-admin` to stop). `wg-quick` sets the `DNS` line as the Mac's
  resolver while the tunnel is up and puts the old one back when it goes down.

### Linux
- **`wg-quick`:** save to `/etc/wireguard/tappaas-admin.conf` (mode `600`), then
  `sudo wg-quick up tappaas-admin` (enable at boot:
  `sudo systemctl enable --now wg-quick@tappaas-admin`). The `DNS` line needs
  `resolvconf` or `systemd-resolved` on the host; without either, `wg-quick` stops with an
  error.
- **NetworkManager:** `nmcli connection import type wireguard file tappaas-admin.conf`.

## 5. Verify

```bash
sudo wg show                       # a recent 'latest handshake' + non-zero transfer = tunnel up
ping 10.0.0.1                      # OPNsense mgmt IP over the tunnel
```
Then, from the workstation, reach the management plane:
- Proxmox: `https://10.0.0.<node>:8006`
- OPNsense UI: `https://10.0.0.1`
- PBS: `https://<pbs-mgmt-ip>:8007`
- SSH: `ssh root@<any-mgmt-host>`

And a published name, answered by the site's resolver with the DMZ gateway:
```bash
dig +short console.<domain>        # 10.6.0.1 (and the dmz IPv6 address for AAAA), not the WAN address
curl -sI https://console.<domain>  # 302 to the Authentik login, not 403
```

## 6. Published names over the tunnel

Inside the site every published name (`console.<domain>`, `logging.<domain>`, …) resolves to
the DMZ gateway, where Caddy listens (ADR-021 D2), and the `admin` zone may reach the
firewall there on 80 and 443 (ADR-021 D3a). Two lines of the config make a laptop on the
tunnel take that path:

- **`DNS = <mgmt gateway>`** — the laptop asks the site's resolver while the tunnel is up, so
  a published name answers with the DMZ gateway instead of the public WAN address. Without it
  the laptop resolved the name publicly, went over the internet to the WAN, and Caddy, seeing
  the laptop's public address, answered **403**.
- **`<dmz gateway>/32` and `<dmz gateway IPv6>/128` in `AllowedIPs`** — the answer is routed
  through the tunnel. The request arrives from the `admin` overlay, which a service whose
  `proxyAllowedZones` includes `admin` lets through to its identity gate.

The overlay itself is IPv4 only (`10.255.1.0/24`), so nothing answers over the IPv6 route:
it keeps the laptop's attempt at the name's AAAA address in the tunnel rather than sending it
across the internet, and the browser goes on over IPv4 within a fraction of a second.

Nothing changes on the firewall; only the client config does.

**A tunnel set up before this (config v1) has neither line.** `network-manager wgvpn list`
says which peers that is:

```
peers  :
  - lars-mac  10.255.1.2/32  config v1: no DNS, mgmt only — re-issue (network-manager wgvpn config lars-mac) and re-import
  - lars-phone  10.255.1.3/32  config v2 issued 2026-10-18
```

Re-issue the config once (`network-manager wgvpn config <name> [<host:port>] >
tappaas-admin.conf`: give the Endpoint the device uses when no admin-vpn satellite supplies
it; paste the private key back in) and re-import it on the device: in the WireGuard app, remove the
tunnel and *Import tunnel(s) from file* again, or replace the file `wg-quick` reads. The
peer's key and address do not change, so nothing is done on the firewall. `list` records the
re-issue, not the re-import: a peer shows v2 once its config was printed.

**Until a tunnel is re-imported**, a hosts-file line reaches a name through the mgmt route
the old config already has — Caddy answers on the firewall's mgmt address too:

```
10.0.0.1  console.<domain>        # /etc/hosts on macOS and Linux
```

Remove it after the re-import, or the name keeps going to mgmt's address when the tunnel is
down.

---

## Managing peers

```bash
network-manager wgvpn list                         # server pubkey, rule, all peers
network-manager wgvpn add-peer --name <n> --pubkey <k> [--ip 10.255.1.N/32] [--endpoint <h:p>]
network-manager wgvpn remove-peer <n>
network-manager wgvpn config <n> [<h:p>]           # re-print an existing peer's config (records it as v2)
```
Give each device its own peer (its own keypair + admin IP); `add-peer` prints its client
config (pass `--endpoint`). Removing a peer revokes it immediately. Which config each peer
was given last is kept in `config/wgvpn/peers.json`.

## Reaching more than `mgmt`

`AllowedIPs`/the firewall rule grant the `mgmt` zone by default (Proxmox, OPNsense, and the
management-network hosts). To reach a host in another zone (e.g. a service VM in `dmz` or a
`srv*` zone), add that zone's subnet to **both** the client `AllowedIPs` and a matching
`wireguard`-interface pass rule (mirror the `admin→mgmt` rule for the new destination).
Keep it least-privilege — grant only the zones you actually administer.

## How it works (and why it's safe)

- **Terminates on OPNsense, not the satellite** (§6.1). The admin↔OPNsense session is
  end-to-end encrypted; a compromised satellite relays opaque UDP and can disrupt but never
  read or impersonate — the same blind-relay property as TLS passthrough.
- **Least privilege.** The `admin` overlay reaches only what a `wireguard`-interface pass rule
  allows (default: `mgmt`). It is never itself *inside* `mgmt`.
- **No control plane.** Plain WireGuard — no NetBird/Tailscale/commercial relay in the path
  (Goal #2). NetBird stays available and independent for many-peer mesh / site-to-site.
- **WAN `:51821` open by default is safe.** Bootstrap opens it so a public-IP site is reachable
  with zero manual steps; WireGuard's silent-drop-without-a-peer property means an exposed port
  is inert until a device is enrolled, and behind CGNAT the rule is never reached.
- **MTU 1340 / keepalive 25.** The admin WG is double-encapsulated over the infra tunnel on
  the relay hop, so lower the client MTU; keepalive holds the CGNAT pinhole open.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No handshake (`wg show` blank) | `Endpoint` reachable? (A: satellite has the `admin-vpn` role + `:51821` open; B: cluster has a public IP and the bootstrap WAN rule is present — `network-manager wgvpn list` → `wan: present`). Server pubkey correct? |
| Handshake OK, can't reach mgmt | `network-manager wgvpn list` shows `rule: present`? Re-run `network-manager wgvpn setup`. `AllowedIPs` includes `10.0.0.0/24`? |
| Connects then stalls / hangs | Lower `MTU` (try `1280`). Confirm `PersistentKeepalive = 25`. |
| A published name answers 403 | The tunnel is a v1 config: `network-manager wgvpn list` says so. Re-issue and re-import it (§6), or use the hosts-file line meanwhile. `dig console.<domain>` should give `10.6.0.1`, not the WAN address. |
| Works on LAN, not remotely | You're hitting split-horizon/local routes — verify `Endpoint` is the **public** IP, not an internal one. |

Server-side implementation: `manager/network-manager/wgvpn/` (`network-manager wgvpn …`).
Design: [ADR-010 §6, §8.4.6](../../../../../docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md).
