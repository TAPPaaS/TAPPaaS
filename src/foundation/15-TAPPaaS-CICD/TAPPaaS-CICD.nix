# ----------------------------------------
# Version: 1.0.0 – tappaas PVE VM Template
# State: Released
# Date: 2025-10-16
# Author: Erik, Lars (Tappaas)
# Purpose: 
#     Declarative common baseline NIXOS VM Template for all tappaas pve-nixos-vm 
#
#     Edit this configuration file to define what should be installed on
#     your system. Help is available in the configuration.nix(5) man page, on
#     https://search.nixos.org/options and in the NixOS manual (`nixos-help`).
#
# ✅ **Automated provisioning** via cloud-init
# ✅ **Consistent base system** across all clones  
# ✅ **CICD integration** with SSH key authentication
# ✅ **Scalable resources** post-deployment
# ✅ **QEMU integration** for proper Proxmox management
# ✅ **Security hardening** with minimal attack surface
#
# Modules:
#     openssh  
#     QEMU   
#
# ----------------------------------------

{ config, lib, pkgs, modulesPath, system, ... }:

{
  imports =
    [ # Note we are not doing hardware includes
      (modulesPath + "/virtualisation/proxmox-image.nix")
      /home/tappaas/TAPPaaS-Base.nix
    ];

  proxmox.qemuConf = {
      cores = 2;
      memory = 4096;
      name="tappaas-cicd";
      net0="virtio=12:34:56:AA:AC:CD,bridge=lan";
      serial0="/dev/ttyS0";
      virtio0="local-zfs:vm-tappaas-disk-0";
  };
