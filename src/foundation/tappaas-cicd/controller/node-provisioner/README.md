# node-provisioner

The **PXE provisioning controller** for TAPPaaS follow-on nodes — Phase N3 of
[docs/design/node-provisioning.md](../../../../../docs/design/node-provisioning.md).
It runs on tappaas-cicd and netboots the Proxmox VE
automated installer for *registered* pending nodes: the box PXE-boots, the
installer posts its system info, and the matching node gets a generated
per-node `answer.toml` back — hands-free PVE install.

**Status: IMPLEMENTED-PENDING-HARDWARE-VALIDATION** — the netboot recipe and
answer flow follow the PVE ≥ 8.2 automated-installation docs but have not yet
been exercised against real hardware/ISO (see the V-2 list in the design doc).

## Operator flow

```bash
# 0. ONCE per PVE release: prepare the ISO on any PVE node (bakes the answer
#    URL into the ISO — the installer fetches its answer from there), copy it
#    to cicd, then stage the netboot assets (needs sudo for the loop mount):
#      proxmox-auto-install-assistant prepare-iso proxmox-ve_9.x.iso \
#          --fetch-from http --url http://<cicd-mgmt-ip>:8090/answer
sudo node-provisioner prepare --iso /var/tmp/proxmox-ve_9.x-auto-from-http.iso

# 1. Register the new node (the allowlist entry). Pin the MAC if you know it;
#    without a MAC the node only matches while it is the ONLY pending one.
#    The boot disk (and --boot-mirror) as fields the installer's /init matches
#    against the machine's disks in its own boot (ADR-037 D4): a size (2TB), a
#    model or a serial; blank, the smallest SSD/NVMe disk, both of an identical
#    smallest pair mirrored; 'ask' asks on the console, as does a field that
#    matches nothing. boot.ipxe carries each pending registration's fields on
#    the kernel command line, chosen by the netbooting MAC.
node-provisioner register tappaas3 --mac aa:bb:cc:dd:ee:ff --boot-disk 2TB

# 2. Open the (TTL-limited) provisioning window:
#    starts the HTTP answer/asset server + a TFTP server (transient systemd
#    units) and sets the PXE options on the mgmt DHCP scope via dhcp-manager.
node-provisioner enable            # default TTL 7200 s = 2 h

# 3. Boot the box: PXE first in BIOS, NIC on the mgmt VLAN, power on, walk
#    away. Progress: `node-provisioner status`, `journalctl -u tappaas-pxe`.

# 4. Close the window as soon as the install is running (the TTL timer does
#    it anyway):
node-provisioner disable
```

After the install the node's generated root password sits in
`/home/tappaas/.node-secrets/<name>.pw` (the operator's, 0600; directory 0700) and the cicd tappaas SSH key
is in the node's root `authorized_keys`. Joining the cluster is Phase N4
(today: run `foundation/install.sh` on the node; the next `update-tappaas`
captures it via `site-manager node reconcile`).

## Verbs

| Verb | What it does |
|------|--------------|
| `register <name> [--mac ..]* [--pool 'p=layout:disks']*` | Write a pending registration (`$TAPPAAS_CONFIG/provision/<name>.json`) — the allowlist. |
| `unregister <name>` / `list` | Manage/inspect pending registrations. |
| `prepare --iso <path>` | Stage netboot assets under `/var/lib/tappaas-pxe`: loop-mounts the ISO, extracts `boot/linux26` + `boot/initrd.img`, copies the whole ISO, appends it to the initrd as a newc cpio (`proxmox.iso`), writes `boot.ipxe`. Run with sudo. |
| `serve [--port 8090]` | Foreground HTTP server: GET = read-only assets (no dir listing); `POST /answer` = system-info matching + answer.toml. `enable` runs this as a unit. |
| `enable [--ttl 7200]` | `systemd-run` transient units `tappaas-pxe.service` (serve) + `tappaas-pxe-tftp.service` (dnsmasq `--port=0 --enable-tftp`, TFTP-only — OPNsense stays the only DHCP server), then `dhcp-manager pxe enable --next-server <cicd-mgmt-ip> --bootfile ipxe.efi --ipxe-script-url http://<ip>:<port>/boot.ipxe`, then arms `tappaas-pxe-ttl.timer` to auto-run `disable`. |
| `disable` | Stops all transient units + `dhcp-manager pxe disable`. |
| `status` | Unit states, pending registrations, DHCP PXE state (exit 0 = fully enabled). |

## How a node is matched (the safety interlock)

The PVE installer POSTs the machine's system info (MACs under
`network_interfaces[].mac`, DMI serial). Matching, in order:

1. a posted MAC equals a registered MAC → that node;
2. otherwise, if EXACTLY ONE pending registration exists and it pins no
   MACs → that node (a `--mac`-pinned registration answers only its own
   machine, so another host's request cannot consume it);
3. otherwise → **404, no answer, installer stops**, refusal is logged.

A served answer **consumes** the registration
(`<name>.json` → `<name>.json.consumed`) — one-shot, it can never answer
twice.

## Security model (design §4)

- **Off by default, TTL-limited** — `enable` arms an auto-`disable` timer
  (default 2 h); a network-boot trap never lingers.
- **Registrations are the allowlist** — unknown machines get no answer.
- **`serve` binds 0.0.0.0** — network scoping comes from placement:
  tappaas-cicd's provisioning traffic rides the **mgmt VLAN** (the untagged
  control plane; hypervisor NICs and the DHCP scope carrying the PXE options
  live there) and mgmt accepts no inbound pinholes from other zones. Do not
  port-forward or pinhole the provisioning port.
- **Answers carry secrets** (root password, SSH keys): generated per node,
  stored 0600 under `~/.node-secrets/`, served once. Day-2 access is
  SSH-keys-only. TODO(V-2): plain HTTP today — evaluate HTTPS + the
  assistant's `--cert-fingerprint` pinning (design V-3) before relying on it
  on a shared mgmt segment.

## Runtime dependencies (on tappaas-cicd)

- `dhcp-manager` (opnsense-controller family) for the DHCP PXE options;
- `systemd-run`/`systemctl` (transient units; sudo when not root);
- `mount`/`umount` + `cpio` for `prepare` (run it with sudo);
- **dnsmasq** for TFTP-only serving — if absent from the cicd closure,
  `enable` warns: add `pkgs.dnsmasq` to the tappaas-cicd NixOS configuration
  (TODO: nix addition);
- an **iPXE UEFI binary** (`ipxe.efi`) in `/var/lib/tappaas-pxe/tftp/` —
  `enable` stages it from `$TAPPAAS_IPXE_EFI` or builds `pkgs.ipxe` via
  nix-build on demand.

## Firmware: UEFI netboot and the boot order

The provisioner serves a UEFI netboot. On a board whose firmware offers both,
switch CSM/legacy off (or set the network stack to UEFI) before step 3.

**Legacy-only firmware.** A board that can only netboot in legacy (CSM) mode
needs the BIOS iPXE loader instead of the UEFI one:

    node-provisioner enable --bootfile undionly.kpxe

`enable` stages the requested file from `pkgs.ipxe` the same way it stages
`snp.efi`. This path has not been run on hardware; the PVE installer then
installs in legacy mode.

**Boot order after the install.** The firmware keeps netbooting while the
network entry is first; the registration is consumed, so the next answer is a
404 and the installer stops. On UEFI, `site-manager node add --install` puts the
installed disk first itself once the node is up. When it cannot (it says so),
or on legacy firmware, set the installed disk first in the firmware setup — or,
on a UEFI node, from its shell:

    efibootmgr                  # lists BootOrder and the entries
    efibootmgr -o <proxmox>,<rest...>

## Configuration / paths

| Path | Purpose |
|------|---------|
| `${TAPPAAS_CONFIG:-/home/tappaas/config}/provision/` | pending registrations |
| `${TAPPAAS_CONFIG:-/home/tappaas/config}/site.json` | country/timezone/email for the answer |
| `${TAPPAAS_PXE_DIR:-/var/lib/tappaas-pxe}` | netboot assets (kernel, initrd, ISO, boot.ipxe, tftp/) |
| `${TAPPAAS_NODE_SECRETS:-/home/tappaas/.node-secrets}` | generated node root passwords (0600) |

Node FQDNs are `<name>.mgmt.internal` (the mgmt control plane; site.json has
no site-wide domain — domains are per-environment), override with
`serve --domain`.

## Testing

`./test.sh` — builds via nix (falls back to system python3), smokes
`node-provisioner --help`, and runs the offline unit tests
(`python -m unittest` over `src/test/`): registration CRUD, answer matching,
answer.toml rendering, one-shot consumption. No firewall, ISO or systemd
needed.
