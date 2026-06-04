# DNS Manager IP Drift Investigation

**Date:** 2026-06-04
**Status:** Investigation complete, solution pending
**Related Issues:** NixOS hostname vs DHCP timing

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
