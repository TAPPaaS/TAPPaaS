# TAPPaaS management tunnel (`admin-vpn`) — Mac & Linux setup

A WireGuard tunnel that gives an operator **the whole management plane from anywhere** —
Proxmox UIs (`tappaas1/2/3:8006`), the OPNsense UI, PBS (`:8007`), and SSH to any host —
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

- **The OPNsense termination is already up.** `satellite-manager admin setup` runs
  automatically during the tappaas-cicd bootstrap (right after the `network` module), so the
  `tappaas-admin` WireGuard server, the `admin → mgmt` rule, and the WAN `:51821` pass already
  exist. §1 is only for (re-)running it by hand — it is idempotent.
- `tappaas-cicd` reachable (you run the peer commands there), with `~/.opnsense-credentials.txt`.
- **Topology A only:** a provisioned satellite carrying the `admin-vpn` role
  (`satellite-manager install <name> --roles reverse-proxy,admin-vpn …`) — this opens the
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
satellite-manager admin setup      # idempotent
satellite-manager admin list       # server pubkey, rule + WAN-rule status, peers
```

`setup` ensures the `tappaas-admin` WireGuard **server** on OPNsense (port `51821`,
tunnel `10.255.1.1/24`), the least-privilege pass rule
`admin 10.255.1.0/24 → mgmt 10.0.0.0/24` on the `wireguard` interface, **and** a WAN pass for
**UDP `51821` → This Firewall**, then applies. It prints the **server public key** — you'll
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
satellite-manager admin add-peer --name lars-mac \
    --pubkey '<contents of tappaas-admin.pub>' \
    [--endpoint <cluster-or-satellite-public-ip>:51821]   # optional; auto-found for a satellite
```

It reports the auto-assigned admin IP (on stderr) and emits the config (on stdout, so
`… > tappaas-admin.conf` saves it straight to a file):

```ini
[Interface]
PrivateKey = <PASTE-YOUR-PRIVATE-KEY>          # from ~/tappaas-admin.key
Address    = 10.255.1.3/32                     # the auto-assigned admin IP
MTU        = 1340                              # admin WG is double-encapsulated over the relay — keep ≤1340

[Peer]
PublicKey           = U/rnce…PVs=              # the OPNsense admin-WG server key (from §1)
Endpoint            = <satellite-or-cluster-public-ip>:51821
AllowedIPs          = 10.0.0.0/24              # the mgmt plane; add more zones here to reach them
PersistentKeepalive = 25                       # keeps the CGNAT pinhole open
```

Paste your private key from `~/tappaas-admin.key` into `PrivateKey`. (Omit `--endpoint`
and the config prints with an `Endpoint` placeholder to fill in yourself. To re-print an
existing peer's config later: `satellite-manager admin config <ip/32> <host:port>`.)

## 4. Bring the tunnel up

### macOS
- **GUI (recommended):** install **WireGuard** from the Mac App Store → *Import tunnel(s)
  from file* (save the §3 output as `tappaas-admin.conf`) → toggle **Activate**.
- **CLI:** `brew install wireguard-tools`, save the config to
  `/opt/homebrew/etc/wireguard/tappaas-admin.conf`, then `sudo wg-quick up tappaas-admin`
  (`sudo wg-quick down tappaas-admin` to stop).

### Linux
- **`wg-quick`:** save to `/etc/wireguard/tappaas-admin.conf` (mode `600`), then
  `sudo wg-quick up tappaas-admin` (enable at boot:
  `sudo systemctl enable --now wg-quick@tappaas-admin`).
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

---

## Managing peers

```bash
satellite-manager admin list                         # server pubkey, rule, all peers
satellite-manager admin add-peer --name <n> --pubkey <k> [--ip 10.255.1.N/32] [--endpoint <h:p>]
satellite-manager admin remove-peer <n>
satellite-manager admin config <ip/32> <h:p>         # re-print an existing peer's config
```
Give each device its own peer (its own keypair + admin IP); `add-peer` prints its client
config (pass `--endpoint`). Removing a peer revokes it immediately.

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
| No handshake (`wg show` blank) | `Endpoint` reachable? (A: satellite has the `admin-vpn` role + `:51821` open; B: cluster has a public IP and the bootstrap WAN rule is present — `satellite-manager admin list` → `wan: present`). Server pubkey correct? |
| Handshake OK, can't reach mgmt | `satellite-manager admin list` shows `rule: present`? Re-run `satellite-manager admin setup`. `AllowedIPs` includes `10.0.0.0/24`? |
| Connects then stalls / hangs | Lower `MTU` (try `1280`). Confirm `PersistentKeepalive = 25`. |
| Works on LAN, not remotely | You're hitting split-horizon/local routes — verify `Endpoint` is the **public** IP, not an internal one. |

Server-side implementation: `manager/satellite-manager/lib/admin-vpn.sh`
(`satellite-manager admin …`). Design: [ADR-010 §6](../../../docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md).
