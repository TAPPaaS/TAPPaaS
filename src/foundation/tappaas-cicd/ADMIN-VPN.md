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

- `tappaas-cicd` reachable (you run the server-side commands there), with
  `~/.opnsense-credentials.txt`.
- **Topology A only:** a provisioned satellite carrying the `admin-vpn` role
  (`satellite-manager install <name> --roles reverse-proxy,admin-vpn …`) — this opens the
  `:51821` blind relay on the satellite and the `edge → admin-WG` allowance.
- **Topology B only:** a public IP on the cluster WAN and a WAN firewall rule allowing
  **UDP 51821 → OPNsense** (see §2B).
- WireGuard on your workstation (§4).

---

## 1. Server side (once) — bring up the OPNsense termination

On `tappaas-cicd`:

```bash
satellite-manager admin setup
```

Idempotent. It ensures the `tappaas-admin` WireGuard **server** on OPNsense (port `51821`,
tunnel `10.255.1.1/24`) and the least-privilege pass rule
`admin 10.255.1.0/24 → mgmt 10.0.0.0/24` on the `wireguard` interface, then applies. It
prints the **server public key** — you'll need it in the client config:

```
admin-vpn ready: server=tappaas-admin port=51821 pubkey=U/rnce…PVs=
  rule: 10.255.1.0/24 -> 10.0.0.0/24 (interface wireguard)
```

`satellite-manager admin list` shows the server pubkey, rule status, and registered peers at
any time.

## 2. Make `:51821` reachable

### 2A. Topology A (satellite) — nothing to do
Provisioning the satellite with the `admin-vpn` role already opened the `:51821` blind relay
and the `edge → admin-WG` allowance. Your `Endpoint` will be the **satellite** public IP.

### 2B. Topology B (direct public IP) — one WAN rule
Allow the admin WireGuard listener in from the internet (OPNsense → *Firewall → Rules → WAN*,
or via API): **pass, WAN, UDP, dest = This Firewall, dest port 51821.** Your `Endpoint` will
be the **cluster WAN** public IP. (Everything else — the admin-WG server and the `admin→mgmt`
rule from §1 — is identical.)

## 3. Generate your device keypair (on the workstation)

Same on macOS and Linux:

```bash
wg genkey | tee ~/tappaas-admin.key | wg pubkey > ~/tappaas-admin.pub
cat ~/tappaas-admin.pub   # copy this — you hand it to the server in §4
```
(macOS: `brew install wireguard-tools` first. The private key never leaves your device.)

## 4. Register your device as a peer (on `tappaas-cicd`)

```bash
satellite-manager admin add-peer --name lars-mac --pubkey '<contents of tappaas-admin.pub>'
# → peer 'lars-mac' added at 10.255.1.3/32     (an admin overlay IP is auto-assigned)
```

Then print a ready-to-use client config (fill `<host:port>` per your topology):

```bash
# Topology A:  satellite public IP
satellite-manager admin config 10.255.1.3/32 <satellite-public-ip>:51821
# Topology B:  cluster WAN public IP
satellite-manager admin config 10.255.1.3/32 <cluster-public-ip>:51821
```

It emits:

```ini
[Interface]
PrivateKey = <PASTE-YOUR-PRIVATE-KEY>          # from ~/tappaas-admin.key
Address    = 10.255.1.3/32
MTU        = 1340                              # admin WG is double-encapsulated over the relay — keep ≤1340

[Peer]
PublicKey           = U/rnce…PVs=              # the OPNsense admin-WG server key (from §1)
Endpoint            = <satellite-or-cluster-ip>:51821
AllowedIPs          = 10.0.0.0/24              # the mgmt plane; add more zones here to reach them
PersistentKeepalive = 25                       # keeps the CGNAT pinhole open
```

Paste your private key from `~/tappaas-admin.key` into `PrivateKey`.

## 5. Bring the tunnel up

### macOS
- **GUI (recommended):** install **WireGuard** from the Mac App Store → *Import tunnel(s)
  from file* (save the §4 output as `tappaas-admin.conf`) → toggle **Activate**.
- **CLI:** `brew install wireguard-tools`, save the config to
  `/opt/homebrew/etc/wireguard/tappaas-admin.conf`, then `sudo wg-quick up tappaas-admin`
  (`sudo wg-quick down tappaas-admin` to stop).

### Linux
- **`wg-quick`:** save to `/etc/wireguard/tappaas-admin.conf` (mode `600`), then
  `sudo wg-quick up tappaas-admin` (enable at boot:
  `sudo systemctl enable --now wg-quick@tappaas-admin`).
- **NetworkManager:** `nmcli connection import type wireguard file tappaas-admin.conf`.

## 6. Verify

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
satellite-manager admin add-peer --name <n> --pubkey <k> [--ip 10.255.1.N/32]
satellite-manager admin remove-peer <n>
```
Give each device its own peer (its own keypair + admin IP). Removing a peer revokes it
immediately.

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
- **MTU 1340 / keepalive 25.** The admin WG is double-encapsulated over the infra tunnel on
  the relay hop, so lower the client MTU; keepalive holds the CGNAT pinhole open.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No handshake (`wg show` blank) | `Endpoint` reachable? (A: satellite has `admin-vpn` role + `:51821` open; B: WAN UDP-51821 rule). Server pubkey correct? |
| Handshake OK, can't reach mgmt | `satellite-manager admin list` shows `rule: present`? Re-run `satellite-manager admin setup`. `AllowedIPs` includes `10.0.0.0/24`? |
| Connects then stalls / hangs | Lower `MTU` (try `1280`). Confirm `PersistentKeepalive = 25`. |
| Works on LAN, not remotely | You're hitting split-horizon/local routes — verify `Endpoint` is the **public** IP, not an internal one. |

Server-side implementation: `manager/satellite-manager/lib/admin-vpn.sh`
(`satellite-manager admin …`). Design: [ADR-010 §6](../../../docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md).
