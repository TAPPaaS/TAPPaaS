"""Shared helpers: paths, privileged subprocess execution."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from .log import debug

DEFAULT_CONFIG_DIR = "/home/tappaas/config"
DEFAULT_PXE_DIR = "/var/lib/tappaas-pxe"
DEFAULT_SECRETS_DIR = "/home/tappaas/.node-secrets"
DEFAULT_PORT = 8090

# Node FQDNs live on the mgmt control plane (zones.json: the untagged mgmt
# zone; internal DNS domain convention <zone>.internal). site.json carries
# no site-wide domain — domains are per-environment — so the node domain is
# this mgmt-plane constant, overridable via --domain.
DEFAULT_NODE_DOMAIN = "mgmt.internal"


def config_dir() -> Path:
    """The TAPPaaS config directory (site.json lives here)."""
    return Path(os.environ.get("TAPPAAS_CONFIG", DEFAULT_CONFIG_DIR))


def provision_dir() -> Path:
    """Where pending-registration JSON files live."""
    return config_dir() / "provision"


def pxe_dir() -> Path:
    """Where the netboot assets are staged/served from."""
    return Path(os.environ.get("TAPPAAS_PXE_DIR", DEFAULT_PXE_DIR))


def secrets_dir() -> Path:
    """Where generated node root passwords are stored (0600)."""
    return Path(os.environ.get("TAPPAAS_NODE_SECRETS", DEFAULT_SECRETS_DIR))


def site_json_path() -> Path:
    return config_dir() / "site.json"


def run(cmd: list[str], privileged: bool = False, check: bool = True,
        capture: bool = False, input_bytes: bytes | None = None,
        cwd: str | None = None) -> subprocess.CompletedProcess:
    """Run a command, prefixing ``sudo -n`` when privileged and not root.

    Args:
        cmd: Command argv.
        privileged: Needs root (mount, systemd-run, systemctl stop...).
        check: Raise CalledProcessError on non-zero exit.
        capture: Capture stdout/stderr (text mode) instead of inheriting.
        input_bytes: Optional bytes fed to stdin (binary mode).
        cwd: Working directory.
    """
    if privileged and os.geteuid() != 0:
        cmd = ["sudo", "-n"] + cmd
    debug(f"exec: {' '.join(cmd)}")
    kwargs: dict = {"check": check, "cwd": cwd}
    if input_bytes is not None:
        kwargs["input"] = input_bytes
    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
        if input_bytes is None:
            kwargs["text"] = True
    return subprocess.run(cmd, **kwargs)


def default_credential_file() -> str | None:
    """Find OPNsense credentials when none were given explicitly.

    node-provisioner regularly runs as root (sudo enable/disable, the TTL
    auto-disable unit, the systemd-run answer server) where dhcp-manager's
    own default lookup only sees /root — but the credentials live in the
    operator's home (stage-1 finding: every root-context disable silently
    left the DHCP boot entries armed). Probe the operator location too.
    """
    for candidate in (
        Path.home() / ".opnsense-credentials.txt",
        Path("/home/tappaas/.opnsense-credentials.txt"),
    ):
        try:
            if candidate.is_file():
                return str(candidate)
        except OSError:
            continue
    return None


def dhcp_manager_bin() -> str:
    import shutil
    return shutil.which("dhcp-manager") or "/home/tappaas/bin/dhcp-manager"


def derive_node_ip(name: str, mgmt_ip: str) -> str | None:
    """Standard mgmt IP for tappaasN: 10.0.0.(9+N), N in 1..9.

    Mirrors config-network.sh node_mgmt_ip(): the firewall reserves
    .10-.18 (outside the dynamic pool, which starts at .100) for exactly
    these nine names. Returns None for any other name.
    """
    import re
    m = re.fullmatch(r"tappaas([1-9])", name)
    if not m:
        return None
    subnet = mgmt_ip.rsplit(".", 1)[0]
    return f"{subnet}.{9 + int(m.group(1))}"


def detect_mgmt_ip(firewall: str = "firewall.mgmt.internal") -> str:
    """The cicd's own mgmt-plane IPv4 (the PXE asset-server address).

    Route-based: the source address of a UDP socket 'connected' to the
    firewall (no packet is sent).
    """
    import socket
    for target in (firewall, "10.0.0.1"):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect((target, 53))
                return s.getsockname()[0]
        except OSError:
            continue
    raise RuntimeError(
        "cannot auto-detect the cicd mgmt IP — pass --next-server")
