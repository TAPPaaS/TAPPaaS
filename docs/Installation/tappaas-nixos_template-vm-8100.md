# NixOS Proxmox Template Setup Guide

## Overview
Create a minimal, cloud-init enabled NixOS template for Proxmox VE that can be cloned for diverse workloads including AI/ML applications, databases, and web services.

## VM Configuration

### Hardware Specifications
- **CPU**: 2 cores (easily scalable post-clone)
- **RAM**: 4GB (scalable via hotplug)
- **Disk**: 32GB (expandable after cloning)
- **BIOS**: OVMF (UEFI) - modern standard
- **Network**: vmbr0 bridge
- **Notes**:

<div align='center'>
  <a href='https://tappaas.org' target='_blank' rel='noopener noreferrer'>
    <img src='https://www.tappaas.org/taapaas.png' alt='Logo' style='width:81px;height:112px;'/>
  </a>

  <h2 style='font-size: 24px; margin: 20px 0;'>TAPPaaS NIXOS Template</h2>

  <span style='margin: 0 10px;'>
    <i class="fa fa-github fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/TAPpaas/TAPpaas' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>GitHub</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-comments fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/TAPpaas/TAPpaas/discussions' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Discussions</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-exclamation-circle fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/TAPpaas/TAPpaas/issues' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Issues</a>
  </span>
  <br>
  <br>
  This is the template for the generic TAPPaaS VM. It is based on NIXOS (25.05).
</div>


### Rationale
- **Minimal resources**: Template stays lean, scale per workload
- **UEFI boot**: Better hardware support and security
- **Cloud-init drive**: Automated VM provisioning

## Template Design Principles

### Services Included
| Service | Purpose | Rationale |
|---------|---------|-----------|
| SSH Server | Remote access | DevOps standard |
| QEMU Guest Agent | Proxmox integration | Proper shutdown, monitoring, IP reporting |
| Cloud-init | Automated provisioning | SSH keys, network config, user setup |
| NetworkManager | Network management | Handles diverse network configs |

### Services Excluded (Add per clone)
- Docker/Podman (workload-specific)
- GPU drivers (only for AI/ML clones)
- Application-specific databases
- Web servers

### Security Configuration
- **SSH**: Key-only authentication, no root login
- **User access**: `tappaas` user with passwordless sudo
- **Firewall**: Basic SSH access only

## Installation Steps

### Prerequisites
- NixOS 25.05 ISO mounted to VM
- Cloud-init drive configured with SSH public key
- VM booted into NixOS live environment

### 1. Disk Partitioning
```bash
# Interactive partitioning
sudo parted /dev/sda
mklabel gpt
mkpart ESP fat32 1MiB 513MiB
set 1 esp on
mkpart primary ext4 513MiB 100%
print
quit
```

**Expected output**: `/dev/sda1` (512MB ESP) and `/dev/sda2` (~31GB primary)

**Rationale**: Simple UEFI + single root partition for maximum flexibility

### 2. Format Filesystems
```bash
# Format EFI boot partition
sudo mkfs.fat -F 32 -n boot /dev/sda1

# Format root partition  
sudo mkfs.ext4 -L nixos /dev/sda2
```

**Rationale**: ext4 for stability and broad application support

### 3. Mount Filesystems
```bash
# Mount root partition
sudo mount /dev/sda2 /mnt

# Create boot directory and mount EFI partition
sudo mkdir -p /mnt/boot
sudo mount /dev/sda1 /mnt/boot

# Verify mounts
df -h | grep /mnt
```

**Expected output**: Both `/dev/sda2` on `/mnt` and `/dev/sda1` on `/mnt/boot`

### 4. Generate Configuration
```bash
# Generate initial configuration
sudo nixos-generate-config --root /mnt

# Verify files created
ls -la /mnt/etc/nixos/
```

### 5. Template Configuration
Edit `/mnt/etc/nixos/configuration.nix`:

```bash
sudo nano /mnt/etc/nixos/configuration.nix
```

**Replace entire contents** with this optimized template configuration:

```nix
{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  # Boot loader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Network
  networking.hostName = "nixos-template";
  networking.networkmanager.enable = true;

  # Time zone (will be overridden by cloud-init)
  time.timeZone = "UTC";

  # Users
  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [
      # SSH keys will be injected by cloud-init
    ];
  };

  # Enable passwordless sudo for tappaas
  security.sudo.wheelNeedsPassword = false;

  # Essential services
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # QEMU Guest Agent
  services.qemuGuest.enable = true;

  # Cloud-init
  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  # Auto-grow root partition
  boot.growPartition = true;

  # System packages
  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    htop
    git
  ];

  # Enable automatic garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # System version
  system.stateVersion = "25.05";
}
```

### Configuration Explanations

| Setting | Value | Rationale |
|---------|--------|-----------|
| `boot.growPartition` | `true` | Auto-expand disk when cloned with larger storage |
| `networking.hostName` | `"nixos-template"` | Will be overridden by cloud-init per clone |
| `security.sudo.wheelNeedsPassword` | `false` | Enables automation from CICD systems |
| `services.openssh.settings.PasswordAuthentication` | `false` | Force SSH key authentication only |
| `time.timeZone` | `"UTC"` | Consistent baseline, customizable per clone |
| `nix.gc.automatic` | `true` | Prevents disk space buildup over time |

### 6. Install NixOS
```bash
# Start the installation
sudo nixos-install
```

**Process expectations**:
- Takes 5-15 minutes depending on network speed
- Downloads and installs packages
- Sets up bootloader
- Prompts for root password at the end

### 7. Handle Root Password
When prompted for root password:
```bash
# Set a simple password like "tappaas"
# This is only for emergency console access
# Root SSH login is disabled in our configuration
```

### 8. Reboot and Remove Installation Media
```bash
# Complete installation and reboot
sudo reboot
```

**Important**: Disable CD/DVD boot or remove ISO:
- **Option A**: In Proxmox GUI → VM Hardware → Edit CD/DVD → "Do not use any media"
- **Option B**: In Proxmox GUI → Options → Boot Order → Disable CD/DVD

### 9. Template Cleanup via SSH
After reboot, console login may not work (this is normal - cloud-init manages SSH access). Connect from your CICD machine:

```bash
# SSH into the VM (cloud-init should have configured your SSH key)
ssh tappaas@[VM_IP_ADDRESS]

# Run template cleanup commands
sudo nix-collect-garbage -d
sudo rm -rf /tmp/*
sudo rm -rf /var/tmp/*
sudo journalctl --vacuum-time=1s

# Clear machine-id for unique identification per clone
sudo rm -f /etc/machine-id
sudo touch /etc/machine-id

# Clear SSH host keys (regenerated uniquely per clone)  
sudo rm -f /etc/ssh/ssh_host_*

# Clear cloud-init state (runs fresh on each clone)
sudo cloud-init clean

# Power off for template conversion
sudo poweroff
```

## Template Conversion and Testing

### 10. Convert VM to Template
**Option A - Proxmox GUI**:
1. Select VM 8100 → "More" → "Convert to template"
2. Confirm conversion

**Option B - Command Line**:
```bash
# From Proxmox host
qm template 8100
```

### 11. Verify Template Configuration
In Proxmox GUI, confirm:
- ✅ VM shows "template" status
- ✅ Options → QEMU Guest Agent = Enabled  
- ✅ Cloud-Init tab shows your SSH public key

### 12. Test Template by Cloning
```bash
# Clone template to test VM
qm clone 8100 200 --name "nixos-test-clone"

# Start the clone
qm start 200

# Wait 1-2 minutes for cloud-init to complete
# Then test SSH access
ssh tappaas@[CLONE_VM_IP]
```

## Cloning and Usage

### Clone Template
```bash
# Clone template (example: VM ID 201)
qm clone 8100 201 --name "my-app-server"
```

### Cloud-init Configuration Example
```yaml
# In Proxmox GUI -> Cloud-Init tab
user: tappaas
password: [leave empty - using SSH keys]
SSH public key: [your public key]
IP Config: dhcp (or static IP configuration)
```

### Post-Clone Scaling
```bash
# Increase RAM to 8GB
qm set 201 --memory 8192

# Add CPU cores
qm set 201 --cores 4

# Expand disk to 100GB
qm resize 201 scsi0 +68G
```

## Workload-Specific Clone Examples

### AI/ML Server (vLLM, OpenWebUI)
```bash
# Clone and configure
qm clone 8100 201 --name "ai-server"
qm set 201 --memory 16384 --cores 8
# Add GPU passthrough in hardware settings
# Configure CUDA drivers post-boot
```

### Database Server
```bash
qm clone 8100 202 --name "postgres-server"  
qm set 202 --memory 8192
qm resize 202 scsi0 +68G  # 100GB total
```

### Web Application
```bash
qm clone 8100 203 --name "web-app"
qm set 203 --memory 4096 --cores 2  # Keep minimal
```

## CICD Integration

### Access Pattern
- CICD VM connects to all clones via SSH
- Uses `tappaas` user with your SSH key
- Passwordless sudo for automation
- Consistent username across all VMs

### Example Ansible Inventory
```yaml
all:
  children:
    nixos_servers:
      hosts:
        ai-server:
          ansible_host: 10.0.0.201
        postgres-server:
          ansible_host: 10.0.0.202
        web-app:
          ansible_host: 10.0.0.203
      vars:
        ansible_user: tappaas
        ansible_ssh_private_key_file: ~/.ssh/id_rsa
```

## Troubleshooting Notes

### Boot Time Expectations
- **First clone boot**: 1-2 minutes (cloud-init setup)
- **Subsequent boots**: 30-60 seconds
- **Console login**: May not work (use SSH instead)

### SSH Connection Issues
If SSH fails:
1. Wait longer (cloud-init may still be running)
2. Check VM console for boot messages
3. Verify IP address in Proxmox Summary tab
4. Confirm VM has fully booted (not just at login prompt)

### Template Customization per Clone
Common post-clone configurations:
```bash
# Change hostname permanently
sudo hostnamectl set-hostname "new-hostname"

# Install application-specific packages
sudo nixos-rebuild switch --upgrade

# Add Docker/Podman for containerized apps
# Add GPU drivers for AI/ML workloads  
# Configure firewalls for specific services
```

## Maintenance

### Template Updates
```bash
# Clone template to temporary VM
qm clone 8100 999 --name "template-update"

# Boot, update system, test
ssh tappaas@[temp-vm-ip]
sudo nixos-rebuild switch --upgrade

# Clean and convert updated VM to new template
# Replace old template when satisfied
```

### Clone Resource Management
```bash
# Monitor disk usage across clones
# Run garbage collection regularly
sudo nix-collect-garbage -d

# Resize resources as needed
qm set [VM_ID] --memory [SIZE]
qm set [VM_ID] --cores [COUNT] 
qm resize [VM_ID] scsi0 +[SIZE]G
```

## Benefits of This Approach

✅ **Consistency**: Same base across all VMs  
✅ **Scalability**: Easy resource adjustment post-clone  
✅ **Automation**: Full cloud-init and CICD integration  
✅ **Efficiency**: Minimal template, add services as needed  
✅ **Maintenance**: Centralized template updates  
✅ **Security**: Key-based authentication, minimal attack surface

## Production Deployment Ready

Your NixOS template now provides:
- ✅ **Automated provisioning** via cloud-init
- ✅ **Consistent base system** across all clones  
- ✅ **CICD integration** with SSH key authentication
- ✅ **Scalable resources** post-deployment
- ✅ **QEMU integration** for proper Proxmox management
- ✅ **Security hardening** with minimal attack surface

Template is production-ready for deploying diverse workloads including AI/ML applications, databases, web services, and development environments.