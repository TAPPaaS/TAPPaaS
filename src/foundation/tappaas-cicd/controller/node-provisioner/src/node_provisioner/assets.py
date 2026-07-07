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

# Injected into the installer's /init right before switch_root (the installer
# root is an overlayfs with a tmpfs upper, so the sed lands in the writable
# upper layer). The stock installer gives dhclient only 10 seconds
# (etc/dhcp/dhclient.conf: "timeout 10;") and proxmox-fetch-answer fires
# exactly once — on hardware where the NIC re-trains its link after kernel
# takeover (plus any switch STP delay) that window is lost and the answer
# fetch dies with "Network unreachable" (stage-1 Atom, X553 NICs). 60s covers
# link training and a 30s STP listening/learning hold.
INIT_ANCHOR = "cp /etc/hostid /mnt/.installer-mp/etc/"
INIT_PATCH = INIT_ANCHOR + """
    # TAPPaaS node-provisioner: raise the DHCP timeout so the auto-installer
    # answer fetch has a live network (link re-training + STP eat the stock 10s)
    sed -i 's/^timeout 10;/timeout 60;/' /mnt/.installer-mp/etc/dhcp/dhclient.conf || true
    # TAPPaaS node-provisioner: ask-at-boot boot disk (registration made
    # without --boot-disk). The ONE question of the whole install: show the
    # machine's real disks, read the choice on the console, and hand it to
    # the answer server as a ?bootdisk= query parameter by bind-mounting a
    # rewritten auto-installer-mode.toml over the ISO's copy (the ISO is
    # read-only; a file bind on the already-bound /cdrom works). Pure
    # busybox sh — no sed/cut dependencies.
    if grep -q "tappaas.askdisk=1" /proc/cmdline; then
        _tap_mode=/mnt/.installer-mp/cdrom/auto-installer-mode.toml
        _tap_con="/dev/${console:-console}"
        if [ -f "$_tap_mode" ]; then
        {
            # Late device-probe chatter (USB etc.) otherwise scrolls the
            # menu away and buries the prompt (stage-1 operator feedback):
            # let probing settle, then keep the console to errors only
            # (the installer sets its own loglevel later anyway).
            sleep 3
            echo "1 1 1 7" > /proc/sys/kernel/printk 2>/dev/null || true
            echo ""
            echo "==== TAPPaaS node provisioning: choose the BOOT disk ===="
            echo "The chosen disk is WIPED (PVE system, ext4/LVM). Disks found:"
            for _tap_d in /sys/block/*; do
                _tap_b="${_tap_d##*/}"
                case "$_tap_b" in loop*|ram*|sr*|dm-*|zram*) continue ;; esac
                _tap_sz=$(cat "$_tap_d/size" 2>/dev/null || echo 0)
                echo "  $_tap_b  ($((_tap_sz / 2097152)) GB)  $(cat "$_tap_d/device/model" 2>/dev/null)"
            done
            _tap_disk=""
            while [ ! -e "/sys/block/$_tap_disk" ] || [ -z "$_tap_disk" ]; do
                printf "TAPPaaS boot disk> "
                read -r _tap_disk
            done
            _tap_url=""
            while IFS= read -r _tap_l; do
                case "$_tap_l" in url*) _tap_u="${_tap_l#*\\"}"; _tap_url="${_tap_u%\\"*}" ;; esac
            done < "$_tap_mode"
            if [ -n "$_tap_url" ]; then
                while IFS= read -r _tap_l; do
                    case "$_tap_l" in
                        url*) echo "url = \\"${_tap_url}?bootdisk=${_tap_disk}\\"" ;;
                        *) echo "$_tap_l" ;;
                    esac
                done < "$_tap_mode" > /tappaas-mode.toml
                mount --bind /tappaas-mode.toml "$_tap_mode"
                echo "TAPPaaS: boot disk '$_tap_disk' goes to the answer server"
            else
                echo "TAPPaaS: WARNING - no answer URL in $_tap_mode; disk choice cannot be delivered"
            fi
        } < "$_tap_con" > "$_tap_con" 2>&1
        fi
    fi"""

BOOT_IPXE_TEMPLATE = """#!ipxe
# TAPPaaS node provisioning (design N3) — Proxmox VE automated installer.
# The asset-server IP is BAKED IN (not ${{next-server}}): in the iPXE DHCP
# round the tagged chainload entry carries no siaddr, so ${{next-server}}
# resolves to the FIREWALL and the kernel fetch times out (found on the
# stage-1 Atom boot). node-provisioner enable refreshes this file with the
# detected cicd mgmt IP.
# Kernel args: proxmox-start-auto-installer runs the installer unattended
# (answer fetched over HTTP per the URL prepared INTO the ISO); no proxdebug.
echo TAPPaaS node provisioner: booting Proxmox VE automated installer
kernel http://{server}:{port}/linux26 ro ramdisk_size=16777216 rw splash=silent proxmox-start-auto-installer{askflag}
initrd http://{server}:{port}/initrd
boot
"""

# Kernel cmdline marker consumed by the injected /init block below: ask the
# operator for the boot disk on the NODE's console. Set by enable when a
# pending registration was made without --boot-disk (boot_disk == "ask").
ASK_DISK_FLAG = " tappaas.askdisk=1"


def _decompress_cmd(initrd_path: Path) -> list[str] | None:
    """Pick a decompressor for the initrd by magic bytes (None = plain cpio)."""
    magic = initrd_path.open("rb").read(6)
    if magic[:4] == b"\x28\xb5\x2f\xfd":
        return ["zstd", "-dc", str(initrd_path)]
    if magic[:2] == b"\x1f\x8b":
        return ["gzip", "-dc", str(initrd_path)]
    if magic == b"070701":
        return None
    raise RuntimeError(
        f"unrecognised initrd compression (magic {magic.hex()}) — "
        "PVE layout drift? (V-2)")


def _patched_init(initrd_path: Path, dest: Path) -> Path | None:
    """Extract /init from the pristine initrd and patch the dhclient timeout.

    Returns the path of the patched ``init`` staged under *dest* (to be
    appended in the override cpio — the kernel lets a later initramfs
    segment replace files from an earlier one), or None if the expected
    anchor is missing (layout drift: boot proceeds with stock behaviour).
    """
    decomp = _decompress_cmd(initrd_path)
    if decomp:
        feed = subprocess.Popen(decomp, stdout=subprocess.PIPE)
        stdin = feed.stdout
    else:
        feed = None
        stdin = initrd_path.open("rb")
    extract = subprocess.run(
        ["cpio", "-i", "--quiet", "--to-stdout", "init"],
        stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    stdin.close()
    if feed:
        feed.wait()
    init_text = extract.stdout.decode("utf-8", errors="replace")
    if extract.returncode != 0 or not init_text.startswith("#!"):
        warn("could not extract /init from the initrd — skipping the "
             "dhclient-timeout patch (V-2 layout drift?)")
        return None
    if INIT_ANCHOR not in init_text:
        warn("initrd /init has no '%s' anchor — skipping the "
             "dhclient-timeout patch (V-2 layout drift?)" % INIT_ANCHOR)
        return None
    out = dest / "init"
    out.write_text(init_text.replace(INIT_ANCHOR, INIT_PATCH, 1))
    out.chmod(0o755)
    info("staged patched /init (dhclient timeout 10s -> 60s in the "
         "installer overlay)")
    return out


def write_boot_script(directory: Path, server: str, port: int,
                      ask_disk: bool = False) -> Path:
    """(Re)write boot.ipxe with the CONCRETE asset-server address."""
    boot_script = Path(directory) / "boot.ipxe"
    boot_script.write_text(BOOT_IPXE_TEMPLATE.format(
        server=server, port=port,
        askflag=ASK_DISK_FLAG if ask_disk else ""))
    return boot_script


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
    # initramfs picks the ISO out of its own filesystem — its init checks
    # /proxmox.iso first).
    # Pad the base initrd to a 4-BYTE BOUNDARY first: the kernel's initramfs
    # parser requires segment alignment and SILENTLY ignores a trailing cpio
    # that starts misaligned. PVE 9.2's initrd.img is 55878409 bytes (≡1 mod
    # 4) — without padding /proxmox.iso never appeared and the installer
    # died with "no device with valid ISO found" (stage-1 Atom boot). Zero
    # bytes between segments are explicitly allowed by the kernel format.
    patched_init = _patched_init(initrd_out, dest)
    pad = (-initrd_out.stat().st_size) % 4
    if pad:
        with open(initrd_out, "ab") as f:
            f.write(b"\0" * pad)
        info(f"padded initrd by {pad} byte(s) to a 4-byte segment boundary")
    cpio_members = (["init"] if patched_init else []) + [ISO_ASSET_NAME]
    info("appending %s to initrd (newc cpio)..." % " + ".join(cpio_members))
    with open(initrd_out, "ab") as f:
        subprocess.run(
            ["cpio", "-L", "-H", "newc", "-o"],
            input=("\n".join(cpio_members) + "\n").encode(),
            stdout=f,
            stderr=subprocess.PIPE,
            cwd=str(dest),
            check=True,
        )

    return _finish(dest, port)


def _finish(dest: Path, port: int) -> Path:
    # 4. iPXE boot script.
    boot_script = dest / "boot.ipxe"
    from .util import detect_mgmt_ip
    write_boot_script(dest, detect_mgmt_ip(), port)
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
