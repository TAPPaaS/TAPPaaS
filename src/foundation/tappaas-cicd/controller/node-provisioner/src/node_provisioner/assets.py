"""Stage netboot assets from a Proxmox VE ISO (``node-provisioner prepare``).

Recipe (the known-good PVE-ISO-to-PXE repack, cf. the community
pve-iso-2-pxe recipe; TODO(V-2): validate against the current PVE 9.x ISO
on hardware):

1. loop-mount the ISO read-only (``mount -o loop,ro`` — needs root/sudo;
   ``7z x <iso> boot/linux26 boot/initrd.img`` is the unprivileged
   alternative, not used here because p7zip is not part of the cicd
   closure) and copy out the installer kernel ``boot/linux26`` and
   ``boot/initrd.img``;
2. copy the WHOLE ISO into the asset dir as ``proxmox.iso`` (also served
   over HTTP);
3. build the netboot ``initrd`` = original initrd.img + a newc cpio
   archive containing ``proxmox.iso`` at its root — the installer's early
   userspace locates the ISO inside the initramfs;
4. write ``boot.ipxe``: chainloads kernel+initrd over HTTP with the
   ``proxmox-start-auto-installer`` cmdline flag (no ``proxdebug``) so the
   installer runs unattended and fetches its answer over HTTP.

IMPORTANT (answer fetch, design N3): the HTTP answer URL is baked INTO the
ISO, not the kernel cmdline — the given ISO must have been prepared with

    proxmox-auto-install-assistant prepare-iso <stock.iso> \
        --fetch-from http --url http://<cicd-mgmt-ip>:8090/answer

on a machine that has the assistant (any PVE node). TODO(V-2): confirm on
hardware that the prepared ISO's auto-installer-mode.toml survives the
initrd-embedding recipe and that no additional kernel args (answer
partition/url) are needed for the deployed PVE version.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

from .log import info, warn
from .util import DEFAULT_PORT, pxe_dir, run

KERNEL_IN_ISO = "boot/linux26"
INITRD_IN_ISO = "boot/initrd.img"
ISO_ASSET_NAME = "proxmox.iso"

BOOT_IPXE_TEMPLATE = """#!ipxe
# TAPPaaS node provisioning (design N3) — Proxmox VE automated installer.
# ${{next-server}} is the DHCP-provided TFTP server = the cicd mgmt IP.
# Kernel args: proxmox-start-auto-installer runs the installer unattended
# (answer fetched over HTTP per the URL prepared INTO the ISO); no proxdebug.
# TODO(V-2): validate args against the deployed PVE ISO on hardware.
echo TAPPaaS node provisioner: booting Proxmox VE automated installer
kernel http://${{next-server}}:{port}/linux26 ro ramdisk_size=16777216 rw splash=silent proxmox-start-auto-installer
initrd http://${{next-server}}:{port}/initrd
boot
"""


def prepare(iso: str, directory=None, port: int = DEFAULT_PORT) -> Path:
    """Stage kernel/initrd/ISO/boot-script under the PXE asset directory."""
    iso_path = Path(iso).expanduser().resolve()
    if not iso_path.is_file():
        raise FileNotFoundError(f"ISO not found: {iso_path}")

    dest = Path(directory) if directory else pxe_dir()
    try:
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "tftp").mkdir(exist_ok=True)
    except PermissionError as e:
        raise PermissionError(
            f"cannot create {dest} — run prepare as root (sudo)") from e

    # 1. + first half of 3.: extract kernel + initrd via loop mount.
    mnt = Path(tempfile.mkdtemp(prefix="tappaas-pxe-iso."))
    initrd_out = dest / "initrd"
    try:
        info(f"loop-mounting {iso_path.name}...")
        run(["mount", "-o", "loop,ro", str(iso_path), str(mnt)],
            privileged=True)
        try:
            kernel_src = mnt / KERNEL_IN_ISO
            initrd_src = mnt / INITRD_IN_ISO
            for src in (kernel_src, initrd_src):
                if not src.is_file():
                    raise FileNotFoundError(
                        f"{src.relative_to(mnt)} not in ISO — not a PVE "
                        "installer ISO? (layout drift: V-2)")
            info(f"extracting {KERNEL_IN_ISO} -> {dest / 'linux26'}")
            shutil.copyfile(kernel_src, dest / "linux26")
            info(f"extracting {INITRD_IN_ISO} -> {initrd_out}")
            shutil.copyfile(initrd_src, initrd_out)
        finally:
            run(["umount", str(mnt)], privileged=True, check=False)
    finally:
        mnt.rmdir()

    # 2. whole ISO for HTTP serving + cpio embedding.
    iso_dest = dest / ISO_ASSET_NAME
    if iso_dest.exists() and iso_dest.stat().st_size == iso_path.stat().st_size:
        info(f"{ISO_ASSET_NAME} already staged (same size) — keeping it")
    else:
        info(f"copying ISO -> {iso_dest} ({iso_path.stat().st_size} bytes)")
        shutil.copyfile(iso_path, iso_dest)

    # 3. append the ISO to the initrd as a newc cpio archive (the PVE
    # initramfs picks the ISO out of its own filesystem).
    info("appending ISO to initrd (newc cpio)...")
    with open(initrd_out, "ab") as f:
        subprocess.run(
            ["cpio", "-L", "-H", "newc", "-o"],
            input=(ISO_ASSET_NAME + "\n").encode(),
            stdout=f,
            stderr=subprocess.PIPE,
            cwd=str(dest),
            check=True,
        )

    return _finish(dest, port)


def _finish(dest: Path, port: int) -> Path:
    # 4. iPXE boot script.
    boot_script = dest / "boot.ipxe"
    boot_script.write_text(BOOT_IPXE_TEMPLATE.format(port=port))
    info(f"wrote {boot_script}")

    # World-readable assets (dnsmasq tftp runs unprivileged; http serves them).
    for name in ("linux26", "initrd", ISO_ASSET_NAME, "boot.ipxe"):
        path = dest / name
        if path.exists():
            path.chmod(0o644)
    dest.chmod(0o755)
    (dest / "tftp").chmod(0o755)

    info(f"netboot assets staged under {dest}")
    warn("reminder: the ISO must be pre-prepared with "
         "'proxmox-auto-install-assistant prepare-iso --fetch-from http "
         "--url http://<cicd-mgmt-ip>:{}/answer' or the installer will not "
         "fetch its answer (V-2)".format(port))
    return dest
