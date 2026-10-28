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

import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from .log import info, warn
from .util import DEFAULT_PORT, pxe_dir, run

KERNEL_IN_ISO = "boot/linux26"
INITRD_IN_ISO = "boot/initrd.img"
ISO_ASSET_NAME = "proxmox.iso"
USB_ISO_NAME = "tappaas-usb.iso"  # the installer stick: the ISO with the patched /init
STAMP_NAME = "assets.json"  # which /init patch the staged assets carry, and their ISO
DEFAULT_SOURCE_ISO = "/home/tappaas/pve-tappaas-netboot.iso"  # prepare-netboot.sh's copy

# Injected into the installer's /init right before switch_root (the installer
# root is an overlayfs with a tmpfs upper, so the sed lands in the writable
# upper layer). The stock installer gives dhclient only 10 seconds
# (etc/dhcp/dhclient.conf: "timeout 10;") and proxmox-fetch-answer fires
# exactly once — on hardware where the NIC re-trains its link after kernel
# takeover (plus any switch STP delay) that window is lost and the answer
# fetch dies with "Network unreachable" (stage-1 Atom, X553 NICs). 60s covers
# link training and a 30s STP listening/learning hold.
INIT_ANCHOR = "cp /etc/hostid /mnt/.installer-mp/etc/"
# Boot-disk matching for the injected /init (ADR-037 D4), kept apart so the
# unit tests run it against a fake /sys (TAPPAAS_SYS). Busybox sh, cat and grep.
# A field is: blank or "auto" (the smallest SSD/NVMe disk not on USB; the two
# smallest when they are the same model and size, mirrored — unless the mirror
# field is "none"), "ask" (the console), a kernel name, a size (2TB, 1.92T,
# 500GB: within 10 %), or text found in a disk's model or serial ('.' stands
# for a space). _tap_resolve <boot> <mirror> sets _tap_disk, _tap_mirror and
# _tap_why; non-zero when the console has to ask.
RESOLVE_SH = r"""
_tap_sys="${TAPPAAS_SYS:-/sys}"
_tap_disks() {
    for _d in "$_tap_sys"/block/*; do
        _b="${_d##*/}"
        case "$_b" in loop*|ram*|sr*|dm-*|zram*|zd*|md*|nbd*|*boot[0-9]*|*rpmb) continue ;; esac
        [ -e "$_d/device" ] || continue
        [ "$(cat "$_d/size" 2>/dev/null || echo 0)" -ge 31250000 ] || continue
        case "$(cd "$_d" 2>/dev/null && pwd -P)" in */usb*) continue ;; esac
        echo "$_b"
    done
}
_tap_sectors() { cat "$_tap_sys/block/$1/size" 2>/dev/null || echo 0; }
_tap_model() { cat "$_tap_sys/block/$1/device/model" 2>/dev/null; }
_tap_ssd() { [ "$(cat "$_tap_sys/block/$1/queue/rotational" 2>/dev/null)" = 0 ]; }
_tap_hay() {
    echo "$(_tap_model "$1") $(cat "$_tap_sys/block/$1/device/serial" 2>/dev/null) $(cat "$_tap_sys/block/$1/device/wwid" 2>/dev/null)"
}
_tap_size_mb() {
    _v="$1"
    case "$_v" in
        *[Tt][Bb]) _v="${_v%??}"; _m=1000000 ;;
        *[Tt]) _v="${_v%?}"; _m=1000000 ;;
        *[Gg][Bb]) _v="${_v%??}"; _m=1000 ;;
        *[Gg]) _v="${_v%?}"; _m=1000 ;;
        *) return 1 ;;
    esac
    case "$_v" in ''|.*|*.|*[!0-9.]*|*.*.*) return 1 ;; esac
    _i="${_v%%.*}"; _f=""
    case "$_v" in *.*) _f="${_v#*.}" ;; esac
    _f="${_f}000"; _f="${_f%"${_f#???}"}"
    while case "$_f" in 0?*) true ;; *) false ;; esac; do _f="${_f#0}"; done
    while case "$_i" in 0?*) true ;; *) false ;; esac; do _i="${_i#0}"; done
    echo $(( _i * _m + _f * _m / 1000 ))
}
_tap_match() {
    if [ -e "$_tap_sys/block/$1/device" ]; then echo "$1"; return 0; fi
    _want="$(_tap_size_mb "$1")" || _want=""
    for _b in $(_tap_disks); do
        if [ -n "$_want" ]; then
            _mb=$(( $(_tap_sectors "$_b") * 512 / 1000000 ))
            _dd=$(( _mb - _want )); [ "$_dd" -lt 0 ] && _dd=$(( 0 - _dd ))
            [ "$_dd" -le $(( _want / 10 )) ] && echo "$_b"
        elif _tap_hay "$_b" | grep -qi -- "$1"; then
            echo "$_b"
        fi
    done
    return 0
}
_tap_alike() {
    [ "$(_tap_sectors "$1")" = "$(_tap_sectors "$2")" ] && [ "$(_tap_model "$1")" = "$(_tap_model "$2")" ]
}
_tap_resolve() {
    _tap_disk=""; _tap_mirror=""; _tap_why=""
    case "$1" in
        ask) _tap_why="asked for on the console"; return 1 ;;
        auto|"")
            _s1=""; _s2=""
            for _c in $(_tap_disks); do
                _tap_ssd "$_c" || continue
                _z=$(_tap_sectors "$_c")
                if [ -z "$_s1" ] || [ "$_z" -lt "$(_tap_sectors "$_s1")" ]; then _s2="$_s1"; _s1="$_c"
                elif [ -z "$_s2" ] || [ "$_z" -lt "$(_tap_sectors "$_s2")" ]; then _s2="$_c"; fi
            done
            if [ -z "$_s1" ]; then _tap_why="no SSD or NVMe disk to choose automatically"; return 1; fi
            _tap_disk="$_s1"
            if [ -n "$_s2" ] && [ "$2" != none ] && _tap_alike "$_s1" "$_s2"; then
                _tap_mirror="$_s2"; _tap_why="automatic: the smallest SSD/NVMe disks, a pair alike"
            else
                _tap_why="automatic: the smallest SSD/NVMe disk"
            fi
            return 0 ;;
    esac
    _m1="$(_tap_match "$1")"; _n1=0; _a=""; _o=""
    for _x in $_m1; do _n1=$((_n1 + 1)); if [ -z "$_a" ]; then _a="$_x"; else _o="$_x"; fi; done
    if [ -z "$2" ] || [ "$2" = none ]; then
        if [ "$_n1" = 1 ]; then _tap_disk="$_a"; _tap_why="'$1'"; return 0; fi
        if [ "$_n1" = 2 ] && [ -z "$2" ] && _tap_alike "$_a" "$_o"; then
            _tap_disk="$_a"; _tap_mirror="$_o"; _tap_why="'$1': two disks alike, mirrored"; return 0
        fi
        _tap_why="'$1' matches $_n1 disks"; return 1
    fi
    _m2="$(_tap_match "$2")"; _n2=0; _p=""
    for _x in $_m2; do _n2=$((_n2 + 1)); _p="$_x"; done
    if [ "$_n1" = 1 ] && [ "$_n2" = 1 ] && [ "$_a" != "$_p" ]; then
        _tap_disk="$_a"; _tap_mirror="$_p"; _tap_why="'$1' + '$2'"; return 0
    fi
    _tap_why="'$1' matches $_n1 disk(s), '$2' $_n2"; return 1
}
"""

# The disk list of a USB boot, on top of RESOLVE_SH (the install media of a
# first node carry RESOLVE_SH alone).
DISK_LIST_SH = r"""
# A value safe in the answer URL: what is not a letter, digit, '.', '_' or '-'
# becomes '.', which the matcher's grep reads as any character.
_tap_safe() {
    _s="$1"; _o=""
    while [ -n "$_s" ]; do
        _c="${_s%"${_s#?}"}"; _s="${_s#?}"
        case "$_c" in [A-Za-z0-9._-]) _o="$_o$_c" ;; *) _o="$_o." ;; esac
    done
    echo "$_o"
}
# The candidate disks for the answer server (a USB boot): name~sectors~
# rotational~model~serial~wwid, comma-separated.
_tap_disk_list() {
    _l=""
    for _b in $(_tap_disks); do
        _e="$_b~$(_tap_sectors "$_b")~$(cat "$_tap_sys/block/$_b/queue/rotational" 2>/dev/null || echo 1)"
        _e="$_e~$(_tap_safe "$(_tap_model "$_b")")~$(_tap_safe "$(cat "$_tap_sys/block/$_b/device/serial" 2>/dev/null)")"
        _e="$_e~$(_tap_safe "$(cat "$_tap_sys/block/$_b/device/wwid" 2>/dev/null)")"
        _l="${_l:+$_l,}$_e"
    done
    echo "$_l"
}
"""

# The boot-disk block of the injected /init: read the registration's two fields
# from the kernel command line, resolve them, ask on the console when they do
# not resolve, and hand the names to the answer server. A USB boot carries no
# fields (its command line is the ISO's): the candidate disks go instead, and
# the answer server matches the registration's fields against them.
BOOT_DISK_SH = r"""
    # TAPPaaS node-provisioner: the boot disk(s) (ADR-037 D4). The registration's
    # two fields come on the kernel command line (tappaas.bootdisk= and
    # tappaas.bootmirror=, chosen per MAC by boot.ipxe) and are matched HERE
    # against this boot's disks — the one moment kernel names are valid. The
    # names go to the answer server as ?bootdisk=&bootmirror= by a rewritten
    # auto-installer-mode.toml bound over the ISO's copy (the ISO is read-only;
    # a file bind on the already-bound /cdrom works). A field that matches no
    # disk, or more than it may, is the one question of the whole install,
    # asked on the console. Without fields (a USB boot) the disks go as
    # ?disks=name~sectors~rotational~model~serial~wwid,... and the answer
    # server runs this same matcher on them.
    _tap_bd=""; _tap_bm=""; _tap_usb=1
    for _tap_w in $(cat /proc/cmdline); do
        case "$_tap_w" in
            tappaas.bootdisk=*) _tap_bd="${_tap_w#*=}"; _tap_usb="" ;;
            tappaas.bootmirror=*) _tap_bm="${_tap_w#*=}" ;;
            tappaas.askdisk=1) _tap_bd=ask; _tap_usb="" ;;
        esac
    done
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
        if [ -n "$_tap_usb" ]; then
            _tap_q="disks=$(_tap_disk_list)"
            echo "TAPPaaS: no boot-disk fields on the command line (a USB boot) — the answer server matches the registration against this machine's disks"
        else
            if _tap_resolve "$_tap_bd" "$_tap_bm"; then
                echo "TAPPaaS: boot disk ${_tap_disk}${_tap_mirror:+, mirrored onto ${_tap_mirror}} (${_tap_why})"
            else
                echo ""
                echo "==== TAPPaaS node provisioning: choose the BOOT disk ===="
                [ "$_tap_bd" = ask ] || echo "(${_tap_why})"
                echo "The chosen disk is WIPED (the PVE system goes on it). Disks found:"
                for _tap_d in /sys/block/*; do
                    _tap_b="${_tap_d##*/}"
                    case "$_tap_b" in loop*|ram*|sr*|dm-*|zram*) continue ;; esac
                    _tap_sz=$(cat "$_tap_d/size" 2>/dev/null || echo 0)
                    echo "  $_tap_b  ($((_tap_sz / 2097152)) GB)  $(cat "$_tap_d/device/model" 2>/dev/null)"
                done
                _tap_disk=""; _tap_mirror=""
                while [ ! -e "/sys/block/$_tap_disk" ] || [ -z "$_tap_disk" ]; do
                    printf "TAPPaaS boot disk> "
                    read -r _tap_disk
                done
            fi
            _tap_q="bootdisk=${_tap_disk}&bootmirror=${_tap_mirror}"
        fi
        _tap_url=""
        while IFS= read -r _tap_l; do
            case "$_tap_l" in url*) _tap_u="${_tap_l#*\"}"; _tap_url="${_tap_u%\"*}" ;; esac
        done < "$_tap_mode"
        if [ -n "$_tap_url" ]; then
            while IFS= read -r _tap_l; do
                case "$_tap_l" in
                    url*) echo "url = \"${_tap_url}?${_tap_q}\"" ;;
                    *) echo "$_tap_l" ;;
                esac
            done < "$_tap_mode" > /tappaas-mode.toml
            mount --bind /tappaas-mode.toml "$_tap_mode"
            if [ -n "$_tap_usb" ]; then
                echo "TAPPaaS: this machine's disks go to the answer server"
            else
                echo "TAPPaaS: boot disk '${_tap_disk}'${_tap_mirror:+ + '${_tap_mirror}'} goes to the answer server"
            fi
        else
            echo "TAPPaaS: WARNING - no answer URL in $_tap_mode; disk choice cannot be delivered"
        fi
    } < "$_tap_con" > "$_tap_con" 2>&1
    fi"""

INIT_PATCH = INIT_ANCHOR + """
    # TAPPaaS node-provisioner: raise the DHCP timeout so the auto-installer
    # answer fetch has a live network (link re-training + STP eat the stock 10s)
    sed -i 's/^timeout 10;/timeout 60;/' /mnt/.installer-mp/etc/dhcp/dhclient.conf || true
""" + RESOLVE_SH + DISK_LIST_SH + BOOT_DISK_SH

BOOT_IPXE_TEMPLATE = """#!ipxe
# TAPPaaS node provisioning (design N3) — Proxmox VE automated installer.
# The asset-server IP is BAKED IN (not ${{next-server}}): in the iPXE DHCP
# round the tagged chainload entry carries no siaddr, so ${{next-server}}
# resolves to the FIREWALL and the kernel fetch times out (found on the
# stage-1 Atom boot). node-provisioner enable refreshes this file with the
# detected cicd mgmt IP.
# Kernel args: proxmox-start-auto-installer runs the installer unattended
# (answer fetched over HTTP per the URL prepared INTO the ISO); no proxdebug.
# The boot-disk fields of the registration whose MAC this is (ADR-037 D4):
# the injected /init resolves them against the machine's disks.
{disklines}echo TAPPaaS node provisioner: booting Proxmox VE automated installer
kernel http://{server}:{port}/linux26 ro ramdisk_size=16777216 rw splash=silent proxmox-start-auto-installer ${{tapdisk}}
initrd http://{server}:{port}/initrd
boot
"""

# One disk of a USB boot's ?disks= list: name~sectors~rotational~model~serial~wwid.
_POSTED_DISK_RE = re.compile(r"[a-z0-9]{1,32}~[0-9]{1,20}~[01]~[A-Za-z0-9._-]{0,64}~[A-Za-z0-9._-]{0,64}~[A-Za-z0-9._-]{0,128}")


def parse_posted_disks(value: str) -> list | None:
    """The ?disks= list of a USB boot as (name, sectors, rotational, model,
    serial, wwid) tuples; None when it is not one."""
    if not value or len(value) > 4096:
        return None
    out = []
    for entry in value.split(","):
        if not _POSTED_DISK_RE.fullmatch(entry):
            return None
        name, sectors, rot, model, serial, wwid = entry.split("~")
        out.append((name, int(sectors), rot, model, serial, wwid))
    return out or None


def resolve_posted_disks(boot: str, mirror: str, disks: list) -> tuple:
    """The installer's matcher (RESOLVE_SH) run on the mothership against a USB
    boot's posted disks, laid out as a /sys: (ok, disk, mirror, why)."""
    with tempfile.TemporaryDirectory(prefix="tappaas-disks.") as tmp:
        root = Path(tmp)
        (root / "block").mkdir()
        for name, sectors, rot, model, serial, wwid in disks:
            dev = root / "devices" / "pci0000:00" / name
            (dev / "device").mkdir(parents=True)
            (dev / "queue").mkdir()
            (dev / "size").write_text(f"{sectors}\n")
            (dev / "queue" / "rotational").write_text(f"{rot}\n")
            (dev / "device" / "model").write_text(model + "\n")
            if serial:
                (dev / "device" / "serial").write_text(serial + "\n")
            if wwid:
                (dev / "device" / "wwid").write_text(wwid + "\n")
            (root / "block" / name).symlink_to(dev)
        script = RESOLVE_SH + '\n_tap_resolve "$1" "$2"; rc=$?\necho "$rc|$_tap_disk|$_tap_mirror|$_tap_why"\n'
        r = subprocess.run(["sh", "-c", script, "resolve", _cmdline_field(boot),
                            _cmdline_field(mirror) if mirror else ""],
                           env={"TAPPAAS_SYS": str(root), "PATH": "/run/current-system/sw/bin:/usr/bin:/bin"},
                           capture_output=True, text=True, timeout=30)
    rc, disk, mir, why = (r.stdout.strip().split("|", 3) + ["", "", "", ""])[:4]
    return rc == "0" and bool(disk), disk, mir, why or r.stderr.strip()


def patch_stamp() -> str:
    """The /init patch the code would stage now (its hash)."""
    return hashlib.sha256(INIT_PATCH.encode()).hexdigest()[:16]


def stale_source(directory=None) -> str | None:
    """The ISO to re-stage from when the staged assets carry another /init patch
    than this code's (or predate the stamp); None when they are current."""
    dest = Path(directory) if directory else pxe_dir()
    try:
        stamp = json.loads((dest / STAMP_NAME).read_text())
    except (OSError, ValueError):
        stamp = {}
    if stamp.get("patch") == patch_stamp():
        return None
    return stamp.get("iso") or DEFAULT_SOURCE_ISO


# A field on the kernel command line: a model's spaces become '.', which the
# /init's grep reads as any character; nothing else a field may hold needs it.
def _cmdline_field(value: str) -> str:
    return (value or "auto").replace(" ", ".")


def boot_disk_lines(pending) -> str:
    """The iPXE lines that set ${tapdisk}: per pending registration, by the
    MAC that netboots; a registration without a MAC (or the only one) is the
    default. ``pending`` are registry Registrations."""
    def args(r) -> str:
        a = f"tappaas.bootdisk={_cmdline_field(r.boot_disk)}"
        return a + (f" tappaas.bootmirror={_cmdline_field(r.boot_mirror)}" if r.boot_mirror else "")
    default = "tappaas.bootdisk=auto"
    no_mac = [r for r in pending if not r.macs]
    if len(pending) == 1 or len(no_mac) == 1:
        default = args(pending[0] if len(pending) == 1 else no_mac[0])
    lines = [f"set tapdisk {default}"]
    for r in pending:
        for m in r.macs:
            lines.append(f"iseq ${{netX/mac}} {m} && set tapdisk {args(r)} ||")
    return "\n".join(lines) + "\n"


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


def render_boot_script(server: str, port: int, pending=()) -> str:
    """boot.ipxe with the CONCRETE asset-server address and the pending
    registrations' boot-disk fields."""
    return BOOT_IPXE_TEMPLATE.format(server=server, port=port,
                                     disklines=boot_disk_lines(list(pending)))


def write_boot_script(directory: Path, server: str, port: int,
                      pending=()) -> Path:
    """(Re)write boot.ipxe with the CONCRETE asset-server address."""
    boot_script = Path(directory) / "boot.ipxe"
    boot_script.write_text(render_boot_script(server, port, pending))
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
    usb_initrd = None
    if patched_init:
        # The stick's initrd: the same /init over the stock one, no ISO inside
        # (the installer finds the stick itself).
        usb_initrd = dest / "usb-initrd"
        shutil.copyfile(initrd_out, usb_initrd)
        with open(usb_initrd, "ab") as f:
            subprocess.run(["cpio", "-L", "-H", "newc", "-o"], input=b"init\n",
                           stdout=f, stderr=subprocess.PIPE, cwd=str(dest), check=True)
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

    _usb_iso(iso_path, usb_initrd, dest)
    (dest / STAMP_NAME).write_text(json.dumps({"patch": patch_stamp(),
                                               "iso": str(iso_path)}) + "\n")
    return _finish(dest, port)


def _usb_iso(iso_path: Path, usb_initrd: Path | None, dest: Path) -> None:
    """The installer stick: a copy of the ISO with its initrd swapped for the
    patched one, written as a new session that keeps the ISO's boot setup — as
    proxmox-auto-install-assistant adds its answer settings (a rebuild with
    -boot_image any replay refuses the ISO's hybrid MBR/GPT layout)."""
    out = dest / USB_ISO_NAME
    out.unlink(missing_ok=True)
    if usb_initrd is None:
        warn(f"no patched /init — no {USB_ISO_NAME}; a stick of the plain ISO cannot match its boot disk")
        return
    if not shutil.which("xorriso"):
        warn(f"xorriso is not installed — no {USB_ISO_NAME}")
        usb_initrd.unlink(missing_ok=True)
        return
    info(f"building the installer stick image {out} ...")
    shutil.copyfile(iso_path, out)
    r = subprocess.run(["xorriso", "-boot_image", "any", "keep", "-dev", str(out),
                        "-map", str(usb_initrd), "/" + INITRD_IN_ISO],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    usb_initrd.unlink(missing_ok=True)
    if r.returncode != 0:
        out.unlink(missing_ok=True)
        warn(f"xorriso could not build {USB_ISO_NAME}: {r.stderr.strip()[-300:]}")
        return
    out.chmod(0o644)


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
