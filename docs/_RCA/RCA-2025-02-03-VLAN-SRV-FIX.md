```markdown
# Root Cause Analysis Report - VM Bootstrap Sequence Analysis
# Author: Erik (tappaas)
# Incident: VLAN 210 DHCP Failure
# State: Proposed
# Date: 2026-02-03
# Resolution: To fix Create-TAPPaaS-VM.sh apply 3 changes proposed in ADR-001 + ADR-002

---

## Execution Flow Diagram

```
[tappaas-cicd host]
    │
    ├─ ./install.sh openwebui
    │   │
    │   ├─ Source: common-install-routines.sh
    │   │   ├─ Validate hostname = tappaas-cicd ✓
    │   │   ├─ Load JSON: /home/tappaas/config/openwebui.json
    │   │   │   (or ./openwebui.json as fallback)
    │   │   └─ Define get_config_value() function
    │   │
    │   ├─ Extract config values:
    │   │   ├─ VMNAME = "openwebui"
    │   │   ├─ NODE = "tappaas2"
    │   │   ├─ ZONE0NAME = "srv"
    │   │   └─ MGMT = "mgmt"
    │   │
    │   ├─ SCP: openwebui.json → root@tappaas2.mgmt.internal:/root/tappaas/
    │   │
    │   ├─ SSH: root@tappaas2.mgmt.internal
    │   │   │
    │   │   └─ Execute: /root/tappaas/Create-TAPPaaS-VM.sh openwebui
    │   │       │
    │   │       [Now on tappaas2 host]
    │   │       │
    │   │       ├─ Load JSON: /root/tappaas/openwebui.json
    │   │       ├─ Load zones: /root/tappaas/zones.json
    │   │       │   └─ Map "srv" → VLAN tag (e.g., 210)
    │   │       │
    │   │       ├─ Extract all config values:
    │   │       │   ├─ VMID = 999
    │   │       │   ├─ VMNAME = "openwebui"
    │   │       │   ├─ NODE = "tappaas2"
    │   │       │   ├─ CORES = 2
    │   │       │   ├─ MEMORY = 4096
    │   │       │   ├─ DISK_SIZE = "32G"
    │   │       │   ├─ STORAGE = "tanka1"
    │   │       │   ├─ IMAGETYPE = "clone"
    │   │       │   ├─ IMAGE = "8080" (template ID)
    │   │       │   ├─ BRIDGE0 = "lan"
    │   │       │   ├─ ZONE0 = "srv"
    │   │       │   └─ VLANTAG0 = 210 (from zones.json)
    │   │       │
    │   │       ├─ Generate MAC address: 02:XX:XX:XX:XX:XX
    │   │       │
    │   │       ├─ Clone VM:
    │   │       │   └─ qm clone 8080 999 --name openwebui --full 1
    │   │       │
    │   │       ├─ Configure VM:
    │   │       │   ├─ qm set 999 --description "<HTML>"
    │   │       │   ├─ qm set 999 --serial0 socket
    │   │       │   ├─ qm set 999 --tags "TAPPaaS,Test"
    │   │       │   ├─ qm set 999 --agent enabled=1
    │   │       │   ├─ qm set 999 --cores 2 --memory 4096
    │   │       │   │
    │   │       │   ├─ qm set 999 --net0 virtio,bridge=lan,tag=210,macaddr=XX ⚠️
    │   │       │   │   └─ ❌ ACCESS MODE (the bug!)
    │   │       │   │
    │   │       │   └─ Cloud-init:
    │   │       │       ├─ qm set 999 --ciuser tappaas
    │   │       │       ├─ qm set 999 --ipconfig0 ip=dhcp
    │   │       │       ├─ qm set 999 --sshkey (if exists)
    │   │       │       └─ qm cloudinit update 999
    │   │       │
    │   │       └─ qm start 999
    │   │
    │   [Back on tappaas-cicd host]
    │   │
    │   └─ Execute: ./update.sh
    │       └─ (Module-specific post-install configuration)
    │
    └─ Done
```

---

## Detailed Step-by-Step Breakdown

### Phase 1: Pre-flight Checks (tappaas-cicd)

**Location:** `common-install-routines.sh`

```bash
# 1. Validate execution environment
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "Must run on tappaas-cicd host"
  exit 1
fi

# 2. Validate argument
if [ -z "$1" ]; then
  echo "Usage: $0 <vmname>"
  exit 1
fi

# 3. Load JSON configuration
JSON_CONFIG="/home/tappaas/config/$1.json"
# Fallback: ./$1.json in current directory
JSON=$(cat "$JSON_CONFIG")
```

**Result:** JSON loaded, `get_config_value()` function available.

---

### Phase 2: Extract Configuration (tappaas-cicd)

**Location:** `install.sh`

```bash
VMNAME="openwebui"           # from JSON
NODE="tappaas2"              # from JSON
ZONE0NAME="srv"              # from JSON
MGMT="mgmt"                  # hardcoded
```

---

### Phase 3: Transfer Configuration to Target Node

**Location:** `install.sh`

```bash
# Copy JSON to target Proxmox node
scp openwebui.json root@tappaas2.mgmt.internal:/root/tappaas/openwebui.json
```

**Result:** Configuration file available on tappaas2 at `/root/tappaas/openwebui.json`

---

### Phase 4: Remote VM Creation (tappaas2)

**Location:** `Create-TAPPaaS-VM.sh` (executed via SSH)

```bash
ssh root@tappaas2.mgmt.internal "/root/tappaas/Create-TAPPaaS-VM.sh openwebui"
```

**This script performs:**

#### 4a. Load Configuration Files

```bash
# Load VM config
JSON_CONFIG="/root/tappaas/openwebui.json"
JSON=$(cat "$JSON_CONFIG")

# Load VLAN zone mapping
ZONES=$(cat /root/tappaas/zones.json)
```

**zones.json structure (inferred):**
```json
{
  "srv": {
    "state": "Active",
    "vlantag": 210
  },
  "mgmt": {
    "state": "Active",
    "vlantag": 1
  }
}
```

#### 4b. Extract All Configuration Values

```bash
NODE="tappaas2"              # Line 96
VMID="999"                   # Line 97
VMNAME="openwebui"           # Line 98
VMTAG="TAPPaaS,Test"         # Line 99
BIOS="ovmf"                  # Line 100 (default)
CORE_COUNT="2"               # Line 101
VM_OSTYPE="l26"              # Line 102 (default)
RAM_SIZE="4096"              # Line 103
DISK_SIZE="32G"              # Line 104
STORAGE="tanka1"             # Line 105
IMAGETYPE="clone"            # Line 106
IMAGE="8080"                 # Line 107 (template VMID)
BRIDGE0="lan"                # Line 112
MAC0="02:XX:XX:XX:XX:XX"     # Line 114 (generated)
ZONE0="srv"                  # Line 115
VLANTAG0="210"               # Line 116 (from zones.json lookup)
BRIDGE1="NONE"               # Line 117 (default)
CLOUDINIT="true"             # Line 127 (default)
DESCRIPTION="TAPPaaS Open Webui VM"  # Line 128
```

#### 4c. Clone VM from Template

**Line 200-202:**
```bash
info "Creating a Clone based VM"
qm clone 8080 999 --name openwebui --full 1
```

**Result:** VM 999 created as full clone of template 8080.

#### 4d. Configure VM Settings

**Lines 206-229:**

```bash
# Description with HTML
qm set 999 --description "$DESCRIPTION_HTML"

# Serial console
qm set 999 --serial0 socket

# Tags
qm set 999 --tags "TAPPaaS,Test"

# Guest agent
qm set 999 --agent enabled=1

# CPU and RAM
qm set 999 --cores 2 --memory 4096

# Network interface (⚠️ THE BUG IS HERE)
if [ "$VLANTAG0" != "0" ]; then
  qm set 999 --net0 "virtio,bridge=lan,tag=210,macaddr=$MAC0"
  # ❌ ACCESS MODE: tag=210 parameter
else
  qm set 999 --net0 "virtio,bridge=lan,macaddr=$MAC0"
fi
```

**🔴 CRITICAL ISSUE:** `tag=210` creates access mode configuration, which triggers the Proxmox bridge VLAN filtering bug documented in RCA-2025-02-03.

#### 4e. Configure Cloud-Init

**Lines 230-243:**

```bash
if [ "$CLOUDINIT" == "true" ]; then
  qm set 999 --ciuser tappaas
  qm set 999 --ipconfig0 ip=dhcp
  
  # SSH key configuration
  if [[ "$VMNAME" == "tappaas-cicd" ]]; then
    qm set 999 --sshkey ~/.ssh/id_rsa.pub
  elif [[ -f ~/tappaas/tappaas-cicd.pub ]]; then
    qm set 999 --sshkey ~/tappaas/tappaas-cicd.pub
  fi
  
  qm cloudinit update 999
fi
```

**🔴 MISSING:** Cloud-init user-data file with VLAN configuration (required for ADR-002).

Current cloud-init only configures:
- Username: tappaas
- Network: DHCP on default interface
- SSH key: If available

**Does NOT configure:**
- VLAN interface inside VM
- Gateway for VLAN subnet
- `/etc/tappaas/network.nix` file

#### 4f. Start VM

**Line 249:**
```bash
qm start 999
```

**Result:** VM boots, **but DHCP will fail** because:
1. Access mode (`tag=210`) triggers bridge VLAN filtering bug
2. DHCP Offer packets won't reach VM (per RCA-2025-02-03)
3. No VLAN interface configured inside VM (trunk mode not implemented)

---

### Phase 5: Post-Install Configuration (tappaas-cicd)

**Location:** `install.sh` line 15

```bash
. ./update.sh
```

**Purpose:** Module-specific configuration (not shown in provided scripts).

---

## What Happens When VM Boots

### Current (Broken) Behavior

```
VM 999 boots
  ├─ NixOS starts
  ├─ ens18 interface comes up (no VLAN interface configured)
  ├─ DHCP client sends Discover on ens18 (untagged)
  ├─ Proxmox adds VLAN 210 tag (access mode)
  ├─ DHCP Discover reaches pfSense ✓
  ├─ pfSense sends DHCP Offer with VLAN 210 tag ✓
  ├─ Proxmox bridge receives DHCP Offer ✓
  ├─ Bridge VLAN filtering tries to forward to tap999i0 (Egress Untagged)
  ├─ ❌ Broadcast forwarding bug: packet dropped
  └─ VM never receives DHCP Offer → No IP address
```

---

## Critical Problems Identified

### Problem 1: Access Mode (Lines 216-220)

**Current code:**
```bash
qm set 999 --net0 "virtio,bridge=lan,tag=210,macaddr=$MAC0"
```

**Issue:** Uses access mode (Proxmox handles VLAN tagging), which triggers Linux bridge VLAN filtering bug.

**Fix required:** Remove `tag=210` parameter (trunk mode).

---

### Problem 2: No VLAN Configuration Inside VM

**Current:** Template VM (8080) has no VLAN configuration in NixOS.

**After cloning:** VM 999 has no `ens18.210` VLAN interface.

**Issue:** Even if trunk mode enabled, VM doesn't know to create VLAN interface.

**Fix required:** Cloud-init must inject VLAN configuration.

---

### Problem 3: Missing Cloud-Init User-Data

**Current cloud-init (lines 230-243):** Only sets username, DHCP, SSH key.

**Missing:** `/var/lib/vz/snippets/openwebui.yml` with VLAN parameters.

**Fix required:** Create cloud-init user-data file before `qm cloudinit update`.

---

## Required Changes to Fix

### Change 0: Fix Proxmox Bridge Configuration (CRITICAL - Must be done FIRST)

**Discovered 2026-02-04:** The `bridge-vids 2-4094` parameter in `/etc/network/interfaces` automatically adds all VLANs to every tap interface with "PVID Egress Untagged" configuration, which triggers the VLAN filtering bug even in trunk mode. This must be fixed on all Proxmox nodes BEFORE implementing Changes 1-3.

**On each Proxmox node (tappaas2, pve, etc.):**

**Edit `/etc/network/interfaces`:**
```bash
nano /etc/network/interfaces
```

**Remove the bridge-vids line:**
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

**Apply changes:**
```bash
ifreload -a
```

**Verify no existing VMs are affected:**
```bash
# Check each running VM's tap interface
for vm in $(qm list | awk 'NR>1 {print $1}'); do
  tap=$(qm config $vm | grep -oP 'tap\d+i\d+' | head -1)
  if [ -n "$tap" ]; then
    echo "VM $vm ($tap):"
    bridge vlan show dev $tap | wc -l
  fi
done
```

**Create VM network hook script for automatic VLAN configuration:**

```bash
cat > /etc/qemu-server/vm-network-hook.sh <<'HOOKEOF'
#!/bin/bash
# Configure tap interface VLANs on VM start
# Called by qm with: <vmid> <phase>

if [ "$2" = "post-start" ]; then
    VMID=$1
    
    # Get tap interface name
    TAP=$(qm config $VMID | grep -oP 'tap\d+i\d+' | head -1)
    [ -z "$TAP" ] && exit 0
    
    # Get VLAN from VM config
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
                # Remove PVID Egress Untagged from VLAN 1
                bridge vlan del vid 1 dev $TAP pvid untagged 2>/dev/null || true
                
                # Add only required VLAN (tagged, no Egress Untagged)
                bridge vlan add vid $VLAN dev $TAP 2>/dev/null || true
                
                logger -t vm-network-hook "Configured $TAP for VM $VMID: VLAN $VLAN"
            fi
        fi
    fi
fi
HOOKEOF

chmod +x /etc/qemu-server/vm-network-hook.sh
```

**Configure Proxmox to call hook script:**

```bash
# Add to /etc/pve/qemu-server/hookscript.pl or create wrapper
cat > /var/lib/vz/snippets/vm-network-hook.pl <<'PERLEOF'
#!/usr/bin/perl
use strict;
use warnings;

my ($vmid, $phase) = @ARGV;
system("/etc/qemu-server/vm-network-hook.sh", $vmid, $phase);
PERLEOF

chmod +x /var/lib/vz/snippets/vm-network-hook.pl
```

**For existing VMs, manually trigger configuration:**
```bash
# After restarting VM
VMID=999
TAP=$(qm config $VMID | grep -oP 'tap\d+i\d+' | head -1)
bridge vlan del vid 1 dev $TAP pvid untagged
bridge vlan add vid 210 dev $TAP

# Verify
bridge vlan show dev $TAP
# Expected: tap999i0  210  (no PVID, no Egress Untagged)
```

**Why this is critical:**
- Without this fix, Changes 1-3 will still fail
- `bridge-vids 2-4094` overrides trunk mode configuration
- Creates 4093 VLAN memberships per VM (performance impact)
- Triggers Linux bridge VLAN filtering bug on all non-native VLANs

---

### Change 1: Enable Trunk Mode (Line 216-220)

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
qm set $VMID --net0 "virtio,bridge=${BRIDGE0},macaddr=${MAC0},firewall=0"
```

---

### Change 2: Create Cloud-Init User-Data (Before Line 231)

**Insert:**
```bash
if [ "$CLOUDINIT" == "true" ]; then
  # Calculate gateway from VLAN (ADR-002)
  GATEWAY="192.168.${VLANTAG0}.1"
  
  # Create cloud-init user-data file
  CLOUD_INIT_FILE="/var/lib/vz/snippets/${VMNAME}.yml"
  cat > "${CLOUD_INIT_FILE}" <<EOF
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
EOF

  # Attach custom cloud-init config
  qm set $VMID --cicustom "user=local:snippets/${VMNAME}.yml"
  
  # Continue with existing cloud-init config...
  qm set $VMID --ciuser tappaas
  # etc...
fi
```

---

### Change 3: Update Template VM 8080

**Template must have dynamic VLAN config in `/etc/nixos/configuration.nix`:**

```nix
let
  defaultNetwork = {
    vlanId = 210;
    gateway = "192.168.210.1";
    useDhcp = true;
  };
  
  cloudNetworkPath = /etc/tappaas/network.nix;
  networkConfig = 
    if builtins.pathExists cloudNetworkPath
    then import cloudNetworkPath
    else defaultNetwork;

in {
  services.cloud-init.enable = true;
  
  networking = {
    useDHCP = false;
    interfaces.ens18.useDHCP = false;
    
    vlans."ens18.${toString networkConfig.vlanId}" = {
      id = networkConfig.vlanId;
      interface = "ens18";
    };
    
    interfaces."ens18.${toString networkConfig.vlanId}".useDHCP = true;
    
    defaultGateway = {
      address = networkConfig.gateway;
      interface = "ens18.${toString networkConfig.vlanId}";
    };
  };
}
```

---

## Summary

**Bootstrap sequence:**
1. ✅ tappaas-cicd validates environment and loads JSON
2. ✅ Copies JSON to target Proxmox node
3. ✅ SSHs to node and runs VM creation script
4. ✅ Script clones template and configures VM
5. ❌ **BUG:** Configures network with access mode (`tag=210`)
6. ❌ **MISSING:** Cloud-init user-data with VLAN configuration
7. ❌ **MISSING:** Template with dynamic VLAN support
8. ❌ **CRITICAL:** `bridge-vids 2-4094` in /etc/network/interfaces sabotages even trunk mode
9. ❌ VM boots but DHCP fails due to bridge VLAN filtering bug

**To fix VM 999 now:** Use manual workaround (already provided).

**To fix Create-TAPPaaS-VM.sh:** Apply 4 changes above (implements ADR-001 + ADR-002 + bridge fix).
```