"""Pending-node registration store — the provisioning allowlist (design N3).

A registration is the operator's declared intent that a machine named
``<name>`` may PXE-install itself. It lives as
``${TAPPAAS_CONFIG:-/home/tappaas/config}/provision/<name>.json``:

    {
      "name":   "tappaas3",
      "macs":   ["aa:bb:cc:dd:ee:ff"],          # optional pin
      "pools":  [{"name": "tanka1", "layout": "single",
                  "disks": ["nvme0n1"]}],
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

# Node-name pattern per schemas/site-fields.json hardware.nodes[].name
NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
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
    pools: list = field(default_factory=list)
    created: str = ""
    path: Path | None = None

    def to_json(self) -> dict:
        return {
            "name": self.name,
            "macs": self.macs,
            "pools": self.pools,
            "created": self.created,
        }


class Registry:
    """CRUD + matching over the pending-registration directory."""

    def __init__(self, directory=None):
        self.directory = Path(directory) if directory else provision_dir()

    def _path(self, name: str) -> Path:
        return self.directory / f"{name}.json"

    def register(self, name: str, macs=None, pool_specs=None) -> Registration:
        """Create (or replace) a pending registration.

        Args:
            name: Node name (tappaasN convention; validated).
            macs: Optional list of MAC strings (normalized).
            pool_specs: Optional list of 'name=layout:disks' strings.
        """
        if not NAME_RE.match(name):
            raise ValueError(f"invalid node name: {name!r}")
        reg = Registration(
            name=name,
            macs=[normalize_mac(m) for m in (macs or [])],
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

        MAC match first; else, when EXACTLY ONE pending registration exists,
        it matches (single-pending fallback — warned about when that
        registration pinned different MACs); else None.
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
                    f"single-pending fallback: matching '{reg.name}' although "
                    f"its pinned MACs {reg.macs} differ from the posted "
                    f"{sorted(posted) or '(none)'}"
                )
            else:
                debug(f"single-pending fallback -> {reg.name}")
            return reg
        return None

    def consume(self, name: str) -> bool:
        """One-shot: rename <name>.json -> <name>.json.consumed."""
        path = self._path(name)
        if not path.exists():
            return False
        os.replace(path, path.with_name(path.name + ".consumed"))
        return True
