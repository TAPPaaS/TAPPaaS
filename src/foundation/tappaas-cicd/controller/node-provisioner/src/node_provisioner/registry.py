"""Pending-node registration store — the provisioning allowlist (design N3).

A registration is the operator's declared intent that a machine named
``<name>`` may PXE-install itself. It lives as
``${TAPPAAS_CONFIG:-/home/tappaas/config}/provision/<name>.json``:

    {
      "name":   "tappaas3",
      "macs":   ["aa:bb:cc:dd:ee:ff"],          # optional pin
      "boot_disk": "sda",                       # installer target
      "boot_filesystem": "zfs",                 # zfs (default, ADR-037) or ext4
      "boot_mirror": "nvme1n1",                 # optional: rpool mirrored onto a second disk
      "pools":  [{"name": "tanka1", "layout": "single",
                  "disks": ["nvme0n1"]}],       # post-join data pools
      "created": "2026-07-06T12:00:00+00:00"
    }

Matching (answer server): a posted MAC that equals a registered MAC wins;
otherwise, when EXACTLY ONE pending registration exists it matches (with a
warning if that registration pinned different MACs); otherwise no match —
unknown machines get no answer (the safety interlock, design §4).

One-shot: a successfully answered registration is renamed
``<name>.json.consumed`` so it can never answer twice.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from .log import debug, warn
from .util import provision_dir

# Node-name pattern: a cluster node's name (its pvehost instance, config/<name>.json)
NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")

# A boot disk is named by its SERIAL (preferred) or, legacy, a kernel name. The
# installer WIPES it. Kernel names are not stable across boots: a node
# reinstalled on 2026-10-03 had its system and data disk swap nvme0n1/nvme1n1
# between the installer and the running system (#729) — with the other order,
# a kernel name would have aimed the installer at the 2 TB data disk.
DISK_RE = re.compile(r"^[A-Za-z0-9._:-]+$")
# A boot-disk field (ADR-037 D4): auto, ask, none (the mirror), a kernel name,
# a size (2TB), or text in a disk's model or serial — matched by the installer.
BOOT_FIELD_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._:-]{0,63}$")
KERNEL_DISK_RE = re.compile(r"^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme\d+n\d+|mmcblk\d+)$")


def is_kernel_disk_name(disk: str) -> bool:
    """True for sda / nvme0n1 / vdb — names the kernel hands out per boot."""
    return bool(KERNEL_DISK_RE.match(disk or ""))
MAC_RE = re.compile(r"^([0-9a-f]{2}:){5}[0-9a-f]{2}$")

# Pool topologies per cluster/config-storage.sh --pool syntax
POOL_LAYOUTS = ("single", "stripe", "mirror", "raidz", "raidz2")


def normalize_mac(mac) -> str:
    """Normalize a MAC to lowercase colon-separated form; raise on garbage."""
    if not isinstance(mac, str):
        raise ValueError(f"invalid MAC address: {mac!r}")
    m = mac.strip().lower().replace("-", ":")
    if not MAC_RE.match(m):
        raise ValueError(f"invalid MAC address: {mac!r}")
    return m


def parse_pool_spec(spec: str) -> dict:
    """Parse a ``name=layout:disk[,disk...]`` pool spec (cluster --pool syntax).

    e.g. 'tanka1=single:nvme0n1' or 'tankb1=mirror:sdb,sdc'.
    """
    if "=" not in spec:
        raise ValueError(f"pool spec must be name=layout:disks, got {spec!r}")
    name, rest = spec.split("=", 1)
    if ":" not in rest:
        raise ValueError(f"pool spec must be name=layout:disks, got {spec!r}")
    layout, disks_str = rest.split(":", 1)
    disks = [d.strip() for d in disks_str.split(",") if d.strip()]
    if not NAME_RE.match(name):
        raise ValueError(f"invalid pool name: {name!r}")
    if layout not in POOL_LAYOUTS:
        raise ValueError(
            f"invalid pool layout {layout!r} (one of {', '.join(POOL_LAYOUTS)})")
    if not disks:
        raise ValueError(f"pool spec has no disks: {spec!r}")
    if layout == "single" and len(disks) != 1:
        raise ValueError(f"layout 'single' takes exactly one disk: {spec!r}")
    if layout != "single" and len(disks) < 2:
        raise ValueError(f"layout {layout!r} needs at least two disks: {spec!r}")
    return {"name": name, "layout": layout, "disks": disks}


@dataclass
class Registration:
    """A pending node registration."""

    name: str
    macs: list = field(default_factory=list)
    boot_disk: str = "sda"
    boot_filesystem: str = "zfs"
    boot_mirror: str = ""
    pools: list = field(default_factory=list)
    created: str = ""
    path: Path | None = None

    def to_json(self) -> dict:
        return {
            "name": self.name,
            "macs": self.macs,
            "boot_disk": self.boot_disk,
            "boot_filesystem": self.boot_filesystem,
            "boot_mirror": self.boot_mirror,
            "pools": self.pools,
            "created": self.created,
        }


class Registry:
    """CRUD + matching over the pending-registration directory."""

    def __init__(self, directory=None):
        self.directory = Path(directory) if directory else provision_dir()

    def _path(self, name: str) -> Path:
        return self.directory / f"{name}.json"

    def register(self, name: str, macs=None, pool_specs=None,
                 boot_disk: str = "sda", boot_filesystem: str = "zfs",
                 boot_mirror: str = "") -> Registration:
        """Create (or replace) a pending registration.

        Args:
            name: Node name (tappaasN convention; validated).
            macs: Optional list of MAC strings (normalized).
            pool_specs: Optional list of 'name=layout:disks' strings —
                POST-JOIN data pools; the installer never touches them.
            boot_disk: The installer's boot disk, as a field the installer
                resolves against the machine's disks (ADR-037 D4): "auto" (the
                smallest SSD/NVMe; an identical smallest pair is mirrored),
                "ask" (the console), a size, a model or serial, or a kernel name.
            boot_filesystem: zfs (the default, ADR-037 D1: the boot pool
                carries the guests when the node has no data disk) or ext4.
            boot_mirror: a second disk to mirror the boot pool onto (zfs
                raid1), a field like boot_disk; "none" keeps a matched pair
                unmirrored; "" mirrors when the boot field finds two disks alike.
        """
        if not NAME_RE.match(name):
            raise ValueError(f"invalid node name: {name!r}")
        boot_disk = (boot_disk or "auto").strip()
        if not BOOT_FIELD_RE.match(boot_disk):
            raise ValueError(
                f"boot disk must be auto, ask, a size (2TB), a model or serial, "
                f"or a kernel name — got {boot_disk!r}")
        if boot_filesystem not in ("zfs", "ext4"):
            raise ValueError(f"boot filesystem must be zfs or ext4, got {boot_filesystem!r}")
        boot_mirror = (boot_mirror or "").strip()
        if boot_mirror and boot_mirror != "none":
            if not BOOT_FIELD_RE.match(boot_mirror) or boot_mirror in ("auto", "ask"):
                raise ValueError(f"boot mirror must be none, a size, a model or serial, or a kernel name — got {boot_mirror!r}")
            if boot_filesystem != "zfs":
                raise ValueError("a mirrored boot disk needs the zfs boot filesystem")
            if boot_disk in ("auto", "ask"):
                raise ValueError(f"a named boot mirror needs a named boot disk, not {boot_disk!r}")
            if boot_mirror == boot_disk:
                raise ValueError("the boot mirror is the boot disk itself")
        reg = Registration(
            name=name,
            macs=[normalize_mac(m) for m in (macs or [])],
            boot_disk=boot_disk,
            boot_filesystem=boot_filesystem,
            boot_mirror=boot_mirror,
            pools=[parse_pool_spec(s) for s in (pool_specs or [])],
            created=datetime.now(timezone.utc).isoformat(timespec="seconds"),
        )
        self.directory.mkdir(parents=True, exist_ok=True)
        path = self._path(name)
        if path.exists():
            warn(f"registration for '{name}' already exists — replacing it")
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(reg.to_json(), indent=2) + "\n")
        os.replace(tmp, path)
        reg.path = path
        return reg

    def unregister(self, name: str) -> bool:
        """Remove a pending registration. Returns False when absent."""
        path = self._path(name)
        if not path.exists():
            return False
        path.unlink()
        return True

    def load(self, name: str) -> Registration | None:
        path = self._path(name)
        if not path.exists():
            return None
        return self._read(path)

    def _read(self, path: Path) -> Registration:
        data = json.loads(path.read_text())
        return Registration(
            name=data.get("name") or path.stem,
            macs=[normalize_mac(m) for m in data.get("macs", [])],
            boot_disk=data.get("boot_disk", "sda"),
            boot_filesystem=data.get("boot_filesystem", "zfs"),
            boot_mirror=data.get("boot_mirror", ""),
            pools=list(data.get("pools", [])),
            created=data.get("created", ""),
            path=path,
        )

    def list_pending(self) -> list:
        """All pending (non-consumed) registrations, name-sorted."""
        if not self.directory.is_dir():
            return []
        regs = []
        for path in sorted(self.directory.glob("*.json")):
            try:
                regs.append(self._read(path))
            except (ValueError, json.JSONDecodeError) as e:
                warn(f"skipping unreadable registration {path.name}: {e}")
        return regs

    def match(self, macs) -> Registration | None:
        """Match posted machine MACs against pending registrations.

        MAC match first; else, when EXACTLY ONE pending registration exists
        and it pins no MACs, it matches (single-pending fallback); else None.
        A registration that pins MACs answers only a machine posting one of
        them — another host's request (or one with no MACs) must not consume
        it and bake its own address.
        """
        posted = set()
        for m in macs or []:
            try:
                posted.add(normalize_mac(m))
            except ValueError:
                debug(f"ignoring unparsable posted MAC {m!r}")

        pending = self.list_pending()
        for reg in pending:
            if posted & set(reg.macs):
                debug(f"MAC match -> {reg.name}")
                return reg

        if len(pending) == 1:
            reg = pending[0]
            if reg.macs:
                warn(
                    f"not matching '{reg.name}': it pins MACs {reg.macs}, the "
                    f"request posted {sorted(posted) or '(none)'}"
                )
                return None
            debug(f"single-pending fallback -> {reg.name}")
            return reg
        return None

    def consume(self, name: str, install_ip: str = "") -> bool:
        """One-shot: rename <name>.json -> <name>.json.consumed.

        install_ip: the address the installer posted from. The PVE
        installer bakes its DHCP lease as a STATIC address (stage-1
        finding), so this is where the installed node boots — recorded
        for the operator / the node-add step.
        """
        path = self._path(name)
        if not path.exists():
            return False
        if install_ip:
            try:
                data = json.loads(path.read_text())
                data["install_ip"] = install_ip
                path.write_text(json.dumps(data, indent=2) + "\n")
            except (OSError, json.JSONDecodeError):
                pass
        os.replace(path, path.with_name(path.name + ".consumed"))
        return True
