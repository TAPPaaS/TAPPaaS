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
import re
import secrets
import stat
import os
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from . import answer as answer_mod
from .log import debug, info, warn
from .registry import Registry
from .util import (
    DEFAULT_NODE_DOMAIN,
    DEFAULT_PORT,
    default_credential_file,
    derive_node_ip,
    detect_mgmt_ip,
    dhcp_manager_bin,
    pxe_dir,
    run,
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


def _reserve_standard_ip(name: str, macs: list, domain: str) -> None:
    """Pin the node's MACs to its standard mgmt IP (tappaasN -> .1x).

    Best-effort at answer-serve time via ``dhcp-manager host set``.
    TIMING (stage-1 finding): the installer already took its lease BEFORE
    posting for the answer and bakes THAT address statically — so for the
    current install this reservation is informational; it pays off for
    every future DHCP round (reinstalls, and MAC-pinned registrations get
    it at ENABLE time, before the first lease). All posted MACs go on one
    reservation (only one port is active at a time). Failure only costs
    that convenience, never the install.
    """
    try:
        ip = derive_node_ip(name, detect_mgmt_ip())
    except RuntimeError as e:
        warn(f"skipping IP reservation for {name}: {e}")
        return
    if not ip:
        warn(f"'{name}' has no standard mgmt IP (tappaas1-9 only) — "
             "skipping the DHCP reservation")
        return
    if not macs:
        warn(f"no MACs posted for {name} — skipping the DHCP reservation")
        return
    cmd = [dhcp_manager_bin(), "--no-ssl-verify"]
    cred = default_credential_file()
    if cred:
        cmd += ["--credential-file", cred]
    cmd += ["host", "set", name, "--ip", ip, "--domain", domain]
    for mac in macs:
        cmd += ["--mac", mac]
    result = run(cmd, check=False, capture=True)
    if result.returncode == 0:
        info(f"reserved {ip} for {name} ({len(macs)} MAC(s))")
    else:
        warn(f"could not reserve {ip} for {name}: "
             f"{(result.stderr or result.stdout or '').strip()}")


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
    request_ip: str = "",
    boot_disk_override: str = "",
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

    # Boot-disk resolution: a console choice (?bootdisk=, from the injected
    # /init prompt when the registration is ask-at-boot) always wins — the
    # operator standing at the machine knows best. An ask-registration
    # without a console choice is refused WITHOUT consuming (the machine
    # can re-post after a re-enable/reboot).
    boot_disk = reg.boot_disk
    if boot_disk_override:
        if not re.fullmatch(r"[A-Za-z0-9]+", boot_disk_override):
            warn(f"REFUSED: bad bootdisk parameter {boot_disk_override!r}")
            return 400, "invalid bootdisk parameter\n"
        boot_disk = boot_disk_override
        info(f"boot disk chosen on the node console: {boot_disk}")
    elif boot_disk == "ask":
        warn(f"REFUSED (not consumed): registration '{reg.name}' expects a "
             "console-chosen boot disk but none arrived — was the trap "
             "enabled while this registration was pending? (the askdisk "
             "kernel flag is set at enable time)")
        return 409, ("registration expects a console-chosen boot disk "
                     "(re-enable provisioning and reboot the node)\n")

    _reserve_standard_ip(reg.name, macs, domain)

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
        boot_disk=boot_disk,
        **settings,
    )

    registry.consume(reg.name, install_ip=request_ip)
    info(f"registration '{reg.name}' consumed (one-shot)")
    if request_ip:
        # The PVE installer BAKES its DHCP lease as a STATIC address
        # (stage-1 finding) — so the installed node comes up exactly here
        # (unless a pre-boot reservation already put it on its standard
        # IP). The join step normalizes to the standard IP either way.
        info(f"node '{reg.name}' will boot at {request_ip} "
             "(installer bakes its lease statically); the cluster join "
             "moves it to its standard mgmt IP")
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
            parts = urlsplit(self.path)
            if parts.path.rstrip("/") != "/answer":
                self.send_error(404, "unknown endpoint")
                return
            bootdisk_param = parse_qs(parts.query).get("bootdisk", [""])[0]
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
                request_ip=self.client_address[0],
                boot_disk_override=bootdisk_param,
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
