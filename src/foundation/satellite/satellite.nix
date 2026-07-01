# Copyright (c) 2026 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Satellite (external host)
# ============================================================================
# Version: 0.1.0  (ADR-010 P3 — nixos-anywhere-deployable; roles still stubbed P4-P6)
# Author: @larsrossen (TAPPaaS)
#
# Deployed onto an EXTERNAL host (a VPS or any machine with a public IP) by
# `satellite-manager` via nixos-anywhere — NOT a Proxmox VM. Built by the flake
# in this dir (flake.nix -> disko disk-config.nix + this module + the generated
# satellite-settings.nix). Per-deployment values (roles, ports, peer keys,
# addresses, operator key) live in satellite-settings.nix, regenerated per
# install from satellite.json. Role bodies (nginx/admin-relay/PBS) are stubbed;
# the tunnel + base are functional. TODO markers mark per-package work.
#
# Trust stance (ADR-010 §1, §7): blind relay + blind vault. The host holds no
# plaintext and no cluster-held credential; management is one-directional (the
# home/tunnel side can never reach this host's SSH or PBS-admin).
# ============================================================================

{ config, lib, pkgs, ... }:

let
  # Per-deployment values (roles, ports, peer keys, addresses, operator SSH key)
  # generated from satellite.json by satellite-manager. A committed default is
  # shipped for reference/testing; satellite-manager regenerates it per install.
  cfg = import ./satellite-settings.nix;
  hasRole = r: lib.elem r cfg.roles;
in
{
  # Filesystems + partitioning come from disko (disk-config.nix) via the flake.
  # No hardware-configuration.nix — this deploys to a fresh cloud host with
  # nixos-anywhere. Kernel modules for a Hetzner-style KVM (virtio-scsi + sda).
  boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.kernelModules = [ ];

  # ==========================================================================
  # BASE + BOOT (BIOS/Legacy GRUB on the single disk — Hetzner Cloud x86)
  # ==========================================================================
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
    # grub.devices is provided by disko (disk-config.nix) — setting it here too
    # would duplicate the device in mirroredBoots. cfg.bootDevice documents it.
  };
  networking.hostName = lib.mkDefault (cfg.hostName or "satellite");
  networking.useDHCP = lib.mkDefault true;   # Hetzner provides the public IP via DHCP on eth0
  time.timeZone = lib.mkDefault "UTC";
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # ==========================================================================
  # SSH — operator out-of-band key only; key auth only; no cluster-held key
  # (ADR-010 §7.3 rule 1/2). The provisioning credential is revoked post-install.
  # ==========================================================================
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin = "prohibit-password";
  };
  users.users.root.openssh.authorizedKeys.keys = cfg.operatorSshKeys;

  # ==========================================================================
  # HOST FIREWALL — one-directional management (ADR-010 §7.3 rule 4)
  # The home/tunnel side must NOT reach this host's SSH (22) or PBS-admin (8007).
  # Public: 443/tcp + 80/tcp (reverse-proxy), wgPort/udp (tunnel), adminWgPort/udp
  # (admin-vpn). Opened per active role below.
  # ==========================================================================
  networking.firewall = {
    enable = true;
    allowedTCPPorts = lib.optionals (hasRole "reverse-proxy") [ 443 80 ];
    allowedUDPPorts =
      [ cfg.tunnel.wgPort ]
      ++ lib.optionals (hasRole "admin-vpn") [ cfg.adminWgPort ];
    # TODO[P7]: explicitly DROP the tunnel interface -> {22,8007}; allow SSH only
    # from the operator's out-of-band source.
  };

  # ==========================================================================
  # WireGuard INFRA TUNNEL — satellite LISTENS; home dials out (ADR-010 §4, P2)
  # ==========================================================================
  # The satellite's private key is GENERATED ON-HOST and never leaves it
  # (ADR-010 §7.1 #1): NixOS creates /etc/wireguard/wg-infra.key on first
  # activation if absent. satellite-manager reads back only the PUBLIC key
  # (`wg show wg-infra public-key`) over SSH to configure the OPNsense peer.
  environment.systemPackages = [ pkgs.wireguard-tools ];

  networking.wireguard.interfaces.wg-infra = {
    listenPort = cfg.tunnel.wgPort;
    ips = [ "${cfg.tunnel.satelliteAddr}/31" ];
    privateKeyFile = "/etc/wireguard/wg-infra.key";
    generatePrivateKeyFile = true;   # on-host, first activation only; never leaves the host
    # The home (OPNsense) peer is added once its public key is known (P3 read-back).
    # NO `endpoint` here — HOME dials in (the satellite only listens); WireGuard
    # roaming learns the home source address from the handshake. PersistentKeepalive
    # lives on the HOME side to keep the CGNAT pinhole open.
    peers = lib.optionals (cfg.homePublicKey != "") [
      {
        publicKey = cfg.homePublicKey;
        allowedIPs = [ "${cfg.tunnel.homeAddr}/32" ];
      }
    ];
  };

  # ==========================================================================
  # ROLE: reverse-proxy — nginx `stream` L4 passthrough + PROXY protocol v2
  # (ADR-010 §2, §5.8). All :443 -> Caddy-on-OPNsense over the tunnel; :80 too
  # (Caddy issues the redirect). The satellite NEVER terminates TLS.
  # ==========================================================================
  services.nginx = lib.mkIf (hasRole "reverse-proxy") {
    enable = true;
    # L4 TCP passthrough to Caddy-on-OPNsense over the tunnel — nginx NEVER
    # terminates TLS (ADR-010 §2/§5.8). Single home cluster => plain passthrough
    # of ALL :443 to Caddy, which does the SNI/host routing. `proxy_protocol on`
    # preserves the real client IP for ADR-005 zone ACLs; it REQUIRES Caddy to
    # expect PROXY protocol on the tunnel listener, so it is gated on the
    # `proxyProtocol` setting (enable once the Caddy side is wired).
    streamConfig =
      let pp = lib.optionalString (cfg.proxyProtocol or false) "\n      proxy_protocol on;";
      in ''
        server {
          listen 443;
          proxy_pass ${cfg.homeCaddyAddr}:443;${pp}
        }
        server {
          listen 80;
          proxy_pass ${cfg.homeCaddyAddr}:80;${pp}
        }
      '';
  };

  # ==========================================================================
  # ROLE: admin-vpn — BLIND UDP relay of an admin WireGuard session that
  # terminates on OPNsense (ADR-010 §6). The satellite holds no admin keys — it
  # only NATs adminWgPort/udp to the OPNsense admin-WG listener over the infra
  # tunnel (admin<->OPNsense stays end-to-end encrypted; double-encapsulated on
  # the satellite->OPNsense hop, so admins set MTU ~1340 on their side).
  # ==========================================================================
  boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkIf (hasRole "admin-vpn") (lib.mkForce 1);
  networking.nftables.enable = lib.mkIf (hasRole "admin-vpn") true;
  networking.nftables.tables.adminvpn = lib.mkIf (hasRole "admin-vpn") {
    family = "ip";
    content = let alp = toString (cfg.adminListenPort or cfg.adminWgPort); in ''
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        udp dport ${toString cfg.adminWgPort} dnat to ${cfg.homeAdminWgAddr}:${alp}
      }
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip daddr ${cfg.homeAdminWgAddr} udp dport ${alp} masquerade
      }
    '';
  };

  # ==========================================================================
  # ROLE: backup — off-site PBS, PULL model; S3 Object-Lock backend by default
  # (ADR-010 §3). Stores ciphertext only (client-side encrypted at home).
  # ==========================================================================
  # TODO[P6]: proxmox-backup-server; datastore on S3 (Object Lock) or a ZFS volume;
  #           register home PBS as a pull remote (--remove-vanished false, read-only
  #           token); reuse the #228 verify/prune schedule; tune Object-Lock retention
  #           vs. prune/GC.

  # ==========================================================================
  # UPDATES — pull-based, signed (ADR-010 §7.3 rule 3). The cluster never pushes.
  # ==========================================================================
  # TODO[P3]: system.autoUpgrade from the pinned/signed update.ref.

  system.stateVersion = "25.05";
}
