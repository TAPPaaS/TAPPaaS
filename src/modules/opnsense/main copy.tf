# define the provider
terraform {
  required_version = ">= 1.9" # Or your OpenTofu version
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.78.0" # Or the latest version
    }
  }
}


# Configure the Proxmox provider
# For info on authentification see https://registry.terraform.io/providers/bpg/proxmox/latest/docs
# This simply set up tofu to use the root account. really we should set up a dedicated terraform user on server
provider "proxmox" {
  endpoint = var.node_endpoint
  api_token = var.api_token
  insecure = true
  ssh {
    agent = true
    username = var.admin_username
    password = var.admin_password
  }
}

resource "proxmox_virtual_environment_vm" "OPNsense_vm" {
  name        = "OPNsense"
  description = "TAPaaS OPNsense firewall VM, Managed by Terraform"
  tags        = ["terraform", "tapaas", "opnsense"]

  node_name = var.node_name
  vm_id     = 666

  agent {
    # read 'Qemu guest agent' section, change to true only when ready
    enabled = false
  }
  # if agent is not enabled, the VM may not be able to shutdown properly, and may need to be forced off
  stop_on_destroy = true

  startup {
    order      = "1"
    up_delay   = "0"
    down_delay = "60"
  }

  cpu {
    cores        = 4
    type         = "x86-64-v2-AES"  # recommended for modern CPUs
  }

  memory {
    dedicated = 4096 # in MB, adjust as needed
    floating  = 4096 # set equal to dedicated to enable ballooning
  }

  disk {
    datastore_id = "tank1"
    file_id      = proxmox_virtual_environment_download_file.opnsense_iso.id
    interface    = "scsi0"
  }


#  network_device {
#    bridge = "vmbr0"
#  }

  operating_system {
    type = "other"
  }

  serial_device {
    device = "socket"
  }

  virtiofs {
    mapping = "data_share"
    cache = "always"
    direct_io = true
  }
}

resource "proxmox_virtual_environment_download_file" "opnsense_iso" {
  content_type = "iso"
  datastore_id = "local"
  file_name   = "OPNsense-25.1-dvd-amd64.iso"
  node_name    = var.node_name
  url          = "https://opnsense.com/download/OPNsense-25.1-dvd-amd64.iso.bz2"
  overwrite    = false
}
 