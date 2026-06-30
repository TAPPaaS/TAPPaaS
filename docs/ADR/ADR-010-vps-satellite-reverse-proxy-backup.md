# ADR-010: VPS Satellite for Reverse Proxy and Backup

**Status:** draft
**Date:** 2026-06-29
**Deciders:** @LarsRossen
**Related:** [NetworkDesign.md](../Architecture/NetworkDesign.md) ("can function with no public IPv4"); [netbird-setup.md](../../src/foundation/firewall/docs/netbird-setup.md) (current remote-access overlay); [ADR-005](ADR-005-variant-domain-architecture.md) (variant/domain + split-horizon DNS, Caddy-on-OPNsense); [backup/QUICKREF.md](../../src/foundation/backup/QUICKREF.md) (PBS multi-source pull/push, #227); _TBD — open issue for satellite_
**Changelog:** 2026-06-29 — skeleton + Context drafted; §2 TLS passthrough decided (terminate-at-satellite parked); §4 WireGuard tunnel (home dials out, satellite listens) + dedicated `edge` overlay zone decided; §4.4 all decided (`/31` `10.255.0.0/31`; :443 passthrough + :80 redirect-via-Caddy; wg `51820` default/configurable + `443/udp` fallback; automated DNS, split-horizon kept, no IPv6 v1); §5 provisioning/lifecycle drafted (NixOS via nixos-anywhere, `satellite-manager` on tappaas-cicd, optional `45-satellite` foundation module); §5.3 expanded with Hetzner Cloud reference, **Tier A (portal allocate) = default**, Tier B (hcloud API token) opt-in; nixos-anywhere kexec, no rescue/custom image; §3 Backup drafted — off-site PBS **pull** model (satellite pulls home, `--remove-vanished false`, client-side encryption key stays home, opt-in role + tunnel `edge→PBS:8007`); admin access reworked into the **`admin-vpn`** role (§6, Goal #5): WireGuard terminating on OPNsense → full management-plane reach, satellite as blind UDP relay (Option B); WG-hub rejected; SSH-only passthrough kept as minimal sub-mode; ports/firewall/roles updated throughout; **§7 secrets inventory (~11 creds) + compromise-isolation** added — pull-only data plane + no standing cicd root + ephemeral provisioning + one-directional mgmt + local immutable ZFS snapshots so a hacked cluster can't destroy the vault; §5.8 passthrough forwarder = **nginx `stream`** (HAProxy alt; Caddy-l4/Traefik rejected), PROXY-protocol-v2 required for client-IP, SNI only for future multi-site

---

## Context

Public reachability is the weakest assumption in the current TAPPaaS network model. Today the design **assumes a reachable public IP on the WAN port** — public ingress (ports 80/443) terminates at **Caddy running on the OPNsense firewall itself**, reached either directly or through a NAT pinhole. That assumption holds for a home/SMB site with a static or DHCP public IPv4. It breaks for a large and growing share of real deployments:

- **CGNAT** — the ISP hands out a private WAN address; ports 80/443 cannot be forwarded inbound at all.
- **Dynamic IP** — the public address changes, breaking DNS A/AAAA records and certificate validation.
- **No inbound allowed** — mobile/4G/5G/Starlink uplinks, or a corporate/landlord network where the operator does not control port forwarding.

The current advice for these cases is to **use NetBird** (a WireGuard mesh overlay) for remote administrative access, and otherwise to "set up some kind of tunnel" so the WAN edge becomes reachable. Two problems follow:

1. **It only solves admin access, not public service publishing.** NetBird gives the *administrator* a path into the `mgmt` zone; it does nothing to make a tenant's Nextcloud or website reachable to an *unauthenticated public visitor* who is not a NetBird peer. [NetworkDesign.md](../Architecture/NetworkDesign.md) asserts TAPPaaS "can function with no public IPv4," but there is no implemented mechanism that makes public HTTPS ingress work in that case.
2. **It pushes the hard part onto the operator and onto third parties.** "Set up a tunnel" is undefined work, and the convenient off-the-shelf answers (Cloudflare Tunnel, Tailscale Funnel, ngrok, commercial relays) mean **handing public ingress — and often TLS termination — to a commercial SaaS**, which contradicts the TAPPaaS premise of a *Trusted, Private, self-owned* platform.

### Proposal (summary)

Introduce a **TAPPaaS satellite**: a small, operator-owned node placed where it *does* have a stable public IP — typically a low-cost **VPS at a public cloud/hosting provider, but equally any VM or physical machine with a public address** (a second site, a colo box, a relative's house). The satellite runs as a **reverse-proxy frontend** for the home/SMB cluster: it accepts public HTTPS, and forwards it over an operator-owned encrypted tunnel to the Caddy/services behind the (possibly CGNAT'd) firewall. The same node is a natural place for **off-site backup**. The satellite is provisioned and managed by TAPPaaS itself — no commercial tunnel SaaS, no manual per-deployment tunnel engineering.

### Goals

1. **Public ingress without a public IP at home** — publish TAPPaaS services to the open internet from a site behind CGNAT / dynamic IP / no-inbound, with no port forwarding on the local WAN.
2. **No commercial dependency** — the entire ingress path (tunnel, TLS, proxy) runs on operator-owned infrastructure and TAPPaaS-managed software; no Cloudflare/Tailscale/ngrok-class SaaS in the data path.
3. **Self-owned trust** — TLS private keys and request contents stay under operator control; the satellite is a trusted TAPPaaS node, not a third party terminating the operator's traffic on their behalf.
4. **Turnkey provisioning** — stand up, configure, update, and decommission a satellite through the normal TAPPaaS tooling (foundation/module flow), not bespoke admin scripting.
5. **Administrative access (management plane)** — give the operator public-reachable admin access to the *whole* management plane even with no public IP: web UIs on `tappaas1/2/3` (`:8006`), OPNsense, PBS (`:8007`), and SSH to any host — not just `tappaas-cicd`. Delivered via **WireGuard** terminating on OPNsense (the `admin-vpn` role, §6), with the satellite as a blind relay. Plain WireGuard, no control plane, no commercial overlay.
6. **Multi-purpose** — one satellite can carry any combination of three roles — public-service ingress, **off-site backup** (reusing the PBS multi-source model, #227), and **admin-vpn** management access — selected per deployment.
7. **Graceful** — when a site *does* have a public IP, the satellite is optional; adding/removing it does not require re-architecting the cluster.

### Non-goals (v1)

- **Replacing NetBird** for *peer-to-peer mesh* / multi-site fabric. The satellite's `admin-vpn` (§6) gives a single operator full management-plane reach into the cluster via a WireGuard endpoint terminating on OPNsense — covering the common single-admin case **without** NetBird's control plane. NetBird remains the choice for many-peer mesh, site-to-site fabric, or any-peer-to-any-zone topologies; the two compose. (*Admin access is now a goal — see Goals #5 — not a non-goal.*)
- High-availability / multi-satellite load balancing or anycast.
- Hosting application workloads on the satellite (it is a frontend/relay + backup target, not a compute node for services).
- Egress proxying / outbound traffic shaping.
- Moving TLS termination off the home cluster by default (whether the satellite terminates TLS or passes it through is an explicit design question — see Decision §2).

---

## Decision

_State the chosen approach. Fill in the subsections below as the design firms up._

### 1. Role of the VPS satellite

_What the VPS is and is not. Trust boundary relative to the home/SMB cluster._

### 2. Reverse proxy responsibility — TLS passthrough (decided)

**Decision: the satellite is a TLS *passthrough* relay. It does not terminate TLS.** The satellite accepts the public TCP connection on :443 and forwards the encrypted stream — routed by **TLS SNI**, so multiple hostnames/services share the one public IP — down the WireGuard tunnel to **Caddy on OPNsense**, which remains the sole TLS terminator and certificate holder (unchanged from today's model, ADR-005). The satellite never sees plaintext and never holds a private key.

Rationale: this directly serves **goal #3 (self-owned trust)**. A satellite is, by definition, a node sitting on someone else's infrastructure (a VPS provider, a remote site). If it terminated TLS it would hold the operator's certificate private keys and see every request in cleartext; a compromised or subpoenaed VPS would then expose all traffic. As a passthrough relay it is a *dumb encrypted pipe* — compromising it yields ciphertext and the ability to disrupt, but not to read or impersonate.

Certificate strategy is therefore **unchanged**: Caddy on OPNsense obtains and renews certs (DNS-01 wildcard per ADR-005). ACME does not run on the satellite, so no inbound :80 HTTP-01 challenge is needed there for the passthrough path.

#### Parked alternative — terminate TLS at the satellite (NOT chosen)

> Terminating TLS at the satellite (satellite holds certs, decrypts, re-encrypts inward over the tunnel) would enable edge caching, a WAF, and HTTP-level routing at the public edge. **We deliberately do not do this in v1** because it places the operator's TLS private keys and plaintext request data on a node outside the operator's premises — weakening the self-owned trust boundary that is the whole point of the satellite (goal #3). Documented here so the option is on record; revisit only if a future use case (e.g. edge caching for a high-traffic public site) justifies the trust trade-off, and even then prefer per-service opt-in over a default.

### 3. Backup responsibility — off-site PBS, pull model (decided)

The satellite's optional second role is an **off-site backup target**. It reuses the existing PBS multi-source machinery ([35-backup](../../src/foundation/backup/), #227) rather than inventing anything: the satellite is, in effect, the **Class A "remote pull" pattern inverted by location** — instead of the home PBS pulling a *buddy's* PBS, the **satellite PBS pulls the home PBS**.

#### 3.1 Direction — the satellite pulls (decided)

The satellite runs its own PBS datastore and a **sync job that pulls** from the home PBS (home = source, satellite = destination), over the WireGuard tunnel. Same hardening as Class A: **`--remove-vanished false`**, and prune/GC/verify owned by the *destination* (the satellite).

Why pull-by-the-satellite, not push-from-home — this is the whole DR property:

- The **home** cluster holds **no credential to the satellite** datastore. So a **compromise (or ransomware) at the home site cannot reach out and delete the off-site copy** — exactly the property Class A was designed for. Push-from-home would hand the home side delete rights on the off-site copy, defeating the point.
- The satellite holds only a **read-only** sync credential to the home PBS (PBS API token, `Datastore.Read`/`Audit` on the home datastore — no delete). A compromised satellite can *read* home backups (which are encrypted — §3.2) but cannot erase or tamper with the source.

So neither end can destroy the other's data: home can't wipe the off-site copy, satellite can't wipe the source.

#### 3.2 Encryption at rest — client-side, key stays home (decided)

The satellite sits on someone else's hardware and must be assumed seizable/compromisable. Therefore backups are **client-side encrypted at the home cluster** before any data crosses the tunnel; PBS sync preserves the encrypted chunks **end-to-end** (as Class A already does), so the **satellite stores only ciphertext and never holds the key**. This is the backup analogue of the §2 TLS-passthrough trust stance: the satellite is a blind store, exactly as it is a blind relay.

> **The encryption key is the DR linchpin.** It is held at home and **must be backed up independently of the satellite** (operator-guarded — e.g. in the identity/secrets store and an offline copy). Losing it makes the off-site copy unrecoverable. This is called out again in the restore path (§3.5) and Acceptance.

#### 3.3 Mechanism & connectivity

- **Reuse:** register the home PBS as a sync **remote** on the satellite's PBS; the satellite runs the same prune/GC/verify schedule the backup module already defines (#228 verify-job + verify-new guard bit-rot on the satellite's disk too).
- **Connectivity:** the pull reaches the home PBS (`:8007`) **over the established WireGuard tunnel**. This adds **one** least-privilege allowance to the `edge` zone for the backup role — `edge → home-PBS:8007` — beyond the Caddy ingress of §4.3. Nothing else in the cluster becomes reachable.
- **Namespace:** home backups land in a dedicated namespace on the satellite datastore (e.g. `remote/home`), keeping the layout consistent with #227.

#### 3.4 Storage & cost — opt-in role

The `reverse-proxy` and `admin-vpn` roles need almost no disk; the **`backup` role needs a datastore sized to the backup set**, which on a VPS means attaching a paid volume (e.g. a Hetzner Cloud Volume). Backup is therefore an **explicit opt-in role** in `satellite.json` (`roles: ["reverse-proxy", "admin-vpn", "backup"]`), so a pure ingress/admin satellite stays tiny and cheap. A site may also run *two* satellites (e.g. one relay+admin, one backup) — they are independent.

#### 3.5 Restore / disaster recovery

For a full-site loss, the operator rebuilds a cluster/PBS and **pulls the backups back from the satellite** (the satellite becomes the source for recovery), then restores VMs via the existing [`restore.sh`](../../src/foundation/backup/restore.sh) path. Recovery **requires the client-side encryption key** (§3.2) — without it the off-site ciphertext is useless, so verifying the key is independently recoverable is part of any DR drill.

### 4. Networking & connectivity

#### 4.1 Tunnel technology — WireGuard

The satellite ↔ cluster tunnel is **WireGuard**, point-to-point, operator-owned, with **no external control plane**.

Rationale:

- **Already in the stack.** WireGuard is a kernel/in-tree transport; OPNsense ships the `os-wireguard` plugin, and TAPPaaS already relies on WireGuard underneath NetBird — so it adds no new trust-critical dependency and the operator's mental model carries over.
- **No commercial / SaaS dependency (goal #2).** A plain WireGuard peering needs only the two endpoints' public keys and the satellite's public endpoint. Unlike NetBird, Tailscale, or Cloudflare Tunnel, there is **no management/coordination server** in the path (NetBird's default control plane is a hosted SaaS; self-hosting it is extra moving parts). This keeps the ingress path entirely self-owned (goal #3).
- **Cheap and fast.** Low overhead, high throughput, minimal CPU on a small VPS — appropriate for a relay node.
- **Self-owned keys.** WireGuard keypairs are generated on each node and never leave it; the tunnel's confidentiality does not depend on any third party.

**Why not reuse NetBird for this tunnel?** NetBird solves *admin mesh access* (many roaming peers, dynamic membership, ACLs) and benefits from a control plane. The satellite tunnel is the opposite shape: a *single, fixed, long-lived* point-to-point link carrying public service traffic. A dedicated plain-WireGuard tunnel is simpler, has fewer dependencies, and keeps public-ingress traffic isolated from the admin overlay. The two coexist (both are WireGuard under the hood) but are independent.

#### 4.2 Connection direction — home dials out, satellite listens

This is the crux of the CGNAT problem. The cluster has **no inbound reachability**; the satellite has a **stable public IP**. Therefore:

- The **satellite** is the WireGuard **listener** — fixed public endpoint `‹satellite-public-ip›:‹udp-port›`. It does **not** configure an `Endpoint` for the home peer (it learns the home peer's current source address from the incoming handshake — WireGuard roaming).
- The **home cluster** (OPNsense, via `os-wireguard`) is the **initiator** — it dials *outbound* to the satellite's public endpoint. Outbound UDP is virtually always permitted even under CGNAT, so no port forwarding or ISP cooperation is needed at home.
- The home peer sets **`PersistentKeepalive` (~25 s)** so the CGNAT/NAT mapping and the WireGuard session stay open continuously, allowing the satellite to push *inbound* public traffic back down an already-established tunnel.

```text
   public visitor                Internet              operator-owned
        │                                                   │
        ▼                                                   ▼
  HTTPS :443  ───────────────▶  [ SATELLITE ]  ◀═══ WireGuard ═══   [ HOME / OPNsense ]
                              public IP, wg listener   tunnel        no public IP (CGNAT)
                                     │                                      │
                                     │   forward over wg (passthrough       ▼
                                     └──  or terminate — see §2) ──▶   Caddy / services
                                                                      (mgmt + zones)

   ── outbound handshake + PersistentKeepalive originates at HOME ──▶ keeps the
      NAT pinhole open so the satellite can push inbound traffic back down the tunnel
```

#### 4.3 Zone placement — a dedicated `edge` overlay zone (decided)

The satellite peer lands in a **new dedicated `edge` zone** in `zones.json`, modeled on the existing **`netbird` overlay zone** — *not* a VLAN zone and *not* the existing `dmz` zone.

- **Overlay, not VLAN.** Like `netbird`, the `edge` zone is `type: "Overlay"`, `state: "Manual"`, `vlantag: 0` — `zone-manager` creates no VLAN interface or DHCP for it; it exists so the firewall can resolve the satellite's tunnel CIDR and write rules for it. Its `ip` is the WireGuard tunnel subnet (a `/31` point-to-point — see §4.4.1).
- **Why a dedicated zone, not `dmz`.** `dmz` (VLAN 610) is for *internet-exposed services running inside the cluster* and has internet egress + inbound pinholes. The satellite is the inverse: an *external* node reaching *in* over a private tunnel. Giving it its own zone makes the "semi-trusted external relay" boundary explicit and lets the firewall grant it **least privilege** rather than DMZ-class access.
- **Why a dedicated zone, not `netbird`.** `netbird` admits *admin* peers to management surfaces; the satellite carries *public service* traffic and must reach only the reverse-proxy ingress. Separate zones keep the two trust domains and rule-sets independent (consistent with §4.1).

##### Firewall posture (least-privilege)

The `edge` zone's `access-to` is **least-privilege and role-gated** — the satellite may reach **only** the specific cluster endpoints its active roles require, and nothing else (never broad `mgmt` reach):

| Role | `edge` may reach | Why |
| --- | --- | --- |
| reverse-proxy | Caddy ingress on OPNsense | deliver ciphertext to the TLS terminator |
| admin-vpn | OPNsense admin-WG listener only (§6) | relay the admin WireGuard session; OPNsense (not `edge`) then routes admins into the `admin` overlay zone |
| backup | home PBS `:8007` only (§3.3) | pull source for off-site sync |

A compromised VPS can therefore deliver ciphertext to Caddy, relay an opaque WireGuard session to OPNsense (which authenticates it independently), and read encrypted PBS chunks — but it is never a flat route into the cluster. Note the **two-layer** separation for admin access: the `edge` zone only reaches OPNsense's WG listener; the admin's reach into `mgmt` is granted by a **separate `admin` overlay zone** on OPNsense (modeled on `netbird`), so the satellite is never itself inside `mgmt`. Exact `access-to` / `pinhole-allowed-from` entries to be specified against the zones schema, and this should slot into the ADR-008 zone-orchestration model (the `opnsense` provider writes these rules; the WireGuard interface is the `edge` zone's bridge-equivalent).

#### 4.4 DNS, addressing, ports — decided

##### 4.4.1 Tunnel subnet & addressing — `/31` (decided)

The WireGuard link uses a **`/31` point-to-point** subnet (RFC 3021) — exactly two addresses, satellite + home, no waste. A second satellite, if ever wanted, gets its own tunnel and its own `edge`-style zone rather than sharing this one.

The range is a small **dedicated slice reserved for `edge`**, chosen to be provably clear of (a) the `10.{1..6}.x` TAPPaaS zone ranges, (b) the `netbird` overlay (`100.64.0.0/10`), and (c) typical VPS-provider internal addressing — candidate **`10.255.0.0/31`** (high block, far from the zone ranges). The satellite's `AllowedIPs` is scoped to the **cluster-side ingress address only**, not a broad route.

##### 4.4.2 Public listening ports — :443 passthrough + :80 redirect via Caddy (decided)

| Port | Role | Behavior |
| --- | --- | --- |
| **:443/tcp** | reverse-proxy | SNI-routed TLS passthrough → tunnel → Caddy (always on when this role is active; the core function). |
| **:80/tcp** | reverse-proxy | **Passthrough to Caddy** — the satellite forwards :80 down the tunnel and **Caddy issues the `301 → https://` redirect**. The satellite adds no HTTP logic of its own (stays a dumb relay). |
| **:`adminWgPort`/udp** | admin-vpn | **Blind UDP relay** of an admin WireGuard session that terminates on OPNsense (§6). Forwarded down the infra tunnel; the satellite holds no admin keys, so it relays only — admin↔OPNsense stays end-to-end encrypted. Only open when the admin-vpn role is active. |
| _(opt.)_ **:`sshPort`/tcp** | admin-vpn (minimal) | Optional lighter sub-mode: pure TCP passthrough to `tappaas-cicd:22` (SSH auth + host-key check terminate on `tappaas-cicd`). For "just a shell on the mothership" without a WG client; the full management plane needs the WG path above. |

Forwarding :80 to Caddy also yields, for free, a working **HTTP-01 ACME fallback path** (a challenge to `satellite:80` reaches Caddy through the tunnel) for any site where DNS-01 is unavailable — though DNS-01 wildcard (ADR-005) remains the default.

##### 4.4.3 WireGuard UDP port — `51820` default, configurable; `443/udp` fallback (decided)

The port is the **satellite's listening (destination) port**, which the **home end dials outbound** — so the constraint is what the home site's *egress* permits, not its inbound.

- **Default `51820/udp`** (the WireGuard convention) — works on any normal residential/business line where all outbound UDP is allowed.
- **Configurable, not hardcoded** — both ends share one `wgPort` setting.
- **Documented fallback `443/udp`** — for *hostile egress* (hotel/captive WiFi, corporate guest nets, some mobile carriers) that block outbound UDP on unknown high ports but pass "web" ports. To a port-based egress filter, `443/udp` looks like ordinary QUIC/HTTP3 and traverses. It does **not** clash with the public `443/tcp` listener (different protocol/socket). A *high random* port is explicitly **not** offered — it gives cosmetic obscurity with none of the traversal benefit.

`PersistentKeepalive ~25s` from the home end keeps the chosen port's NAT mapping open regardless of which port is used.

##### 4.4.4 DNS & split-horizon — automated record, existing split-horizon kept, no IPv6 in v1 (decided)

- **Public record:** automated — reuse the **DNS-provider API credentials already present for DNS-01 ACME** so `dns-manager` sets/updates the public `A` / wildcard to point at the satellite's stable IP. (No manual record step; the creds already exist.) This is what eliminates the dynamic-IP problem at home.
- **Split-horizon unchanged:** internal on-LAN clients keep resolving published names to the **local OPNsense interface** (ADR-005) and must **never hairpin** out to the satellite and back. The satellite changes only the external/authoritative view; internal Unbound overrides are untouched. *Invariant to verify: the satellite IP never leaks into the internal view.*
- **IPv6: not supported in v1.** No `AAAA` is published for the satellite path. With no IPv6 and IPv4 behind CGNAT, the satellite is the **single** public ingress — which is simpler to secure (one path, one trust boundary). A future v6-direct-to-home optimization (IPv6 often routes globally even under v4 CGNAT) is left as a later enhancement, out of scope here.

### 5. Provisioning & lifecycle

The satellite breaks the usual TAPPaaS module mold in one important way: **it is not a Proxmox VM the cluster hosts — it is an external host the cluster *reaches out to and manages***. Everything else (declarative NixOS, managed from `tappaas-cicd`, config-as-data) stays the same.

#### 5.1 What the node is — declarative NixOS, minimal

The satellite runs **NixOS**, configured **declaratively** from the repo, same as every other TAPPaaS node. It is deliberately minimal: a WireGuard endpoint, an SNI-aware TCP forwarder (the passthrough relay, §2), and — when the backup role is enabled — a PBS/datastore target (§3). No application workloads (non-goal). Keeping it NixOS means the satellite's entire state is reproducible from the repo and rebuildable from scratch after a provider loss.

#### 5.2 Where it is managed from — `tappaas-cicd`, via `satellite-manager`

The satellite is **provisioned** from the **`tappaas-cicd` mothership** through a new **`satellite-manager`** CLI plus a config pair that mirrors the module convention. Note a deliberate departure from the usual model: `tappaas-cicd` does **not** retain standing root over *any* satellite after provisioning — see the compromise-isolation rules in §7.3 (applied uniformly to all roles).

- `satellite.json` — declarative config: provider/label, public IP, SSH access, `wgPort` (infra tunnel), `adminWgPort` (admin-vpn relay), tunnel `/31`, the domain(s)/SNI names it fronts, and a `roles` list — any combination of `reverse-proxy`, `admin-vpn`, `backup`.
- `satellite.nix` — the NixOS configuration deployed onto the external host.

#### 5.3 Bootstrap flow — bare VPS → satellite

The generic flow (any provider, or any machine with a public IPv4). The single unavoidable manual prerequisite is provider-side: obtain a host with a **public IPv4 + root SSH**. Minimal specs (1–2 vCPU / 1–2 GB is ample for a passthrough relay; add disk only for the backup role). `satellite-manager` does the rest:

1. **Register** — operator records the IP / SSH access / `wgPort` / domains in `satellite.json`.
2. **Deploy NixOS** — bootstrap `satellite.nix` onto the host over SSH with **`nixos-anywhere`** (new tooling for TAPPaaS — no in-tree precedent outside the Attic). It `kexec`s the running image into a NixOS installer, partitions declaratively with **disko**, and installs. The satellite comes up running: the WireGuard listener (`:wgPort/udp`, peer = home pubkey), the SNI passthrough forwarder (`:443/tcp` → tunnel → Caddy; `:80/tcp` → tunnel for Caddy's redirect, §4.4.2), and a host firewall exposing only those three ports.
3. **Keypairs** — the satellite generates its **own** WireGuard private key on first boot (it never leaves the host); `satellite-manager` SSHes in to read back only the **public** key. The home key is generated on OPNsense the same way. (See §5.4.)
4. **Wire the home end** — add the `edge` zone to `zones.json`, create the OPNsense `os-wireguard` peer (`Endpoint = satellite:wgPort`, `AllowedIPs` = the `/31` + the role-specific endpoints from §4.3, `PersistentKeepalive = 25`), and run **`zone-manager reconcile --apply`** (ADR-008) so the least-privilege, role-gated `edge` firewall rules land.
5. **DNS** — `dns-manager` points the public `A`/wildcard at the satellite IP (§4.4.4).
6. **Verify** — tunnel handshakes, then an end-to-end public HTTPS probe of a fronted name resolving through satellite → tunnel → Caddy.

##### 5.3.1 Hetzner Cloud — the most-automated path (reference)

For a Hetzner Cloud VPS there are two tiers of automation. **Tier A (operator allocates on the portal) is the default**; Tier B (fully API-driven) is an opt-in path for operators who accept storing a server-create/destroy API token as a TAPPaaS secret.

**Why no rescue mode / no custom image is needed:** `nixos-anywhere` boots the stock Hetzner image (Debian/Ubuntu) and `kexec`s straight into the NixOS installer — confirmed on Hetzner Cloud. So *any* default image works as the launch pad; we never maintain a NixOS snapshot.

**Tier A — operator allocates on the web portal (DEFAULT):**

1. In the Hetzner Cloud console, create a server: image **Debian 12** (or Ubuntu), attach the operator's **SSH public key**, smallest type (e.g. `cax11` ARM 2 vCPU/4 GB, cheapest; or `cx22`). Note the public IP. *(~5 clicks.)*
2. `satellite-manager install <name> --ip <pubip>` runs nixos-anywhere and steps 3–6 above:
   ```bash
   nix run github:nix-community/nixos-anywhere -- \
     --flake .#satellite-<name> --target-host root@<pubip> --build-on-remote
   ```

**Tier B — fully API-driven (opt-in; most automated, zero portal server-creation):**

Not the default: it requires storing a one-time Hetzner **API token** (Project → Security → API Tokens) as a TAPPaaS secret — a credential that can create *and destroy* servers and incur cost. Operators who accept that trade enable it by providing the token; `satellite-manager` then allocates and provisions in one command via the `hcloud` CLI/API:

```bash
# satellite-manager install <name>  internally does, roughly:
hcloud server create --name satellite-<name> \
  --type cax11 --image debian-12 --location <loc> \
  --ssh-key <tappaas-key>                    # (optional) --user-data-from-file cloud-init.yml
# → wait for IP / SSH ready, then:
nix run github:nix-community/nixos-anywhere -- \
  --flake .#satellite-<name> --target-host root@<new-ip> --build-on-remote
# → read back wg pubkey, wire the edge zone + os-wireguard peer, set DNS, verify (steps 3–6)
```

This collapses provisioning to: **one API token (once) + one `satellite-manager install` command**. Allocation, OS conversion, tunnel, zone wiring, DNS, and verification are all driven from `tappaas-cicd`; the operator never hand-configures the box. The same `hcloud` token also enables clean teardown (`hcloud server delete`) in §5.6 — making even VPS destruction automatable for Hetzner specifically (the generic case stays manual).

> _Note on `nixos-anywhere` host-key/secret planting:_ it supports `--extra-files` and `--copy-host-keys`, which is how a persistent SSH host key (no `known_hosts` churn across rebuilds) and any first-boot material are placed into the installed system. The WireGuard private key is **not** planted this way — it is generated on the node (step 3) to keep the private key on-host.

#### 5.4 Secrets — WireGuard keys

WireGuard confidentiality rests on the private keys never leaving their node. Each end generates its own keypair locally; the satellite's private key lives only on the satellite, OPNsense's only on OPNsense. The exchanged **public** keys and the satellite's connection metadata are stored as TAPPaaS secrets under the existing identity/secrets model ([40-Identity](../../src/foundation/identity/), ADR-006) — not committed in cleartext. Key **rotation** = regenerate on one end, re-exchange public keys, re-reconcile; the declarative model makes this a config change rather than hand-surgery.

#### 5.5 Update

Updates are declarative, same shape as `update.sh`/`update-os.sh` elsewhere: edit `satellite.nix`, then the satellite applies the new config. **This is pull-based for every satellite** (uniform isolation, §7.3) — the satellite `autoUpgrade`s from a pinned/signed ref rather than `tappaas-cicd` SSHing in, so a compromised cluster cannot push it malicious config. Because the satellite holds no app state, a botched rebuild is recoverable by redeploy.

#### 5.6 Decommission

`satellite-manager remove <name>` reverses provisioning: tear down the OPNsense `os-wireguard` peer, remove the `edge` zone and reconcile, revert the public DNS record, and forget the secrets. **Destroying the VPS itself is provider-side and stays manual** (out-of-band, the operator's cloud account) — TAPPaaS removes only what it created (tunnel, zone, DNS, config). Removing the satellite must cleanly fall back to the prior reachability model (direct public IP, or none).

#### 5.7 Foundation placement & numbering

Proposed as an **optional foundation module, `45-satellite`** (after `40-Identity`) — it is foundation-grade networking/backup infrastructure, but unlike `05–40` it is **not mandatory**: a site with a real public IP needs no satellite. Dependencies: requires `10-firewall` (zones + `os-wireguard` + Caddy) and `30-tappaas-cicd` (orchestration); the optional backup role additionally requires `35-backup`.

> _Alternative placement:_ treat it as an `apps/` module since it is optional and externally hosted. Rejected for v1 because it provisions foundation-level network ingress and edits `zones.json`/firewall — squarely foundation concerns — not an application workload.

#### 5.8 The passthrough forwarder — nginx `stream` (decided)

The satellite's TCP relay is **nginx** using the `stream` module (`ssl_preread` available for SNI). **HAProxy** is the sanctioned alternative.

Framing that drives the choice:

- The satellite **never terminates TLS**. For a single home cluster it is a **plain L4 passthrough** — *all* `:443` traffic goes to the one backend (Caddy-on-OPNsense over the tunnel), and Caddy does the real per-host routing. **SNI inspection is not needed in v1**; it only becomes relevant if one satellite fronts **multiple** sites/tunnels (a future multi-tenant case), which `ssl_preread` + a `map` covers without a redesign.
- **Hard requirement (any tool): PROXY protocol v2.** The relay must prepend the real client IP (`proxy_protocol on;` in nginx `stream`; Caddy configured to trust it) — otherwise Caddy sees the satellite's tunnel IP and **ADR-005's per-zone ACLs and access logs break**.

Why nginx over the alternatives:

| Tool | Verdict |
| ---- | ------- |
| **nginx (`stream`+`ssl_preread`)** ✅ | First-class nixpkgs module; the *same* daemon relays both `:443` and `:80`; `proxy_protocol` for client-IP; `ssl_preread` in reserve for multi-site; tiny, mature, auditable static config. |
| **HAProxy** (alt) | Purpose-built L4 proxy, cleanest SNI switching + best stats; entirely acceptable. Loses on a tie-break: its own config DSL and a separate daemon for `:80`. |
| **Caddy layer4** ❌ | Third-party, pre-1.0 plugin → custom build (xcaddy); weak "consistency" benefit since we deliberately *don't* terminate TLS here. |
| **Traefik** ❌ | Built around dynamic service discovery (irrelevant for static config-as-data); heaviest surface; overkill for fixed passthrough. |

### 6. Administrative access — WireGuard via the satellite (`admin-vpn` role)

The `admin-vpn` role gives the operator the **whole management plane** from anywhere — node Proxmox UIs (`tappaas1/2/3:8006`), OPNsense's UI, PBS (`:8007`), and SSH to any host — even with no public IP at home. Per-port TCP passthrough does not scale to that; **WireGuard** does. The design keeps the satellite a *blind relay*, consistent with §2/§3.

#### 6.1 Where the admin tunnel terminates — OPNsense, not the satellite (decided)

The admin's WireGuard session terminates on **OPNsense** (the cluster's router/firewall), which lands admins in a dedicated **`admin` overlay zone** — modeled on the existing `netbird` zone (`type: Overlay`, `state: Manual`, `vlantag: 0`) — whose `access-to` grants the management plane. The **satellite only relays UDP**; it never terminates the admin tunnel and holds none of its keys.

#### 6.2 How the relay works (Option B — blind UDP relay)

The admin laptop runs a normal WireGuard config with `Peer = OPNsense` but `Endpoint = satellite:adminWgPort`. The satellite statefully **UDP-forwards** `adminWgPort` down the infra tunnel to OPNsense's admin-WG listener (which is reachable only over that tunnel, since home has no public IP). Result: the admin↔OPNsense WireGuard session is **end-to-end encrypted**; the satellite forwards opaque UDP and cannot read or impersonate it — the same blind-relay property as TLS passthrough.

```text
 admin ──WG (admin↔OPNsense, e2e)──▶ satellite:adminWgPort/udp ──(blind fwd, rides infra tunnel)──▶ OPNsense WG
                                                                                                        │ terminates
                                                                                                        ▼
                                                                            `admin` overlay zone ──▶ mgmt plane
                                                                            (:8006 nodes, OPNsense UI, PBS, SSH)
```

- **MTU:** the relayed admin WG is double-encapsulated on the satellite→OPNsense hop (admin WG inside the infra WG). The admin-side WireGuard MTU must be lowered accordingly (~1340 or below — tune during implementation).
- **Reachability of OPNsense's WG listener from the satellite:** granted by the single `edge → OPNsense admin-WG` allowance in §4.3; nothing else in the cluster is exposed to `edge`.

#### 6.3 Rejected alternative — satellite as a WireGuard *hub*

Letting the admin peer **with the satellite**, which then decrypts and routes into the cluster, is simpler (no double-encap, no UDP-forward) but makes the satellite **terminate the admin tunnel** — it would see admin traffic in cleartext at the WG layer (only per-service TLS/SSH still protecting content). Rejected for the same reason as terminate-at-satellite TLS (§2): an off-premises node must not sit inside the cleartext/trust path. Recorded so the trade-off is on the record.

#### 6.4 Minimal sub-mode — SSH-only passthrough

For "just a shell on the mothership" without running a WireGuard client, the satellite can additionally expose an optional `:sshPort/tcp` **passthrough to `tappaas-cicd:22`** (SSH key auth + host-key check terminate on `tappaas-cicd`; satellite stays blind). This is a convenience sub-mode of `admin-vpn`, not the primary path — it reaches only `tappaas-cicd`, not the full management plane.

#### 6.5 Relationship to NetBird

`admin-vpn` covers the **single-operator** admin case with **plain WireGuard and no control plane** — strictly better than NetBird on the no-commercial-dependency axis (goal #2). NetBird stays the answer for many-peer mesh, site-to-site fabric, or any-peer-to-any-zone topologies. They coexist (both WireGuard) and are independent; a site can run either, both, or neither.

### 7. Secrets inventory & compromise isolation

This section answers two questions: **what secrets exist, where, and for how long**; and **how a fully-compromised home cluster is prevented from destroying the off-site backup** — the property that gives the backup role its entire value.

#### 7.1 Secrets inventory

Following the existing TAPPaaS convention (no central vault; secrets live in `/etc/secrets/` mode-600 and are generated in place — cf. [identity.nix](../../src/foundation/identity/identity.nix), [tappaas-cicd install](../../src/foundation/tappaas-cicd/)). Public keys are config, not secrets, and are omitted.

| # | Secret | Generated | Stored at | Lifecycle / rotation | If leaked |
| - | ------ | --------- | --------- | -------------------- | --------- |
| 1 | Satellite **infra-tunnel** WG private key | on satellite, first boot | satellite only | per-satellite; rotate = regen + re-exchange pubkey | impersonate satellite to home (home still only exposes role endpoints) |
| 2 | OPNsense **infra-tunnel** WG private key | on OPNsense | OPNsense only | rotate with #1 | impersonate home end |
| 3 | Satellite **SSH host key** | on satellite (persisted via `--copy-host-keys`) | satellite only | stable across rebuilds; rotate = reprovision | MITM of satellite management SSH |
| 4 | **Operator management key** authorized on the satellite | operator workstation / hardware token | **operator only — NOT on the cluster** | operator-controlled | full satellite root (see §7.3 — kept off the cluster on purpose) |
| 5 | Home-PBS **read-only sync token** (`Datastore.Read`/`Audit`) | home PBS | satellite's PBS remote config | per-satellite; revocable at home | read **ciphertext** home backups; cannot delete/decrypt |
| 6 | Satellite PBS local admin credential | satellite PBS | satellite only | local | control satellite datastore (still bounded by §7.3) |
| 7 | **Client-side backup encryption key** (DR linchpin) | home | **home** `/etc/secrets` + independent offline copy | long-lived; rotation re-encrypts | read/forge backup *content*; **loss = unrecoverable DR** |
| 8 | OPNsense **admin-WG** server key + admin client keys | on each device | OPNsense / admin laptops | per-device; revoke at OPNsense | join the admin VPN (still authenticates to OPNsense) |
| 9 | _(opt-in, Tier B)_ **Hetzner API token** | Hetzner portal | tappaas-cicd secret | **provision/teardown only — see §7.3** | create **and destroy** the VPS, incur cost |
| 10 | DNS provider API credential | existing | tappaas-cicd (reused from DNS-01) | existing lifecycle | alter public DNS records |
| 11 | _(transient)_ Satellite **provisioning credential** | per-install | ephemeral — see §7.3 | **revoked after install** | root on satellite *during* install only |

Roughly **eleven** credentials, but only **four live on the satellite** (#1, #3, #5, #6) and none of those can decrypt or delete the home-held data. The DR linchpin (#7) and the destroy-capable token (#9) live at home — and §7.3 governs how they (and the management path) are kept away from an attacker.

#### 7.2 Trust directions — data plane is already safe

The backup *data* path is isolated **by direction**, independent of any host hardening:

- **Satellite pulls; home holds no write/delete credential to the satellite datastore** (§3.1). Via the PBS protocol, a compromised home **cannot** erase the off-site copy.
- The satellite holds only a **read-only** token to home (#5) and **no decryption key**. A compromised satellite can read ciphertext, nothing more.
- Backups are **client-side encrypted at home** (#7); the satellite stores ciphertext.

Net: neither end's credentials let it destroy the other's data **over the backup protocol**. The residual risk is therefore entirely the **management plane** — can a compromised cluster get *root* on the satellite by another path?

#### 7.3 Compromise isolation — keeping a hacked cluster out of the vault (decided direction)

The threat: `tappaas-cicd` is the cluster's highest-value target (it already holds a root SSH key distributed to every node). If the satellite were managed the same way — **standing root SSH from `tappaas-cicd`** — then *compromise of the mothership = root on the vault = backups wiped and VPS destroyed*. That must be impossible. Five rules enforce it:

1. **No standing inbound management credential from the cluster.** `tappaas-cicd` does **not** hold a persistent root key on the satellite. This is the single most important rule and the deliberate exception to the normal "cicd manages everything" model (goal #4 yields to security here, for every satellite — see §7.3 uniform-application note).
2. **Provisioning credential is ephemeral (#11).** Install-time root access is operator-initiated and **revoked once provisioning completes**; the only key left authorized is the operator's out-of-band key (#4), which lives on an operator workstation/hardware token, never on the cluster.
3. **Updates are pull-based, not pushed.** The satellite runs NixOS `autoUpgrade` pulling a **pinned, signed** config ref; the cluster cannot forge a config the satellite will accept (signing key off-cluster). The satellite reaches out; nothing reaches in to manage it. (Revises §5.5's "remote `nixos-rebuild` from cicd".)
4. **Management is one-directional over the tunnel.** The satellite's **host firewall** forbids the home/tunnel side from reaching the satellite's SSH or PBS-admin. The infra tunnel carries satellite→home pulls and relayed public ingress only — it is **not** a path for home to administer the satellite.
5. **Local immutable history on the satellite.** The satellite keeps **local ZFS snapshots** of its datastore on a schedule that requires *local* root to delete. Even an attacker who somehow obtained the read-only sync token (#5) cannot rewrite history; deletion needs satellite root, which §7.3.1–4 keep away from the cluster.

Plus, for the destroy-capable **Hetzner token (#9)**: it is **never standing on the mothership** — supplied only for an operator-initiated provision/teardown and not persisted (a compromised cluster therefore cannot `hcloud server delete` the vault). Hetzner tokens cannot be scoped to "no delete", so non-persistence is the only real control.

**Result:** a total home-cluster compromise can, at worst, **stop new backups flowing** and read its own (already-held) data. It **cannot** reach back to delete, encrypt, or destroy the existing off-site history or the VPS. The vault survives the thing it exists to survive.

> **Uniform application (decided).** These rules apply to **every satellite**, regardless of role — not just backup-role ones. Rationale: one mental model ("a satellite is always semi-trusted and self-managing; the cluster never holds standing root over it") is far easier to reason about and audit than per-role management trust, and it removes any risk of a relay satellite later gaining the backup role while still carrying relaxed, cluster-rootable management. This is a deliberate, accepted departure from goal #4's "managed from `tappaas-cicd`" convenience for **all** satellites.

---

## Consequences

_Positive, negative, and neutral consequences of this decision. New trust assumptions, operational burden, failure modes._

---

## Alternatives Considered

- _..._

---

## Implementation Plan (phased)

_High-level phases / milestones._

---

## Testing Strategy

_How correctness and resilience (failover, restore) are verified._

---

## Acceptance

- [ ] _..._
