# templates — Design notes

Implementation and reference detail for the templates module. For the catalog entry see
[README.md](./README.md); for installation see [INSTALL.md](./INSTALL.md); for test
coverage see [TEST.md](./TEST.md).

## What this module is

Two things, deliberately kept together:

1. **Template images** — Proxmox template VMs the platform clones app VMs from:
   `tappaas-nixos` (VMID 8080, prebuilt image) and `tappaas-winserver` (VMID 8081,
   built on-cluster).
2. **Per-OS service hooks** (`services/nixos`, `services/debian`, `services/windows`) —
   lifecycle scripts run for every consumer module that declares
   `dependsOn: ["templates:<os>"]`. They apply/refresh the OS configuration on the
   *consumer's* VM (`install-service.sh` delegates to `update-service.sh`, which runs
   the OS update — nixos-rebuild for NixOS, apt for Debian, the phased Windows baseline
   for Windows).

## Files

| File | Role |
|------|------|
| `templates.json` | Module json (`tier: foundation`, `provides: ["nixos", "debian"]`). |
| `tappaas-nixos.json` | Build config for the NixOS template: VMID 8080, pinned `version` + `imageLocation` (GitHub Release), `imageType: img`. |
| `tappaas-nixos.nix` | Manual-install entry point: `configuration.nix` for installing the baseline by hand from the NixOS ISO (imports `hardware-configuration.nix` + `tappaas-common.nix`). |
| `tappaas-common.nix` | The hardware-agnostic TAPPaaS NixOS baseline — shared verbatim by the prebuilt image and the manual path, and imported by every module's own `.nix` (#324). It declares no time zone: that is the site's fact, imported from the generated `/etc/nixos/tappaas-site.nix` when it exists (#472). |
| `flake.nix` / `flake.lock` | Builds the EFI qcow2 image (`nix build .#image`), pinned to `nixos-25.11` (same release as `system.stateVersion`). No `hardware-configuration.nix` — the image format module supplies disk/filesystem/bootloader. |
| `tappaas-winserver.json` | Build config for the Windows Server 2025 template: VMID 8081, installs from a local ISO (`imageType: iso`), `autoInstall: true`. |
| `winserver/` | The Windows template build (autounattend/oobe XML, `build-template.sh`, `deploy-vms.sh`) — see [winserver/README.md](winserver/README.md). |
| `services/<os>/` | The `templates:nixos` / `templates:debian` / `templates:windows` service hooks (see [services/windows/README.md](services/windows/README.md) for the Windows phases). |
| `update.sh` | Version-gated refresh of the NixOS template (below). |
| `test.sh` | Module tests (see [TEST.md](./TEST.md)). |

## How the NixOS image is built and shipped

- GitHub Actions builds the image from `flake.nix`/`tappaas-common.nix` and publishes it
  as a `nixos-template-v*` Release — see
  `.github/workflows/build-nixos-template-image.yml`.
- `tappaas-nixos.json` pins the `version` and `imageLocation` consumed on-cluster. The
  target version is therefore **branch-controlled**: stable branches stay on tested
  versions while `main` can point at newer builds.
- At bootstrap, `cluster/install-platform.sh` (Phase A) imports the image via
  `Create-TAPPaaS-VM.sh` and converts VM 8080 into a Proxmox template.
- The cicd VM is cloned from this image; since the image has no
  `/etc/nixos/hardware-configuration.nix`, the cicd `bootstrap.sh` generates one from
  the running hardware before its first `nixos-rebuild`.

## Hostname / DNS registration

The NixOS baseline sets `networking.hostName = lib.mkDefault ""` so cloud-init (Proxmox
`--name <vmname>`) owns the hostname, and ships a `tappaas-dhcp-hostname` oneshot that
sets `ipv4.dhcp-hostname` and does a full NetworkManager re-acquire so the DHCP lease
carries the correct name from first boot — even if the consumer overlay's
`nixos-rebuild` never runs. VM DNS registration works via dnsmasq **leases** on the
firewall (not `dns-manager` static pins). The full mechanism is documented inline in
`tappaas-common.nix`.

## update.sh — version-gated template refresh

`update.sh` keeps VM 8080 in sync with the version pinned in `tappaas-nixos.json`. It is
cheap to run regularly:

1. Compares the pinned version against the tag recorded on the template's node in
   `/root/tappaas/nixos-template.version`. Already current → exit 0, nothing downloaded.
2. **Pre-flight**: confirms the release asset URL answers HTTP 200 *before* destroying
   the existing template, so a bad release leaves the cluster untouched.
3. Stages `Create-TAPPaaS-VM.sh` + the module json (with `imageLocation` pinned to the
   resolved release tag) to the node, destroys the old 8080, recreates it from the new
   image (~700 MB download — the only expensive step), converts it to a template and
   records the new tag in the marker file.

Updating the template affects only **new** clones; VMs already cloned from an older
template are independent (full clones) and update via their own nixos-rebuild.

`tappaas-nixos.json` is stored in Pattern-A form (vm fields nested under
`.config."cluster:vm"`); `update.sh` flattens it with `normalize_module_config` before
reading.

## Testing

See [TEST.md](./TEST.md). Known gap: `services/nixos/test-service.sh` is a stub with no
assertions — the NixOS baseline of consumer VMs is effectively unverified despite a
green exit; implementing it is the tracked open item.

## The site's facts on a running VM (#472, #87)

A module VM does not build from this directory. Before every `nixos-rebuild
switch` on the guest, `update-os.sh` ships one generated file to `/etc/nixos`:

| File | Where it comes from | What it carries |
|---|---|---|
| `tappaas-site.nix` | generated from `config/site.json` by `lib/site-locale.sh` | the site's time zone, locale, console keymap and time source |

Each module's own `.nix` imports it, so the site's answers (recorded per #408)
reach every guest without any module restating them. Before this, thirteen
modules each hard-coded a time zone and six disagreed with the site.

**The baseline itself is not shipped to guests yet.** Every module `.nix` still
carries its own copy of what is here — ssh, cloud-init, the `tappaas` user, the
nix settings, `system.stateVersion` — so importing `tappaas-common.nix` makes
NixOS refuse the build with conflicting definitions at equal priority. Proven on
the test site 2026-09-20: `system.stateVersion` is `25.11` here and `25.05` in
every module. De-duplicating those copies so the baseline can be imported is
**#324**; `tappaas-common.nix` imports `tappaas-site.nix` itself, so the manual
and image paths already get the site's facts.

The mothership is built from the repository flake rather than by `update-os.sh`,
so `tappaas-self-rebuild.sh` writes the same generated fragment before it
rebuilds, and `tappaas-cicd.nix` imports it the same way.
