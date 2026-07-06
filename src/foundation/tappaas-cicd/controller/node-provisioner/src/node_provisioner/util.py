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
