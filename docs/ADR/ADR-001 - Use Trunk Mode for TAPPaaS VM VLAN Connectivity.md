```markdown
# ADR-001: Use Trunk Mode for TAPPaaS VM VLAN Connectivity

**Status:** Accepted  
**Date:** 2026-02-03  
**Updated:** 2026-02-04 (Added bridge-vids requirement)  
**Deciders:** Erik (tappaas)  
**Related:** RCA-2025-02-03-VLAN-SRV.md, RCA-2025-02-03-VLAN-SRV-FIX.md

---

## Context

TAPPaaS VMs require connectivity to multiple VLANs (mgmt, srv, dmz, app, data) for network segmentation and security. The current implementation uses Proxmox "access mode" (`tag=X` parameter), which triggers a known Linux kernel bridge VLAN filtering bug that prevents broadcast/multicast traffic (DHCP, ARP) from reaching VMs on non-native VLANs.

**Current implementation (broken):**
```bash
qm set <VMID> --net0 bridge=lan,tag=210
```

This configuration creates a bridge port with "PVID Egress Untagged" which fails to forward broadcast frames correctly on non-native VLANs (documented kernel limitation, see RCA-2025-02-03).

**Additional discovery (2026-02-04):**

Investigation revealed that even switching to trunk mode (removing `tag` parameter) is insufficient if the Proxmox bridge has `bridge-vids 2-4094` configured in `/etc/network/interfaces`. This setting automatically adds all 4093 VLANs to every tap interface with "PVID Egress Untagged", triggering the same VLAN filtering bug even in trunk mode.

---

## Decision

**We will use trunk mode (VLAN tagging inside VM) for all TAPPaaS VM VLAN connectivity.**

**This requires THREE critical changes:**

1. **Remove `bridge-vids` from Proxmox bridge configuration** (host-level fix)
2. **Remove `tag=X` parameter from VM network configuration** (Proxmox config)
3. **Configure VLAN interfaces inside VMs** (guest OS config)

---

## Rationale

### Why Trunk Mode?

**Industry standard:**
- VMware recommends "Guest VLAN tagging (VST)" over "External Switch tagging (EST)"
- Red Hat recommends "VLAN interfaces inside guest" for production
- Proxmox staff confirms: "We recommend using VLAN interfaces inside the guest"

**Avoids kernel bug:**
- No "Egress Untagged" configuration on bridge ports
- Broadcast/multicast forwarding works correctly
- All protocols (DHCP, ARP, mDNS) function properly

**Architectural benefits:**
- VM controls its own VLAN membership (explicit configuration)
- No dependency on Proxmox access mode VLAN translation
- More portable (VM config contains full network info)
- Better observability (VLAN visible in VM's network config)

### Why Remove bridge-vids?

**Problem:**
```bash
# In /etc/network/interfaces
iface lan inet static
  bridge-vids 2-4094  # ← Adds ALL VLANs to ALL tap interfaces
```

**Impact:**
- Creates 4093 VLAN memberships per VM interface
- Each VLAN gets "PVID Egress Untagged" by default
- Triggers VLAN filtering bug even in trunk mode
- Massive performance overhead

**Evidence:**
```bash
bridge vlan show dev tap999i0
# tap999i0  1 PVID Egress Untagged
#           2
#           3
#           ...
#           4094  # 4093 unwanted VLANs!
```

Even with trunk mode VM config, the bridge strips VLAN tags on egress due to "Egress Untagged" flag, breaking VLAN functionality.

---

## Implementation

### Phase 0: Fix Proxmox Bridge Configuration (CRITICAL - Do First)

**On each Proxmox node (tappaas2, pve, etc.):**

#### Step 0.1: Backup current config
```bash
cp /etc/network/interfaces /etc/network/interfaces.backup-$(date +%Y%m%d)
```

#### Step 0.2: Remove bridge-vids line
```bash
nano /etc/network/interfaces
```

**Remove this line:**
```diff
  iface lan inet static
    address 192.168.2.220/24
    gateway 192.168.2.254
    bridge-ports enp97s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
-   bridge-vids 2-4094
```

#### Step 0.3: Apply changes
```bash
# Reload networking (WARNING: may briefly interrupt connectivity)
ifreload -a

# Verify bridge config
grep -A10 "iface lan" /etc/network/interfaces
```

#### Step 0.4: Create VM network hook script

This script automatically configures tap interfaces with the correct VLAN when VMs start:

```bash
cat > /etc/qemu-server/vm-network-hook.sh <<'HOOKEOF'
#!/bin/bash
# Configure tap interface VLANs on VM start
# Called by Proxmox with: <vmid> <phase>

if [ "$2" = "post-start" ]; then
    VMID=$1
    
    # Get tap interface name
    TAP=$(qm config $VMID | grep -oP 'tap\d+i\d+' | head -1)
    [ -z "$TAP" ] && exit 0
    
    # Get VLAN from VM config JSON
    CONFIG_FILE="/root/tappaas/${VMID}.json"
    if [ ! -f "$CONFIG_FILE" ]; then
        # Fallback: use VMNAME.json
        VMNAME=$(qm config $VMID | grep -oP 'name: \K.*')
        CONFIG_FILE="/root/tappaas/${VMNAME}.json"
    fi
    
    if [ -f "$CONFIG_FILE" ]; then
        # Parse zone from VM config
        ZONE=$(jq -r '.zone0 // empty' "$CONFIG_FILE")
        
        if [ -n "$ZONE" ] && [ "$ZONE" != "null" ]; then
            # Get VLAN tag from zones.json
            VLAN=$(jq -r ".\"$ZONE\".vlantag // empty" /root/tappaas/zones.json)
            
            if [ -n "$VLAN" ] && [ "$VLAN" != "null" ] && [ "$VLAN" != "0" ]; then
                # Remove default VLAN 1 with PVID Egress Untagged
                bridge vlan del vid 1 dev $TAP pvid untagged 2>/dev/null || true
                
                # Add only required VLAN (tagged, no Egress Untagged)
                bridge vlan add vid $VLAN dev $TAP 2>/dev/null || true
                
                logger -t vm-network-hook "Configured $TAP for VM $VMID: VLAN $VLAN (zone: $ZONE)"
            fi
        fi
    fi
fi
HOOKEOF

chmod +x /etc/qemu-server/vm-network-hook.sh
```

#### Step 0.5: Test hook script
```bash
# Test on existing VM
/etc/qemu-server/vm-network-hook.sh 999 post-start

# Verify
bridge vlan show dev tap999i0
# Expected: tap999i0  210  (only one VLAN, no PVID, no Egress Untagged)
```

#### Step 0.6: Audit existing VMs
```bash
# Check all running VMs
for vm in $(qm list | awk 'NR>1 {print $1}'); do
  tap=$(qm config $vm | grep -oP 'tap\d+i\d+' | head -1)
  if [ -n "$tap" ]; then
    vlan_count=$(bridge vlan show dev $tap | wc -l)
    echo "VM $vm ($tap): $vlan_count VLAN entries"
    if [ $vlan_count -gt 3 ]; then
      echo "  ⚠️  WARNING: Excessive VLANs detected (should be 1-2)"
    fi
  fi
done
```

**For VMs with excessive VLANs:** Stop and restart to recreate tap interface with clean config.

---

### Phase 1: Update Proxmox VM Configuration

#### Step 1.1: Remove VLAN tag parameter

**Before:**
```bash
qm set <VMID> --net0 virtio,bridge=lan,tag=210,macaddr=XX:XX:XX:XX:XX:XX
```

**After:**
```bash
qm set <VMID> --net0 virtio,bridge=lan,macaddr=XX:XX:XX:XX:XX:XX,firewall=0
```

**Why `firewall=0`:** Disable Proxmox firewall to ensure all VLAN-tagged packets pass through unmodified.

#### Step 1.2: Update Create-TAPPaaS-VM.sh

**Location:** Line 216-220 in `/root/tappaas/Create-TAPPaaS-VM.sh`

**Replace:**
```bash
if [ "$VLANTAG0" != "0" ]; then
  qm set $VMID --net0 "virtio,bridge=${BRIDGE0},tag=${VLANTAG0},macaddr=${MAC0}"
else
  qm set $VMID --net0 "virtio,bridge=${BRIDGE0},macaddr=${MAC0}"
fi
```

**With:**
```bash
# Trunk mode - no tag parameter (ADR-001)
# VLAN configuration handled inside VM
qm set $VMID --net0 "virtio,bridge=${BRIDGE0},macaddr=${MAC0},firewall=0"
```

---

### Phase 2: Configure VLAN Inside VM (NixOS)

#### Step 2.1: Update NixOS configuration

**Template VM 8080:** `/etc/nixos/configuration.nix`

**Add dynamic VLAN configuration support:**

```nix
let
  # Default network config (used if cloud-init doesn't provide one)
  defaultNetwork = {
    vlanId = 210;
    gateway = "192.168.210.1";
    useDhcp = true;
    staticIp = null;
  };
  
  # Path where cloud-init will write network config
  cloudNetworkPath = /etc/tappaas/network.nix;
  
  # Use cloud-init config if exists, otherwise use default
  networkConfig = 
    if builtins.pathExists cloudNetworkPath
    then import cloudNetworkPath
    else defaultNetwork;

in {
  # Enable cloud-init
  services.cloud-init.enable = true;
  
  # Network configuration
  networking = {
    # Disable DHCP on physical interface
    useDHCP = false;
    interfaces.ens18.useDHCP = false;
    
    # Create VLAN interface
    vlans."ens18.${toString networkConfig.vlanId}" = {
      id = networkConfig.vlanId;
      interface = "ens18";
    };
    
    # Configure VLAN interface
    interfaces."ens18.${toString networkConfig.vlanId}" = {
      useDHCP = networkConfig.useDhcp;
      
      # Static IP if configured
      ipv4.addresses = lib.optionals (networkConfig.staticIp != null) [
        {
          address = networkConfig.staticIp;
          prefixLength = 24;
        }
      ];
    };
    
    # Set default gateway
    defaultGateway = {
      address = networkConfig.gateway;
      interface = "ens18.${toString networkConfig.vlanId}";
    };
  };
}
```

#### Step 2.2: Rebuild template
```bash
# On template VM 8080
nixos-rebuild switch

# Verify VLAN interface exists
ip link show ens18.210
ip addr show ens18.210
```

---

### Phase 3: Implement Cloud-Init VLAN Injection (ADR-002)

**Update Create-TAPPaaS-VM.sh to create cloud-init user-data:**

**Location:** Before line 231 (before `qm set --ciuser`)

**Add:**
```bash
if [ "$CLOUDINIT" == "true" ]; then
  # Calculate gateway from VLAN
  GATEWAY="192.168.${VLANTAG0}.1"
  
  # Create cloud-init user-data file
  CLOUD_INIT_FILE="/var/lib/vz/snippets/${VMNAME}.yml"
  cat > "${CLOUD_INIT_FILE}" <<CLOUDEOF
#cloud-config
hostname: ${VMNAME}

write_files:
  - path: /etc/tappaas/network.nix
    permissions: '0644'
    content: |
      {
        vlanId = ${VLANTAG0};
        gateway = "${GATEWAY}";
        useDhcp = true;
        staticIp = null;
      }

runcmd:
  - mkdir -p /etc/tappaas
  - nixos-rebuild switch
CLOUDEOF

  # Attach custom cloud-init config
  qm set $VMID --cicustom "user=local:snippets/${VMNAME}.yml"
  
  # Continue with standard cloud-init config
  qm set $VMID --ciuser tappaas
  qm set $VMID --ipconfig0 ip=dhcp
  
  # SSH key configuration (existing code)
  if [[ "$VMNAME" == "tappaas-cicd" ]]; then
    qm set $VMID --sshkey ~/.ssh/id_rsa.pub
  elif [[ -f ~/tappaas/tappaas-cicd.pub ]]; then
    qm set $VMID --sshkey ~/tappaas/tappaas-cicd.pub
  fi
  
  qm cloudinit update $VMID
fi
```

---

## Migration Plan

### Existing VMs (Immediate Fix)

**For VM 999 (openwebui) and other affected VMs:**

```bash
# 1. Stop VM
qm stop 999

# 2. Remove VLAN tag from Proxmox config
qm set 999 --net0 virtio,bridge=lan,macaddr=02:c1:90:c0:2a:58,firewall=0

# 3. Start VM
qm start 999

# 4. Wait for tap interface creation
sleep 5

# 5. Configure tap interface VLAN
TAP=$(qm config 999 | grep -oP 'tap\d+i\d+' | head -1)
bridge vlan del vid 1 dev $TAP pvid untagged
bridge vlan add vid 210 dev $TAP

# 6. Verify tap config
bridge vlan show dev $TAP
# Expected: tap999i0  210

# 7. Inside VM: Verify network
# (Should already have VLAN interface if NixOS config updated)
qm guest exec 999 -- ip addr show eth0.210
```

### New VMs (Automated)

**After implementing all changes:**

1. Update template VM 8080 with dynamic VLAN config
2. Update Create-TAPPaaS-VM.sh with trunk mode + cloud-init
3. Fix bridge configuration on all Proxmox nodes
4. Install hook script on all Proxmox nodes
5. Test with new VM deployment
6. Verify DHCP, DNS, and connectivity

---

## Consequences

### Positive

- **Reliable networking:** DHCP, ARP, and all broadcast protocols work correctly
- **Industry standard:** Aligns with VMware, Red Hat, and Proxmox recommendations
- **Better observability:** VLAN membership visible in VM's network configuration
- **More portable:** VM network config is self-contained
- **Scalable:** No manual bridge VLAN configuration per VM
- **Future-proof:** Not dependent on kernel bridge VLAN filtering improvements

### Negative

- **Migration effort:** Existing VMs must be reconfigured
- **Template complexity:** NixOS config must handle dynamic VLAN assignment
- **Cloud-init dependency:** VLAN configuration injected via cloud-init
- **Manual tap config:** Hook script required until Proxmox adds native support

### Neutral

- **Documentation:** Need to update all deployment guides
- **Training:** Module developers must understand trunk mode
- **Testing:** All VMs must be tested after migration

---

## Validation Criteria

### Success Criteria

- [ ] Bridge configuration cleaned (no bridge-vids on any Proxmox node)
- [ ] Hook script installed and tested on all Proxmox nodes
- [ ] VM 999 obtains IP via DHCP on VLAN 210 ✓ (Verified 2026-02-04)
- [ ] VM 999 can ping gateway 192.168.210.1
- [ ] VM 999 can resolve DNS via 192.168.210.1 ✓ (Verified 2026-02-04)
- [ ] VM 999 has internet connectivity ✓ (Verified 2026-02-04)
- [ ] Template VM 8080 updated with dynamic VLAN support
- [ ] Create-TAPPaaS-VM.sh updated (trunk mode + cloud-init)
- [ ] New VM deployment creates correct configuration automatically
- [ ] All existing TAPPaaS VMs migrated to trunk mode
- [ ] No VMs using `tag=X` parameter in Proxmox config
- [ ] Documentation updated (ADR-001, ADR-002, deployment guides)

### Test Cases

1. **New VM deployment:**
   - Deploy VM with zone=srv (VLAN 210)
   - Verify tap interface has only VLAN 210 (no PVID Egress Untagged)
   - Verify VM creates ens18.210 interface
   - Verify DHCP assigns IP in 192.168.210.0/24 range
   - Verify connectivity to gateway and internet

2. **VM restart persistence:**
   - Stop and start VM
   - Verify tap interface VLAN config persists (via hook script)
   - Verify VM network still functional

3. **Multi-VLAN VM:**
   - Deploy VM with multiple zones (future feature)
   - Verify multiple VLAN interfaces created
   - Verify each VLAN gets correct gateway

---

## References

- **RCA-2025-02-03-VLAN-SRV.md:** Root cause analysis of VLAN DHCP failure
- **RCA-2025-02-03-VLAN-SRV-FIX.md:** Bootstrap sequence analysis and fix details
- **Proxmox Forum Thread 59298:** VLAN aware bridge DHCP not working
- **Proxmox Forum Thread 77842:** VM with VLAN tag doesn't get DHCP
- **VMware vSphere Best Practices:** Guest VLAN tagging recommendation
- **Red Hat Virtualization Guide:** In-guest VLAN configuration

---

## Related Decisions

- **ADR-002:** Dynamic VLAN Configuration for TAPPaaS Deployments (cloud-init implementation)
- **Future ADR:** Multi-VLAN VM Support (multiple zones per VM)

---

**Status:** PROPOSED - READY TO BE VALIDATED** (2026-02-04)

**Implementation Status:**
- [x] Bridge configuration fixed (bridge-vids removed)
- [x] Hook script created and tested
- [x] VM 999 migrated to trunk mode successfully
- [ ] Template VM 8080 update pending
- [ ] Create-TAPPaaS-VM.sh update pending
- [ ] Full automation pending
```

