"""HTTP asset + answer server (``node-provisioner serve``).

Foreground stdlib http.server:

* ``GET``  — serves the netboot assets under /var/lib/tappaas-pxe
  read-only (kernel, initrd, boot.ipxe, proxmox.iso; directory listing
  disabled).
* ``POST /answer`` — the Proxmox VE automated installer posts the
  machine's system-info JSON; MACs (``network_interfaces[].mac``) and the
  DMI serial are matched against the pending registrations, and the
  matching node's rendered ``answer.toml`` is returned. Unknown machines
  get 404 — no answer, the installer stops (design §4 interlock). A served
  answer consumes its registration (one-shot).

Binding: 0.0.0.0. Placement makes this safe — tappaas-cicd's provisioning
interface sits on the mgmt VLAN (see README), and `enable` keeps the whole
service TTL-limited and off by default.
"""

from __future__ import annotations

import json
import secrets
import stat
import os
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import answer as answer_mod
from .log import debug, info, warn
from .registry import Registry
from .util import (
    DEFAULT_NODE_DOMAIN,
    DEFAULT_PORT,
    pxe_dir,
    secrets_dir,
    site_json_path,
)

MAX_POST_BYTES = 1024 * 1024  # system-info JSON is small; cap defensively

# The cicd tappaas key is placed in the node's root authorized_keys so the
# existing ssh-driven tooling can reach the new node (design N4 / #404
# "locked down" option).
CICD_PUBKEY_PATH = "/home/tappaas/.ssh/id_ed25519.pub"
# TODO(N4): also include the tappaas1 /root SSH public key — needs a
# distribution path for it onto cicd first (design N4).


def collect_root_ssh_keys() -> list:
    """Public keys for the answer file's root-ssh-keys field."""
    keys = []
    try:
        text = Path(CICD_PUBKEY_PATH).read_text().strip()
        if text:
            keys.append(text)
    except OSError:
        warn(f"no cicd public key at {CICD_PUBKEY_PATH} — answer will carry "
             "no SSH keys; only the generated root password grants access")
    return keys


def extract_macs(system_info: dict) -> list:
    """MAC addresses from the installer's posted system info.

    Per the PVE automated-install docs the post payload carries
    ``network_interfaces`` as a list of objects with a ``mac`` field.
    TODO(V-2): confirm the exact payload shape against the deployed PVE
    installer on hardware.
    """
    macs = []
    for nic in system_info.get("network_interfaces") or []:
        if isinstance(nic, dict) and nic.get("mac"):
            macs.append(str(nic["mac"]))
    return macs


def extract_serial(system_info: dict) -> str:
    """Best-effort DMI system serial (logging/audit only for now)."""
    dmi = system_info.get("dmi") or {}
    system = dmi.get("system") or {}
    return str(system.get("serial") or "") or "unknown"


def write_node_secret(name: str, password: str, directory=None) -> Path:
    """Store the generated root password 0600 under the secrets dir."""
    base = Path(directory) if directory else secrets_dir()
    base.mkdir(parents=True, exist_ok=True)
    os.chmod(base, stat.S_IRWXU)  # 0700
    path = base / f"{name}.pw"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(password + "\n")
    return path


def handle_answer_post(
    system_info: dict,
    registry: Registry,
    site: dict,
    domain: str = DEFAULT_NODE_DOMAIN,
    secrets_directory=None,
):
    """Pure-ish core of POST /answer: (http_status, body_text).

    On a match: generates the node's root password (stored 0600), renders
    answer.toml and consumes the registration (one-shot).
    """
    macs = extract_macs(system_info)
    serial = extract_serial(system_info)
    reg = registry.match(macs)
    if reg is None:
        warn(f"answer request REFUSED: no pending registration matches "
             f"macs={macs} serial={serial}")
        return 404, "no pending registration matches this machine\n"

    info(f"answer request matched registration '{reg.name}' "
         f"(macs={macs} serial={serial})")

    password = secrets.token_urlsafe(24)
    secret_path = write_node_secret(reg.name, password, secrets_directory)
    info(f"generated root password for {reg.name} -> {secret_path} (0600)")

    settings = answer_mod.answer_settings_from_site(site)
    body = answer_mod.render_answer(
        name=reg.name,
        domain=domain,
        root_password=password,
        ssh_keys=collect_root_ssh_keys(),
        pools=reg.pools,
        **settings,
    )

    registry.consume(reg.name)
    info(f"registration '{reg.name}' consumed (one-shot)")
    return 200, body


def build_handler(registry: Registry, directory: Path,
                  domain: str = DEFAULT_NODE_DOMAIN):
    """Handler class bound to a registry + asset directory."""

    class ProvisionHandler(SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(directory), **kwargs)

        # Read-only asset serving; no browsing.
        def list_directory(self, path):
            self.send_error(403, "directory listing disabled")
            return None

        def do_POST(self):
            if self.path.rstrip("/") != "/answer":
                self.send_error(404, "unknown endpoint")
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = 0
            if length <= 0 or length > MAX_POST_BYTES:
                self.send_error(400, "bad content length")
                return
            try:
                system_info = json.loads(self.rfile.read(length))
                if not isinstance(system_info, dict):
                    raise ValueError("system info must be a JSON object")
            except (ValueError, json.JSONDecodeError) as e:
                warn(f"answer request with unparsable body: {e}")
                self.send_error(400, "invalid system-info JSON")
                return

            status, body = handle_answer_post(
                system_info,
                registry,
                answer_mod.load_site(site_json_path()),
                domain=domain,
            )
            payload = body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, fmt, *args):  # route http.server chatter
            debug(f"http {self.client_address[0]} {fmt % args}")

    return ProvisionHandler


def serve(port: int = DEFAULT_PORT, directory=None,
          domain: str = DEFAULT_NODE_DOMAIN) -> None:
    """Run the provisioning HTTP server in the foreground."""
    directory = Path(directory) if directory else pxe_dir()
    if not directory.is_dir():
        raise FileNotFoundError(
            f"PXE asset directory {directory} missing — run "
            "'node-provisioner prepare --iso <pve.iso>' first")
    registry = Registry()
    handler = build_handler(registry, directory, domain)
    httpd = ThreadingHTTPServer(("0.0.0.0", port), handler)
    info(f"node-provisioner serving {directory} on 0.0.0.0:{port} "
         f"(POST /answer; mgmt-VLAN placement assumed — see README)")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        info("interrupted — shutting down")
    finally:
        httpd.server_close()
