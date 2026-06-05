# DNS Manager IP Drift Investigation

**Date:** 2026-06-04
**Status:** Investigation complete, solution pending
**Related Issues:** NixOS hostname vs DHCP timing

> **2026-06-05 addendum — Option 2 (NixOS boot order) investigated.** Several
> premises in the original write-up below turned out to be stale once the live
> firewall was inspected (DNS for VMs already resolves from DHCP leases, not
> from `dns-manager` static pins; `regdhcp=0` is a red herring). The full
> findings, a feasibility verdict on Option 2, and how it relates to GitHub
> issues **#302** and **#309** are in the
> **[Option 2 Investigation (2026-06-05)](#option-2-investigation-2026-06-05)**
> section at the end of this document. Read that section first — it supersedes
> the "Recommended Solution" above.

## Summary

The `dns-manager` tool creates static DNS host entries in OPNsense's Dnsmasq service. These entries do NOT include MAC address bindings, which means VMs can receive different IPs from DHCP on reboot, causing DNS entries to become stale.

## Background

### Why dns-manager Exists

NixOS VMs have a hostname timing problem during bootstrap:

1. The NixOS template (`tappaas-common.nix`) has hardcoded hostname `tappaas-nixos`
2. NetworkManager brings up the network and sends DHCP request with wrong hostname
3. Cloud-init runs AFTER network is up and sets the correct hostname
4. By then, Dnsmasq has already registered the wrong hostname (if auto-registration were enabled)

To work around this, TAPPaaS:
- Disables Dnsmasq auto-registration (`regdhcp=0` in firewall template)
- Uses `dns-manager` to explicitly create DNS entries with correct hostname after VM is configured

### How dns-manager Works

- **Location:** `src/foundation/tappaas-cicd/opnsense-controller/src/opnsense_controller/dns_manager_cli.py`
- **What it creates:** Dnsmasq "host overrides" with hostname, domain, and IP
- **What it does NOT create:** MAC-based DHCP reservations

### Where dns-manager is Called

1. **VM Install** (`cluster/services/vm/install-service.sh:264-267`)
   - After VM gets IP via DHCP
   - Creates DNS entry for the new VM

2. **VM Update** (`cluster/services/vm/update-service.sh:379-392`)
   - After zone migration
   - Registers new DNS entry and cleans up old one if zone changed

## The Problem: IP Drift

If a VM reboots later and DHCP assigns a different IP:
- The static dns-manager entry still points to the **old IP**
- DNS resolution returns wrong IP
- Services become unreachable by hostname

This can happen because:
- dns-manager entries have no MAC address (no DHCP reservation)
- DHCP pool can assign any available IP to any client
- VM might get different IP if old lease expired or pool changed

## Current Mitigations

1. **Long DHCP lease times** - Default lease is typically 24h-7d, reducing frequency of IP changes
2. **Small pools** - If DHCP pool is small and mostly static, IPs tend to stay the same
3. **VM seldom reboot** - In practice, TAPPaaS VMs rarely reboot

## Potential Solutions

### Option 1: DHCP Static Reservations (MAC → IP binding)

Modify dns-manager or create a separate tool to:
- Query VM's MAC address from Proxmox
- Create Dnsmasq static mapping with MAC + IP
- VM always gets same IP regardless of boot order

**Pros:** Deterministic IPs, no drift possible
**Cons:** Requires knowing MAC at install time (available from Proxmox API)

### Option 2: Fix NixOS Boot Order

Modify cloud-init or NixOS config to set hostname BEFORE NetworkManager starts:
- Use cloud-init's `bootcmd` to set hostname early
- Or configure NetworkManager to wait for hostname

**Pros:** Enables Dnsmasq auto-registration, simpler architecture
**Cons:** Requires changes to NixOS template and cloud-init

### Option 3: dns-manager with MAC Binding

The `DhcpHost` dataclass already has a `mac` field:
```python
@dataclass
class DhcpHost:
    description: str
    host: str
    ip: list[str]
    domain: str = ""
    mac: str = ""  # Already exists but unused!
```

Modify install-service.sh to:
1. Query MAC from Proxmox: `qm config $VMID | grep net0`
2. Pass MAC to dns-manager when creating entry
3. Dnsmasq then binds MAC → IP

**Pros:** Minimal changes, uses existing infrastructure
**Cons:** Requires Proxmox API call during install

### Option 4: Periodic Reconciliation

Add a cron job or update-tappaas check that:
- Queries current VM IPs from Proxmox guest agent
- Compares with dns-manager entries
- Updates any mismatches

**Pros:** Self-healing, catches drift automatically
**Cons:** Reactive not preventive, brief outage during drift period

## Recommended Solution

**Option 3 (dns-manager with MAC binding)** is the cleanest solution:

1. MAC address is available from Proxmox at install time
2. The `DhcpHost` dataclass already supports it
3. Dnsmasq handles MAC → IP binding natively
4. No changes to NixOS template needed

### Implementation Steps

1. Update `install-service.sh` to query MAC from Proxmox
2. Pass `--mac` argument to dns-manager
3. Update `dns_manager_cli.py` to accept and use MAC field
4. Update `DhcpManager.create_host()` to include MAC in API call
5. Test with VM reboot to verify IP persistence

## Files Involved

| File | Purpose |
|------|---------|
| `dns_manager_cli.py` | CLI for DNS management |
| `dhcp_manager.py` | API client, has `DhcpHost` with unused `mac` field |
| `install-service.sh` | VM install, calls dns-manager |
| `update-service.sh` | VM update, calls dns-manager |
| `tappaas-common.nix` | NixOS template with hostname timing issue |
| `firewall-config.xml.template` | Has `regdhcp=0` disabling auto-registration |

## Testing Plan

1. Identify a test VM
2. Note its current IP and MAC
3. Implement MAC binding in dns-manager
4. Re-register VM with MAC
5. Reboot VM
6. Verify it gets same IP
7. Verify DNS resolves correctly

## Related Documentation

- Dnsmasq static hosts: `dhcp-host=<mac>,<ip>,<hostname>`
- OPNsense DHCP static mappings: Services → DHCPv4 → Static Mappings
- Proxmox guest agent: `qm guest cmd <vmid> network-get-interfaces`

---

# Option 2 Investigation (2026-06-05)

**Scope:** Investigate "Option 2: Fix NixOS Boot Order" (above) and its
relationship to GitHub **#302** (`update-service` doesn't re-register DNS unless
the zone changes) and **#309** (`templates:nixos` silent half-install / fresh-zone
timing race). Findings are backed by reading the install pipeline end-to-end and
by inspecting the **live** OPNsense firewall and DHCP lease table.

## TL;DR

- **Option 2 is feasible and is the right long-term fix**, but for a reason
  different from the one the original doc gives. The IP-drift problem it was
  meant to solve **largely does not exist** in the current architecture; what
  Option 2 actually fixes is the **"VM is leased/known under the wrong name"**
  failure that produces the user-visible symptoms in #302 and #309.
- **DNS for DHCP VMs already works "via masqdns / DHCP allocation"** — exactly
  what #302's last comment says it *should* do. It is **not** driven by
  `dns-manager` static pins today. So the architecture lars wants is already
  ~90% in place; the gap is purely *getting the correct hostname into the very
  first DHCP lease*.
- Recommended concrete change: **template `networking.hostName = lib.mkDefault ""`**
  so cloud-init's `local-hostname` (which Proxmox already injects as `--name
  <vmname>`) sets the hostname before the first DHCP request, instead of the
  baked-in `tappaas-nixos`. Keep `fix_dhcp_hostname` as a belt-and-suspenders
  during the transition. Needs one deep-test to confirm NixOS+cloud-init
  ordering (see Test Plan).

## What was actually verified on the live system

Inspected `firewall.mgmt.internal` (`/conf/config.xml`, running dnsmasq,
`/var/db/dnsmasq.leases`, `/var/etc/dnsmasq-hosts`) and the cicd resolver:

1. **dnsmasq is the integrated DHCP+DNS server.** Its config defines the DHCP
   ranges directly (`domain=mgmt.internal,10.0.0.100,10.0.0.254`, …) and runs
   with `dhcp-authoritative` + `dhcp-fqdn`. In this mode dnsmasq **natively
   answers DNS for current DHCP leases** — no separate registration step needed.

2. **`regdhcp=0` is a red herring.** `regdhcp`/`regdhcpstatic` are legacy
   *"register DHCP leases in the DNS Forwarder/Unbound"* toggles. They do **not**
   govern dnsmasq's own lease resolution. The original doc's central claim
   ("Dnsmasq auto-registration is DISABLED → that's why dns-manager exists") is
   incorrect for the current setup.

3. **VM names resolve from leases, not from static pins.** `identity`,
   `logging`, `nixos` all resolve (`identity.mgmt.internal → 10.0.0.186`, etc.)
   yet appear **only** in the lease table — `<hosts>` count in `config.xml` is
   `0`, and `/var/etc/dnsmasq-hosts` contains **only the static infrastructure**
   (firewall, `tappaas1..9`, `backup`). Those static entries come from the
   `firewall:dns` service for fixed-IP hardware — *not* from VM installs.

4. **The lease table shows the boot-order problem directly:**

   ```
   10.0.0.161 02:ce:c7:6b:3b:fe  test-debian      ← correct name (after fix)
   10.0.0.238 02:8c:a9:b3:ee:3d  *                ← NO hostname sent
   10.0.0.162 02:81:16:e7:14:0e  tappaas-cicd
   10.0.0.186 02:fe:a1:ad:01:66  identity
   10.0.0.207 6c:1f:f7:67:a4:67  nixos
   ```

   The `*` lease is a VM that leased an IP **without** ever sending its real
   hostname. A name that never reaches a lease never resolves — this is the
   actual user-facing failure behind #302/#309 ("502 on proxy domain", "name
   doesn't resolve"), **not** IP drift.

## How the hostname actually gets set (corrects the original doc)

The original doc says cloud-init sets the hostname. For TAPPaaS NixOS VMs that
is **not** how the final hostname is set:

| Stage | What sets the hostname | Value |
|-------|------------------------|-------|
| Template image | `networking.hostName = lib.mkDefault "tappaas-nixos"` in `tappaas-common.nix` (declarative, baked into the image) | `tappaas-nixos` |
| Proxmox cloud-init | `qm set --name <vmname>` → cloud-init `local-hostname` (`Create-TAPPaaS-VM.sh:639-646`) | correct, but **overridden** by the NixOS declarative value |
| Install pipeline | `nixos-rebuild switch` applies the consumer overlay `<vmname>.nix`, which sets `networking.hostName = "<vmname>"` (`update-os.sh:update_nixos`) | correct — but only **after** first boot + DHCP |
| Post-rebuild | `fix_dhcp_hostname()` sets `nmcli ipv4.dhcp-hostname=$(hostname)` + `device reapply` → re-sends DHCP with the now-correct name (`update-os.sh:376-423`) | correct — re-leases under the right name |

So the real hostname is **declarative (the overlay)**, applied late, and the
correct DHCP lease only happens at the very end via the `fix_dhcp_hostname`
nmcli reapply. The sequence that bites us:

1. Clone boots as `tappaas-nixos` → **first DHCP lease is under the wrong name.**
2. `nixos-rebuild` applies the overlay (sets real hostname) and reboots.
3. `fix_dhcp_hostname` re-applies DHCP → lease corrected to `<vmname>`.

If step 2 fails (**#309**, fresh-zone `nixos-rebuild` race), steps 2–3 never
complete, the VM stays `tappaas-nixos` (or `*`), and the real name never
resolves. If step 3 is skipped/raced, you get the `*` lease seen above.

> Note: `update-os.sh` already contains a **3× `nixos-rebuild` retry with settle
> + `wait_for_ssh`** (lines ~312-338) and the `run_quiet`/`PIPESTATUS` fix from
> #201, so part of #309's "concrete ask 3" is already implemented. The
> still-open #309 asks are (1) **surface the real stderr** on failure (today
> `run_quiet` collapses it to dots and `die`s with only an exit code) and
> (2) tighten the post-SSH `cloud-init status --wait` + `sudo -n true` gate.

## What Option 2 actually buys (re-framed)

Because DNS already resolves from leases, Option 2's value is **not** "avoid IP
drift" (drift self-heals — a fresh lease always re-resolves to the current IP).
Its value is **getting the correct name into the first lease**, which:

- Makes a VM resolvable **immediately at boot**, with no dependency on the
  fragile post-rebuild `fix_dhcp_hostname` reapply.
- Makes DNS correct **even when `nixos-rebuild` fails** (#309) — the operator
  then sees an honest "service not responding" instead of a misleading
  "name doesn't resolve / 502" two steps removed from the root cause.
- Eliminates the stale `*` / `tappaas-nixos` leases.
- Is the prerequisite for eventually **retiring** the `fix_dhcp_hostname` nmcli
  dance and the residual `dns-manager` VM pins (Windows path, zone-change path).

It does **not** by itself fix #309's `nixos-rebuild` race — that remains an
`update-os.sh` hardening task — but it removes the worst *symptom* (silent wrong
DNS) and decouples "is the VM addressable?" from "did the overlay apply?".

## Recommended implementation (Approach A)

Set the hostname from cloud-init metadata **before** NetworkManager sends its
first DHCP request, and let the consumer overlay converge to the same value:

1. **Template (`tappaas-common.nix`):** change
   `networking.hostName = lib.mkDefault "tappaas-nixos"` →
   `networking.hostName = lib.mkDefault ""`. An empty `hostName` tells NixOS not
   to force a hostname, allowing cloud-init's `cc_set_hostname`
   (`local-hostname`, already supplied by Proxmox `--name`) to own it.
2. **Keep the consumer overlay** setting `networking.hostName = "<vmname>"`. The
   value matches what cloud-init set, so the final declarative state is
   unchanged and there is no flip-flop — the only behavioural change is the
   *first-boot* name.
3. **Keep `fix_dhcp_hostname` for now** as a safety net (and for Debian/Ubuntu,
   which are unaffected by the NixOS change). Remove it only after the deep test
   proves the first lease is already correct across a few release cycles.

### Why not the alternatives
- **`bootcmd`/`hostnamectl` via `--cicustom` user-data** (the doc's literal
  Option 2): also works and is the most explicit, but requires threading a
  custom user-data snippet through `Create-TAPPaaS-VM.sh`, which today relies on
  Proxmox's auto-generated cloud-init. More surface area for the same result.
- **DHCP static reservations (Option 1/3, MAC→IP):** solves a drift problem that
  the lease model already solves; adds a Proxmox-MAC lookup to every install for
  little benefit now that VMs resolve from live leases.

### Risk to validate
NixOS + cloud-init hostname ordering is finicky. `cc_set_hostname` runs in the
`cloud-init.service` (network) stage; if it lands **after** NetworkManager's
first DHCP, the first lease could still be generic and we'd still depend on a
reapply. The deep test below determines whether the empty-`hostName` approach
sets the name early enough on its own, or whether we additionally need the
hostname set in the `cloud-init-local` (pre-network) stage.

## Relationship to the GitHub issues

- **#302** ("DNS not re-registered unless zone changes"): under the verified
  lease-based model, the "refresh" that matters is **making the VM re-send its
  hostname**, not a `dns-manager add`. `update-service` → `update-os.sh` already
  runs `fix_dhcp_hostname` on every update, so `update-module.sh <m> --force`
  *does* re-assert the lease name today (the proposed `dns-manager add` in the
  issue would only matter for the static-pin path). **Option 2 addresses #302 at
  the source** by making the name correct from boot. If Option 2 is deferred,
  the minimal #302 fix is to ensure `fix_dhcp_hostname` is reached on every
  update path (it is, for NixOS/Debian) and optionally add an idempotent
  `dns-manager add` fallback for guests whose agent never reports a hostname.
- **#309** ("templates:nixos silent half-install"): Option 2 removes the
  **misleading DNS symptom** but not the root `nixos-rebuild` race. The two
  remaining #309 asks (surface stderr; tighten the cloud-init/sudo gate) stay
  valid and are independent of Option 2.

## Test Plan (deep)

1. On a cluster with `test3` Inactive, branch the change to
   `tappaas-common.nix` (`hostName = ""`) and rebuild the NixOS template.
2. `install-module.sh test-nixos` (mgmt) and a fresh-zone NixOS fixture
   (e.g. `test-fw-c` in a just-activated zone).
3. **Before** `nixos-rebuild` runs, snapshot the lease table: assert the VM's
   first lease already carries `<vmname>`, **not** `tappaas-nixos`/`*`.
4. Confirm `<vmname>.<zone>.internal` resolves from cicd within seconds of boot,
   before the overlay is applied.
5. Force a `nixos-rebuild` failure (e.g. break the overlay) and confirm DNS
   *still* resolves to the right VM (symptom decoupled from overlay success).
6. Reboot the VM and confirm the lease/name persist (no regression vs. today).
7. Regression: repeat for `test-debian` (must be unaffected by the NixOS change).

## Files involved (current, verified paths)

| File | Role |
|------|------|
| `src/foundation/templates/tappaas-common.nix` | `networking.hostName = lib.mkDefault "tappaas-nixos"` ← the change |
| `src/foundation/cluster/Create-TAPPaaS-VM.sh` (≈634-647) | sets cloud-init `--name <vmname>`, `--ciuser`, `ip=dhcp` |
| `src/foundation/tappaas-cicd/scripts/update-os.sh` | `update_nixos` (overlay apply), `fix_dhcp_hostname` (nmcli reapply) |
| `src/foundation/templates/services/nixos/{install,update}-service.sh` | thin wrappers → `update-os.sh` |
| `src/foundation/cluster/services/vm/{install,update}-service.sh` | `dns-manager` pins (Windows path; zone-change path only — #302) |
| `firewall-config.xml.template` | `regdhcp=0` (legacy, irrelevant to dnsmasq lease resolution) |

## Bottom line

Adopt Option 2 via the one-line template change (`hostName = lib.mkDefault ""`),
gated behind the deep test above. It aligns the implementation with the
already-true "DNS via DHCP/masqdns" model, fixes the real #302/#309 *symptom*
(wrong-name / unresolvable VMs), and is the precondition for later deleting the
`fix_dhcp_hostname` and residual `dns-manager` VM-pinning workarounds. The
original Option 3 (MAC binding) is unnecessary — it targets an IP-drift problem
the integrated-dnsmasq lease model has already eliminated for DHCP VMs.

---

# Deep Test Results (2026-06-05) — branch `test/option2-nixos-boot-order`

Built the modified NixOS template image (`nix build .#image` from
`templates/flake.nix`) and tested fresh clones on the live cluster (throwaway
VMIDs 8081-8086, all destroyed afterwards; production template 8080 untouched).
DHCP lease names observed directly in `/var/db/dnsmasq.leases` on the firewall.

**The one-line change is necessary but NOT sufficient.** Five build/test
iterations were needed to land a working fix. Key empirical findings:

| # | Template variant | First DHCP lease | Notes |
|---|------------------|------------------|-------|
| baseline | current (`hostName="tappaas-nixos"`) | **`tappaas-nixos`** | wrong name baked in; only corrected by overlay+reboot; never if `nixos-rebuild` fails |
| v1 | `hostName=""` only | **`*`** (no name) | cloud-init *does* set the live hostname (`/etc/hostname=<vmname>`) independent of the overlay — but in its **network stage**, after NM's first DHCP |
| v2/v3 | `+` pre-network oneshot setting hostname from `instance-data.json` | **`*`** | dead end: at the pre-network stage `v1.local_hostname` is the cloud-init default `nixos` — Proxmox delivers the real name via cloud-init **user-data** (network stage), not meta-data |
| v4 | `+` post-cloud-init `nmcli down/up` | **`*`** | bounced the wrong profile, and NM sends the **static** hostname (empty under `hostName=""`) — not the live one |
| **v5** | `+` post-cloud-init: set `ipv4.dhcp-hostname` explicitly **then** full device re-acquire | **`*` → `<vmname>` at ~40s** | ✅ resolves from cicd; **survives reboot**; needs neither `nixos-rebuild` nor any cicd action |

### Decisive mechanism facts (verified live, not theorised)

- **NM sends the *static* hostname for DHCP option 12.** With `hostName=""` the
  static hostname is empty, so NM leases as `*` even though cloud-init has set
  the *live/transient* hostname correctly. The fix must set
  `ipv4.dhcp-hostname` explicitly on the connection profile.
- **A NetworkManager renew / `device reapply` does NOT change an existing
  lease's name** — only a full `device disconnect`/`connect` (fresh DISCOVER)
  does. **This means the existing `fix_dhcp_hostname` in `update-os.sh`, which
  uses `nmcli device reapply`, is ineffective at correcting a lease name on this
  NM version** (NixOS 25.11 / NM 1.52). That is a separate latent bug worth
  fixing regardless of Option 2.
- **cloud-init sets the correct hostname independent of the overlay.** This is
  the core #309 win: even when `nixos-rebuild` never applies, the bare template
  + cloud-init + the re-acquire service give a correctly-named, resolvable VM.

### The validated fix (now on the branch, in `tappaas-common.nix`)

1. `networking.hostName = lib.mkDefault "";` — delegate the name to cloud-init.
2. `systemd.services.tappaas-dhcp-hostname` — a oneshot ordered
   `After=cloud-init.service` that (a) sets `ipv4.dhcp-hostname=<live hostname>`
   on every ethernet profile and (b) does a full `nmcli device disconnect/connect`
   to re-lease under the correct name. Runs every boot (self-healing).

**Measured behaviour of the fix:** brief `*` window (~10 s from boot) →
auto-corrects to `<vmname>` (~40 s) → resolves in DNS → persists across reboot.
No nixos-rebuild and no cicd involvement required.

### Full-pipeline validation (passed)

Beyond the bare-clone test, the complete `install-module.sh` path was validated:
built a modified **template** VM (8081) from the image, then installed a real
module (`test-bo-full`, VMID 902) that clones from it through
`cluster:vm` → `templates:nixos` (`update-os.sh` → `nixos-rebuild` overlay →
reboot). Result (`install-module.sh` exit 0):

- DNS: `test-bo-full.mgmt.internal → 10.0.0.129` ✓
- DHCP lease name: `test-bo-full` (not `*`, not `tappaas-nixos`) ✓
- In-VM: `hostname=test-bo-full`, `/etc/hostname=test-bo-full`, overlay applied
  (`networking.hostName="test-bo-full"`), `ipv4.dhcp-hostname=test-bo-full` ✓
- The `tappaas-dhcp-hostname` re-acquire (network bounce) did **not** disrupt
  `update-os.sh`'s SSH / `nixos-rebuild` — the install ran clean.

Note the two mechanisms compose to cover all cases: the **template** fix
(`hostName=""` + re-acquire) handles the pre-rebuild window and the
failed-overlay case (#309); the **consumer overlay** sets
`networking.hostName=<vmname>` declaratively, so post-rebuild the static hostname
is non-empty and NM advertises the correct name on its own.

### Shipped (2026-06-05, on `main`)

- **Template v1.2** carries the fix; `tappaas-nixos.json` bumped to v1.2 and the
  on-cluster template 8080 rebuilt from it. **Remaining ops step:** publish the
  `nixos-template-v1.2` GitHub release (push the tag) so fresh foundation
  installs fetch it — clones use the released image, not a local build.
- **`update-os.sh` `fix_dhcp_hostname` fixed** to do a full re-acquire
  (`nmcli device disconnect/connect`, run detached via `systemd-run` so it can't
  strand the SSH session) instead of the no-op `device reapply`. This is the
  belt-and-suspenders for the NixOS NM path and also matters for the update path.
- **#309 hardening** landed alongside: `run_quiet` surfaces the failing step's
  output; `wait_for_provisioning()` gates `update_nixos` on cloud-init + sudo.

### Remaining caveat

- The brief `*` window (~10 s before the re-acquire) could be eliminated only by
  having Proxmox deliver the hostname via cloud-init **meta-data** (read
  pre-network) rather than user-data — out of scope and not worth the complexity
  given the ~40 s self-correction and that the install pipeline reboots anyway.

### #302 closure note

`#302` ("update-service doesn't re-register DNS unless the zone changes") is
addressed the way its own thread concluded it should be — **via masqdns/DHCP, not
a dns-manager pin**. Verified that VM DNS already resolves from dnsmasq leases;
Option 2 makes the lease correct at boot, and the now-working `fix_dhcp_hostname`
re-asserts it on every `update-module.sh` run (every VM module depends on
`templates:nixos`/`:debian`, whose update path runs `update-os.sh`). The literal
proposed patch (an unconditional `dns-manager add` in `cluster:vm
update-service.sh`) was deliberately **not** applied — it would re-introduce the
static pin the masqdns model makes unnecessary.
