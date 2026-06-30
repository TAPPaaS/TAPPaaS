# NetBird macOS Client — Sequoia Setup & mgmt Zone Access

## Problem

NetBird daemon failed to start on macOS Sequoia (Darwin 25/26). The client could not connect to management zone via OPNsense routing peer.

**Symptoms:**
- `netbird status` → `dial unix /var/run/netbird.sock: connect: no such file or directory`
- `sudo launchctl bootstrap system /Library/LaunchDaemons/netbird.plist` → `Bootstrap failed: 5: Input/output error`
- Process could not be quit via normal means

## Root Cause

Two compounding issues:

**1. BTM (Background Task Management) blocking the LaunchDaemon**

macOS Sequoia enforces background task approval via `backgroundtaskmanagementd`. The NetBird LaunchDaemon was being rejected because:
- `BTMConfigBundleIdentifiers = ()` — plist lacked `AssociatedBundleIdentifiers` key
- Conflicting BTM registrations: old "Wiretrustee UG" entry (legacy company name) vs new "NetBird GmbH" signing identity
- BTM was actively removing the NetBird GmbH registration

Diagnosed via:
```sh
log show --predicate 'eventMessage contains[c] "netbird"' --last 2m --info
# Output: removing uuid=..., name=NetBird GmbH, type=developer
```

**2. LaunchDaemon plist used symlink instead of real binary path**

```xml
<!-- Wrong (symlink): -->
<string>/usr/local/bin/netbird</string>

<!-- symlink resolves to: -->
<!-- /usr/local/bin/netbird -> /Applications/NetBird.app/Contents/MacOS/netbird -->
```

macOS Sequoia launchd does not reliably follow symlinks in `ProgramArguments` for system daemons.

## Solution

**Do not use the LaunchDaemon for desktop Mac.** Use the NetBird.app directly:

1. **Register as User Device via SSO** (not setup key):
   - Open `/Applications/NetBird.app`
   - Log in with your account (iCloud/SSO)
   - This creates a User Device entry in the NetBird dashboard, not a Server

2. **Add to Login Items** for auto-start:
   - System Settings → General → Login Items & Extensions → Open at Login → add NetBird.app

3. **Connect** via menu bar icon or:
   ```sh
   netbird up
   ```

The LaunchDaemon approach is for headless servers (OPNsense, LXC containers), not for macOS desktop clients.

## NetBird Dashboard Configuration

### Peers

| Device | Type | Group | NetBird IP |
|---|---|---|---|
| Mac.home.internal | User Device | mgmt | 100.70.x.x |
| iPad-podium87.toothy | User Device | mgmt | 100.70.x.x |
| iPhone-podium87.toothy | User Device | mgmt | 100.70.x.x |
| OPNsense.internal | Server | OPNsense | 100.70.167.222 |

### Groups

| Group | Purpose | Members |
|---|---|---|
| `mgmt` | Client devices with mgmt zone access | Mac, iPad, iPhone |
| `OPNsense` | Gateway peer | OPNsense |
| `All` | Default | All peers |

### Network Routing

- **Network:** TAPPaaS OPNsense Network
- **Resource:** `10.0.0.0/24` (TAPPaaS OPNSense Subnet — hardened from /8 on 2026-06-26)
- **Routing Peer:** opnsense (100.70.167.222)
- **High Availability:** Inactive (single peer)

### Access Control Policy

**TAPPaaS OPNSense Subnet Policy:**
- Sources: `mgmt`
- Destinations: TAPPaaS OPNSense Subnet (10.0.0.0/24)
- Protocol: ALL
- Ports: ALL
- Direction: → (clients initiate)

## Connectivity

- OPNsense reachable via NetBird tunnel: `ping 100.70.167.222` ✓
- mgmt zone gateway: `ping 10.0.0.1` ✓
- Internal DNS: `10.0.0.1:53` for `*.mgmt.internal` ✓
- OPNsense web GUI: `https://firewall.mgmt.internal:8443` ✓
- Tunnel type: P2P (direct, not relayed)
- Latency: ~7ms

## NetBird Versions

| Component | Version |
|---|---|
| macOS daemon | 0.75.0-rc.2 |
| OPNsense module | 0.70.0+ |
| iOS/iPadOS client | 0.70.4+ |

## Remaining Issue — Daemon Persistence After Reboot

The NetBird.app starts the daemon when opened. If added to Login Items, it auto-starts on login. However, BTM approval may need to be re-granted after a fresh macOS install or major update.

If the daemon does not start after reboot:
```sh
# Verify app is in Login Items:
# System Settings → General → Login Items → NetBird ✓

# Manual start:
open /Applications/NetBird.app
netbird up

# Check status:
netbird status
```

## Cleanup Done

- Deleted stale `macbook-pro-van-erik-2` User Device (duplicate, 2 days old)
- Deleted `mac` Server peer (registered with setup key, superseded by User Device)
- Old setup keys (one-off, used): tappaas-airouter, tappaas-ai-chat-permanent, NetBird-PVEhost — can be removed from Setup Keys

## Hardening — 2026-06-26: NetBird route versmald naar mgmt zone

**Probleem:** NetBird Network Route was geconfigureerd als `10.0.0.0/8`, waardoor alle TAPPaaS zones (srv 10.2.x, home 10.3.x, iot 10.4.x, guest 10.5.x, dmz 10.6.x) direct bereikbaar waren via de tunnel. Dit ondermijnt het zone-model.

**Fix (server-side, alle clients automatisch):**
1. NetBird dashboard → Network Routing → TAPPaaS OPNSense Subnet: `10.0.0.0/8` → `10.0.0.0/24`
2. OPNsense → Firewall → Rules → OPT1: destination `10.0.0.0/8` → `10.0.0.0/24`

**Architectuur na fix:**
```
Mac/iPad/iPhone → NetBird → 10.0.0.0/24 (mgmt only)
                              └─ tappaas-cicd (10.0.0.246) ProxyJump
                                  └─ andere zones via OPNsense firewall rules
```

**Testresultaten:**

| Check | Resultaat |
|---|---|
| `ping 10.0.0.1` | ✓ bereikbaar |
| `ping 10.0.0.246` (tappaas-cicd) | ✓ bereikbaar |
| `route get 10.2.0.1` (srv) | ✓ via en0 (LAN), NIET via NetBird |
| `route get 10.4.10.1` (iotLocal) | ✓ via en0, NIET via NetBird |
| Traversal via tappaas-cicd ProxyJump | ✓ netwerk OK |
| VS Code Remote SSH tappaas-cicd | ✓ |

---

## Incident 2026-06-26 — OPNsense direct op ONT, mgmt zone onbereikbaar

### Probleem

Na het omzetten van OPNsense van ISP-router naar directe ONT-verbinding (double NAT verwijderd) was de mgmt zone (10.0.0.0/8) niet meer bereikbaar via NetBird. VS Code kon niet verbinden met `tappaas-cicd`.

**Symptomen:**
- `ping 10.0.0.1` → 100% packet loss
- NetBird toont OPNsense als "Connected" maar `NO_RECENT_HANDSHAKE` op DNS
- VS Code Remote SSH naar `tappaas-cicd` time-out

**Root cause:**

De NetBird WireGuard interface (`wt0`) is in OPNsense toegewezen als `OPT1`. Na de herconfigurie had `OPT1` **geen firewall rules** — OPNsense blokkeert standaard al het verkeer als er geen rules zijn op een interface.

### Oplossing

**1. Firewall rule toegevoegd op OPT1 (Firewall → Rules → OPT1):**

| Veld | Waarde |
|---|---|
| Action | Pass |
| Interface | OPT1 |
| Direction | in |
| Protocol | any |
| Source | any |
| Destination | 10.0.0.0/8 |
| Description | NetBird clients → mgmt zone only |

Least privilege: alleen mgmt zone (10.0.0.0/8) als destination, niet `any/any`.

**2. Interface flags OPT1 (Interfaces → OPT1):**

- `☐ Block private networks` — **uitgevinkt** (tegengesteld aan WAN)
- `☐ Block bogon networks` — **uitgevinkt** (tegengesteld aan WAN)

NetBird overlay gebruikt `100.70.x.x` (RFC 6598 shared address space, valt buiten RFC1918 maar kan als bogon worden beschouwd). Beide flags uitzetten op tunnel interfaces.

**3. Interface IP configuratie:**

`wt0` is een tunnel interface — **geen IP configuratie nodig** (`IPv4/IPv6 Type: None`). OPNsense geeft een foutmelding als je toch een IP probeert toe te wijzen; dit is expected behaviour en mag genegeerd worden.

### Audit resultaat na fix

| Check | Resultaat |
|---|---|
| NetBird OPNsense tunnel | P2P Connected ✓ |
| `10.0.0.1` (mgmt gateway) | Bereikbaar ✓ |
| `10.0.0.246` (tappaas-cicd) | Bereikbaar ✓ |
| DNS `tappaas-cicd.mgmt.internal` | Resolves ✓ |
| SSH tappaas-cicd | Connected ✓ |
| VS Code Remote SSH | Werkt ✓ |

Note: `ping 100.70.167.222` (OPNsense NetBird overlay IP) blijft 100% packet loss — OPNsense blokkeert ICMP op eigen interfaces, dit is normaal gedrag.

---

**Status:** ✅ Working  
**Date:** 2026-06-19 (initial) / 2026-06-26 (ONT incident)
**Affects:** macOS Sequoia (Darwin 25.x / 26.x) + NetBird 0.72.x + OPNsense 26.1
