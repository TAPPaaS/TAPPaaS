# ADR-001: Use Trunk Mode for TAPPaaS VM VLAN Connectivity
**Author** Erik Daniel (tappaas)
**Status:** Proposed  
**Date:** 2025-02-03  
**Deciders:** TAPPaaS Core Module Owner  
**Technical Story:** RCA-2025-02-03-VLAN-SRV 

---

## TL;DR

TAPPaaS VMs require dedicated VLAN connectivity with HA migration support. We propose **trunk mode** (VLAN tagging inside VM using NixOS VLAN interfaces) instead of Proxmox access mode (tag=X parameter). This solves critical DHCP failures caused by Linux bridge VLAN filtering bugs, follows industry best practices, and enables reliable cross-node migration.

---

## Context

### Problem Statement

On 2025-02-03, TAPPaaS VM 999 deployed to VLAN 210 failed to obtain DHCP despite correct infrastructure configuration. Investigation revealed **Linux kernel bridge VLAN filtering limitation** where broadcast/multicast packets (DHCP, ARP) are not correctly forwarded to VM interfaces configured with "PVID Egress Untagged" on non-native VLANs.

**Full technical details:** See RCA-2025-02-03-VLAN210-DHCP-Failure

### Current Architecture

- **Proxmox nodes:** tappaas1 (primary), tappaas2 (secondary)
- **Router:** opensense VM using trunk mode (vtnet1 trunk, vtnet1.210 subinterface)
- **VLANs:** .., 210 (Services)
- **TAPPaaS requirements:**
  - Dedicated VLAN per VM instance
  - Live migration between nodes
  - High availability (automatic failover)
  - Hands-off deployment for operators

### Technical Requirements

1. DHCP must work reliably on all VLANs
2. Broadcast/multicast traffic must function correctly
3. VM network configuration must survive migration
4. Solution must scale to 50+ TAPPaaS VMs across multiple VLANs

---

## Decision

**Adopt trunk mode for all TAPPaaS VM network interfaces.**

### Architecture

```
┌─────────────────────────────────────┐
│ TAPPaaS VM (NixOS)                  │
│  ├─ ens18 (trunk, no IP)            │
│  └─ ens18.210 (VLAN subinterface)  │
└─────────────────────────────────────┘
         ↓ VLAN 210 tagged frames
┌─────────────────────────────────────┐
│ Proxmox Bridge (VLAN-aware)         │
│  VM config: NO tag parameter        │
└─────────────────────────────────────┘
         ↓ VLAN 210 tagged frames
┌─────────────────────────────────────┐
│ Physical Switch → opnsense          │
└─────────────────────────────────────┘
```

**Key principle:** VM handles VLAN tagging, Proxmox bridge forwards tagged frames transparently.

---

## Implementation

### 1. Proxmox Infrastructure Configuration

**Required once per VLAN, per node.**

**File:** `/etc/network/interfaces`

```bash
auto vmbr2  # or 'lan' on tappaas2
iface vmbr2 inet manual
    bridge-ports eno2
    bridge-vlan-aware yes
    bridge-vids 2-4094
    # VLAN membership (add for each TAPPaaS VLAN)
    post-up bridge vlan add vid 210 dev vmbr2 self
    post-up bridge vlan add vid 210 dev eno2
```

**Apply changes:**
```bash
ifreload -a
bridge vlan show dev vmbr2  # Verify VLAN 210 present
```

**Authority:** Proxmox VE Network Configuration Guide  
https://pve.proxmox.com/wiki/Network_Configuration#_vlan_802_1q

---

### 2. TAPPaaS VM Template Configuration

**Proxmox VM network interface (trunk mode):**

```bash
qm set <VMID> --net0 model=virtio,bridge=vmbr2,firewall=0
# Note: NO tag parameter
# firewall=0 avoids Proxmox firewall bridge complexity
```

**NixOS configuration:**

```nix
{ config, pkgs, ... }:

{
  networking = {
    useDHCP = false;
    
    # Main interface (trunk, no IP)
    interfaces.ens18.useDHCP = false;
    
    # VLAN subinterface
    vlans."ens18.210" = {
      id = 210;
      interface = "ens18";
    };
    
    # VLAN interface gets DHCP
    interfaces."ens18.210".useDHCP = true;
    
    # Default gateway via VLAN
    defaultGateway = {
      address = "192.168.210.1";
      interface = "ens18.210";
    };
    
    nameservers = [ "192.168.210.1" ];
  };
}
```

**Authority:** NixOS Manual - VLAN Configuration  
https://nixos.org/manual/nixos/stable/options.html#opt-networking.vlans

**Verification:**
```bash
nixos-rebuild switch
ip addr show ens18.210  # Should show DHCP-assigned IP
```

---

### 3. Module Developer Guidelines

**For developers creating TAPPaaS VMs:**

1. **Use template** with trunk mode configuration (Proxmox config already correct)
2. **Update VLAN ID** in NixOS configuration:
   ```nix
   vlans."ens18.XXX" = {
     id = XXX;  # Your assigned VLAN
     interface = "ens18";
   };
   ```
3. **Update gateway** to match VLAN subnet:
   ```nix
   defaultGateway.address = "192.168.XXX.1";
   ```
4. **Deploy and verify** DHCP connectivity

**Note:** See ADR-002 for dynamic VLAN configuration to avoid hardcoding.

---

### 4. pfSense/OPNsense Configuration

**No changes required.** Existing trunk configuration already supports this:
- pfSense receives tagged VLAN frames on vtnet1 (trunk interface)
- VLAN subinterfaces (vtnet1.210, etc.) handle routing/DHCP
- Firewall rules per VLAN interface continue to apply

**Authority:** pfSense VLAN Documentation  
https://docs.netgate.com/pfsense/en/latest/vlan/index.html

---

## Consequences

### Positive

**Reliability:**
- ✓ Eliminates Linux bridge VLAN filtering bugs
- ✓ DHCP, ARP, and all broadcast/multicast work correctly
- ✓ Proven solution (pfSense, OPNsense, VMware use this approach)

**Migration & HA:**
- ✓ VMs migrate between nodes without network reconfiguration
- ✓ VLAN config stays with VM (NixOS configuration.nix)
- ✓ No node-specific network settings required

**Operations:**
- ✓ Clear separation: infrastructure (Proxmox) vs application (VM VLAN)
- ✓ Proxmox config is static (add VLAN once, works for all VMs)
- ✓ Declarative configuration (version-controlled NixOS config)

**Scalability:**
- ✓ Adding VLANs: 2 lines per Proxmox node
- ✓ No per-VM Proxmox configuration changes
- ✓ Supports multiple VLANs per VM (multiple subinterfaces)

### Negative

**Complexity:**
- VM OS must support VLAN interfaces (Linux: standard, Windows: requires configuration)
- Module developers must understand VLAN configuration
- Troubleshooting requires VM access (cannot diagnose from Proxmox alone)

**Template Management:**
- VLAN ID currently hardcoded in NixOS config (see ADR-002 for dynamic solution)
- Each VM needs custom VLAN configuration before deployment

### Mitigation

**Documentation:**
- Provide NixOS VLAN configuration examples
- Create troubleshooting guide (tcpdump on VLAN interface)
- Document common errors and solutions

**Automation:**
- Implement dynamic VLAN configuration (see ADR-002)
- Create deployment verification scripts
- Automated testing of DHCP connectivity

---

## Alternatives Considered

### Alternative 1: Access Mode (Current/Failed)

**Configuration:**
```bash
qm set VM --net0 bridge=lan,tag=210
```

**Why rejected:**

**Technical limitation:** Linux kernel bridge VLAN filtering does not correctly forward broadcast frames to ports configured as "PVID Egress Untagged" on non-native VLANs.

**Evidence:**
- **Testing:** VM with tag=210 never received DHCP Offer (only Discover sent)
- **Testing:** Same VM without tag immediately received IP on native VLAN 1
- **Root cause:** Confirmed via packet capture at multiple layers (see RCA-2025-02-03)

**References:**
- Proxmox Forum: "VLAN aware bridge DHCP not working"  
  https://forum.proxmox.com/threads/vlan-aware-bridge-dhcp-not-working.59298/
- Red Hat: "VLAN Filter Support on Bridge"  
  https://developers.redhat.com/blog/2017/09/14/vlan-filter-support-on-bridge
- Linux kernel bug reports: Multiple reports of broadcast forwarding issues with bridge VLAN filtering

**Industry consensus:** Access mode unreliable in production, trunk mode standard practice.

---

### Alternative 2: Dedicated VLAN Bridges

**Configuration:**
```bash
# Per VLAN: create dedicated bridge
ip link add link lan name lan.210 type vlan id 210
ip link add vlan210 type bridge
ip link set lan.210 master vlan210
qm set VM --net0 bridge=vlan210
```

**Why rejected:**

**Operational overhead:**
- Requires creating one bridge per VLAN per node
- 20 VLANs = 20 bridges = 20 configurations to maintain
- Each node must have identical bridge setup for migration
- Error-prone: easy to forget creating bridge on one node

**Non-standard:**
- Not how modern Proxmox is intended to be used
- VLAN-aware bridges exist specifically to avoid this complexity

**References:**
- Proxmox VE Administration Guide: Recommends VLAN-aware bridges over dedicated bridges  
  https://pve.proxmox.com/pve-docs/chapter-sysadmin.html#_vlan_802_1q

---

### Alternative 3: Proxmox SDN

**Configuration:**
```
Datacenter → SDN → Zones → Simple Zone with VLAN support
```

**Why rejected:**

**Maturity concerns:**
- SDN introduced in Proxmox 7.0, still evolving feature
- Known issues with external router integration (pfSense/OPNsense)
- Interface naming changes (vnetX instead of traditional names)

**Complexity overhead:**
- Adds abstraction layer for simple VLAN requirement
- Designed for multi-datacenter overlay networks (VXLAN, GRE)
- Overkill for basic VLAN segmentation

**Migration risk:**
- Converting existing setup requires downtime
- SDN service failure affects all VM networking
- Limited community experience with SDN + external routers

**References:**
- Proxmox SDN Documentation: Recommends Simple Zone for basic VLANs  
  https://pve.proxmox.com/pve-docs/chapter-pvesdn.html
- Community feedback: Mixed results with SDN and external routers

**Future consideration:** Reevaluate when TAPPaaS scales to multi-datacenter deployments requiring VXLAN tunneling.

---

### Alternative 4: Disable VLAN Filtering

**Configuration:**
```bash
bridge-vlan-aware no  # Classic Linux bridge
```

**Why rejected:**

**Security risk:**
- All VLANs visible on all VM interfaces (no isolation)
- Bridge learns MAC addresses from all VLANs (pollution)
- Broadcast storms: VLAN 1 broadcasts reach VLAN 210 VMs

**Non-compliant:**
- Violates network segmentation requirements
- Physical switch must enforce all VLAN policy

**References:**
- Linux Bridge Documentation: Recommends VLAN filtering for multi-tenant environments  
  https://www.kernel.org/doc/Documentation/networking/bridge.txt

---

## References

### Official Documentation

1. **Proxmox VE Network Configuration**  
   https://pve.proxmox.com/wiki/Network_Configuration  
   Section: "VLAN 802.1Q" and "VLAN-aware bridge setup"

2. **Proxmox VE Administration Guide - VLAN**  
   https://pve.proxmox.com/pve-docs/chapter-sysadmin.html#_vlan_802_1q  
   Bridge VLAN configuration and best practices

3. **NixOS Manual - Networking Options**  
   https://nixos.org/manual/nixos/stable/options.html#opt-networking.vlans  
   Official networking.vlans configuration documentation

4. **pfSense VLAN Configuration Guide**  
   https://docs.netgate.com/pfsense/en/latest/vlan/index.html  
   VLAN interface (trunk mode) configuration

5. **Linux Bridge VLAN Filtering**  
   https://developers.redhat.com/blog/2017/09/14/vlan-filter-support-on-bridge  
   Technical explanation of PVID and Egress Untagged behavior

### Community & Industry

6. **Proxmox Forum - VLAN DHCP Issues**  
   https://forum.proxmox.com/threads/vlan-aware-bridge-dhcp-not-working.59298/  
   Community-reported DHCP failures with access mode

7. **VMware vSphere Networking Best Practices**  
   https://core.vmware.com/resource/vmware-vsphere-network-best-practices  
   Recommends guest VLAN tagging (VST/trunk mode) for production

8. **Red Hat Virtualization Network Guide**  
   https://access.redhat.com/documentation/en-us/red_hat_virtualization/  
   Recommends guest VLAN tagging for flexibility and reliability

### Technical Analysis

9. **Linux Kernel Bridge Documentation**  
   https://www.kernel.org/doc/Documentation/networking/bridge.txt  
   Bridge VLAN filtering implementation and limitations

10. **Root Cause Analysis**  
    RCA-2025-02-03-VLAN210-DHCP-Failure  
    Detailed investigation of access mode failure

---

## Decision Outcome

**Chosen solution:** Trunk mode (VLAN tagging inside VM)

**Rationale:**
1. **Reliability:** Eliminates known Linux bridge VLAN filtering bugs
2. **Industry standard:** VMware, Red Hat, pfSense/OPNsense all use this approach
3. **Migration-friendly:** VLAN config stays with VM (survives node migration)
4. **Proven:** pfSense already uses trunk mode successfully in this infrastructure
5. **Scalable:** No per-VM Proxmox configuration changes needed

**Expected benefits:**
- Zero DHCP-related failures
- Reliable broadcast/multicast (ARP, mDNS, etc.)
- Seamless HA migration
- Clear operational boundaries (infrastructure vs application)

**Trade-offs accepted:**
- VLAN configuration moves to VM level (NixOS config)
- Module developers need VLAN configuration knowledge
- Currently requires manual VLAN ID editing (resolved by ADR-002)

---

## Compliance & Validation

**Security:** Maintains VLAN isolation at network layer (switch and router enforce policy)

**Testing required:**
- [ ] DHCP functionality on VLAN 210
- [ ] VM migration between pve and tappaas2 nodes
- [ ] HA failover with network connectivity maintained
- [ ] Multiple VLANs per VM (if required by modules)
- [ ] Performance testing (latency, throughput)

**Success criteria:**
1. All TAPPaaS VMs receive DHCP IP on assigned VLANs within 10 seconds of boot
2. VMs migrate between nodes with zero network interruption
3. Automatic failover maintains VLAN connectivity
4. Zero broadcast/multicast-related failures over 30-day validation period

---

## Approval

**Status:** Proposed  
**Awaiting approval from:** TAPPaaS Core Module Owner

**Questions for reviewer:**
1. Approval to update TAPPaaS VM template to trunk mode?
2. Acceptable for module developers to configure VLANs in NixOS config?
3. Timeline for migrating existing VMs to trunk mode?
4. Any security/compliance concerns with trunk mode approach?

**Related decisions:**
- ADR-002: Dynamic VLAN Configuration (proposes cloud-init solution for hardcoded VLAN issue)

---

**End of ADR-001**