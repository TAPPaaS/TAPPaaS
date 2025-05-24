# define the provider
terraform {
  required_version = ">= 1.9" # Or your OpenTofu version
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.29.0" # Or the latest version
    }
  }
}


# Configure the Proxmox provider
provider "proxmox" {
  host = "192.168.2.250"
  user = "root"
  # password = "your_proxmox_password"
  # Optional: Use API key instead of password
  api_key = "b412fbcd-6d41-4fe3-a7c5-5cb30ccc9d11"
}

# Create the Proxmox VM
resource "proxmox_vm_qemu" "example" {
  name  = "OPNsense"          # VM name
  vmid  = 500              # VM ID (must be unique)
  node  = "your_proxmox_node_name"    # The name of the Proxmox node where the VM will be created
  description = "My first VM"
  # ... other VM properties

  # Boot configuration
  boot {
    order = "scsi0"  # Boot from hard disk (adjust as needed)
  }

  # Define the disk configuration
  disk {
    size = "32G"       # Disk size
    type = "scsi0"    # Disk type (adjust as needed)
  }

  # Define the ISO image
  cdrom {
    path = "iso/ubuntu-22.04-desktop-amd64.iso"  # Path to the ISO image on Proxmox
    # For remote ISO, use:
    # url = "http://example.com/iso/ubuntu-22.04-desktop-amd64.iso"
  }

  # Define network configuration
  network {
    bridge = "vmbr0"     # Proxmox network bridge
    ip_address = "192.168.1.101"  # Static IP (optional)
    gateway = "192.168.1.1"      # Gateway (optional)
    netmask = "255.255.255.0"    # Netmask (optional)
    type = "bridge"            # Network type
  }

  # Other VM configuration (CPU, memory, etc.)
}