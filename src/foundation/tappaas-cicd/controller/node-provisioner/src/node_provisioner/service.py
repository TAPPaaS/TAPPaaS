"""Transient-unit lifecycle: ``enable`` / ``disable`` / ``status``.

``enable`` (design N3: OFF by default, TTL-limited):
  1. preflight the staged assets (prepare must have run);
  2. stage the iPXE UEFI binary into the TFTP root;
  3. ``systemd-run`` the HTTP answer server as ``tappaas-pxe.service``;
  4. ``systemd-run`` dnsmasq in TFTP-ONLY mode (``--port=0`` disables its
     DNS/DHCP entirely) as ``tappaas-pxe-tftp.service`` — OPNsense stays
     the only DHCP server; if dnsmasq is not in the cicd closure, warn
     with the nix addition needed (TODO);
  5. ``dhcp-manager pxe enable`` — sets next-server/bootfile on the mgmt
     scope (+ iPXE chainload conditional to break the stock-iPXE loop);
  6. arm a TTL timer (``tappaas-pxe-ttl``) that runs
     ``node-provisioner disable`` — a network boot trap never lingers.

``disable`` reverses 3–6; ``status`` reports units, pending registrations
and the DHCP options.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
from pathlib import Path

from .log import error, info, warn
from .registry import Registry
from .util import DEFAULT_PORT, pxe_dir, run

PXE_UNIT = "tappaas-pxe.service"
TFTP_UNIT = "tappaas-pxe-tftp.service"
TTL_UNIT = "tappaas-pxe-ttl"  # .timer + .service pair created by systemd-run

DEFAULT_TTL_SECONDS = 7200  # 2h (design §4)

FIREWALL_DEFAULT = "firewall.mgmt.internal"


def _self_path() -> str:
    """Absolute path of the node-provisioner entry point for systemd-run."""
    found = shutil.which("node-provisioner")
    if found:
        return found
    return os.path.abspath(sys.argv[0])


def _find_dnsmasq() -> str | None:
    for candidate in (
        shutil.which("dnsmasq"),
        "/run/current-system/sw/bin/dnsmasq",
    ):
        if candidate and Path(candidate).is_file():
            return candidate
    return None


def _stage_ipxe_binary(tftp_root: Path, bootfile: str) -> bool:
    """Put the iPXE UEFI binary into the TFTP root (idempotent)."""
    target = tftp_root / bootfile
    if target.is_file():
        return True

    candidates = [os.environ.get("TAPPAAS_IPXE_EFI") or ""]
    # NixOS: the ipxe package installs its binaries at the store path root,
    # so they are not linked into /run/current-system — build it on demand.
    for cand in candidates:
        if cand and Path(cand).is_file():
            shutil.copyfile(cand, target)
            target.chmod(0o644)
            info(f"staged {bootfile} from {cand}")
            return True

    if shutil.which("nix-build"):
        info("building iPXE via nix (pkgs.ipxe)...")
        result = run(["nix-build", "--no-out-link", "<nixpkgs>", "-A", "ipxe"],
                     capture=True, check=False)
        if result.returncode == 0:
            store = Path(result.stdout.strip().splitlines()[-1])
            for found in sorted(store.rglob("ipxe.efi")):
                shutil.copyfile(found, target)
                target.chmod(0o644)
                info(f"staged {bootfile} from {found}")
                return True
    warn(f"could not stage {bootfile} into {tftp_root} — set TAPPAAS_IPXE_EFI "
         "or add pkgs.ipxe to the cicd NixOS config (TODO: nix addition) "
         "and re-run enable")
    return False


def detect_mgmt_ip(firewall: str = FIREWALL_DEFAULT) -> str:
    """The cicd's own mgmt-plane IPv4 (the PXE next-server address).

    Route-based: the source address of a UDP socket 'connected' to the
    firewall (no packet is sent).
    """
    for target in (firewall, "10.0.0.1"):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect((target, 53))
                return s.getsockname()[0]
        except OSError:
            continue
    raise RuntimeError(
        "cannot auto-detect the cicd mgmt IP — pass --next-server")


def _firewall_cli_args(firewall: str | None, no_ssl_verify: bool,
                       credential_file: str | None) -> list:
    args = []
    if firewall:
        args += ["--firewall", firewall]
    if no_ssl_verify:
        args += ["--no-ssl-verify"]
    if credential_file:
        args += ["--credential-file", credential_file]
    return args


def _dhcp_manager() -> str:
    return shutil.which("dhcp-manager") or "/home/tappaas/bin/dhcp-manager"


def enable(
    ttl: int = DEFAULT_TTL_SECONDS,
    port: int = DEFAULT_PORT,
    next_server: str | None = None,
    bootfile: str = "ipxe.efi",
    zone: str = "mgmt",
    firewall: str | None = None,
    no_ssl_verify: bool = False,
    credential_file: str | None = None,
) -> bool:
    """Bring the provisioning service up, TTL-limited."""
    assets = pxe_dir()
    for required in ("linux26", "initrd", "boot.ipxe"):
        if not (assets / required).is_file():
            error(f"missing asset {assets / required} — run "
                  "'node-provisioner prepare --iso <prepared-pve.iso>' first")
            return False

    tftp_root = assets / "tftp"
    tftp_root.mkdir(parents=True, exist_ok=True)
    _stage_ipxe_binary(tftp_root, bootfile)  # warns + continues on failure

    if not next_server:
        next_server = detect_mgmt_ip(firewall or FIREWALL_DEFAULT)
        info(f"auto-detected next-server (cicd mgmt IP): {next_server}")

    self_bin = _self_path()

    # 3. HTTP answer server.
    run(["systemd-run", "--collect", f"--unit={PXE_UNIT}",
         f"--property=Description=TAPPaaS PXE answer/asset server (N3)",
         self_bin, "serve", "--port", str(port)], privileged=True)
    info(f"started {PXE_UNIT} (serve --port {port})")

    # 4. TFTP for the iPXE binary.
    dnsmasq = _find_dnsmasq()
    if dnsmasq:
        run(["systemd-run", "--collect", f"--unit={TFTP_UNIT}",
             "--property=Description=TAPPaaS PXE TFTP (dnsmasq tftp-only)",
             dnsmasq, "--keep-in-foreground", "--port=0", "--enable-tftp",
             f"--tftp-root={tftp_root}", "--log-facility=-"],
            privileged=True)
        info(f"started {TFTP_UNIT} (dnsmasq tftp-only, root {tftp_root})")
    else:
        warn("dnsmasq not found on this system — TFTP is NOT running. "
             "TODO: add pkgs.dnsmasq to the tappaas-cicd NixOS "
             "configuration (environment.systemPackages) and re-run enable.")

    # 5. DHCP PXE options on the mgmt scope.
    dhcp_cmd = [
        _dhcp_manager(), *(_firewall_cli_args(firewall, no_ssl_verify,
                                              credential_file)),
        "pxe", "enable",
        "--next-server", next_server,
        "--bootfile", bootfile,
        "--zone", zone,
        "--ipxe-script-url", f"http://{next_server}:{port}/boot.ipxe",
    ]
    result = run(dhcp_cmd, check=False)
    if result.returncode != 0:
        error("dhcp-manager pxe enable failed — rolling the units back")
        disable(zone=zone, firewall=firewall, no_ssl_verify=no_ssl_verify,
                credential_file=credential_file, skip_dhcp=True)
        return False

    # 6. TTL auto-off.
    run(["systemd-run", "--collect", f"--unit={TTL_UNIT}",
         f"--on-active={ttl}",
         "--timer-property=AccuracySec=1s",
         self_bin, "disable",
         *(_firewall_cli_args(firewall, no_ssl_verify, credential_file))],
        privileged=True)
    info(f"armed auto-disable in {ttl}s ({TTL_UNIT}.timer)")

    info("provisioning ENABLED — boot the registered box now "
         f"(PXE, mgmt VLAN). Auto-off in {ttl}s; run "
         "'node-provisioner disable' as soon as the install started.")
    return True


def disable(
    zone: str = "mgmt",
    firewall: str | None = None,
    no_ssl_verify: bool = False,
    credential_file: str | None = None,
    skip_dhcp: bool = False,
) -> bool:
    """Tear the provisioning service down (idempotent)."""
    for unit in (f"{TTL_UNIT}.timer", f"{TTL_UNIT}.service",
                 PXE_UNIT, TFTP_UNIT):
        result = run(["systemctl", "stop", unit], privileged=True,
                     check=False, capture=True)
        if result.returncode == 0:
            info(f"stopped {unit}")

    ok = True
    if not skip_dhcp:
        dhcp_cmd = [
            _dhcp_manager(), *(_firewall_cli_args(firewall, no_ssl_verify,
                                                  credential_file)),
            "pxe", "disable", "--zone", zone,
        ]
        result = run(dhcp_cmd, check=False)
        if result.returncode != 0:
            error("dhcp-manager pxe disable failed — CLEAR THE DHCP BOOT "
                  "OPTIONS MANUALLY (Services > Dnsmasq > Boot options)")
            ok = False
    if ok:
        info("provisioning DISABLED")
    return ok


def _unit_active(unit: str) -> str:
    result = run(["systemctl", "is-active", unit], check=False, capture=True)
    return (result.stdout or "unknown").strip()


def status(
    zone: str = "mgmt",
    firewall: str | None = None,
    no_ssl_verify: bool = False,
    credential_file: str | None = None,
) -> bool:
    """Report units / registrations / DHCP state. Exit 0 = fully enabled."""
    pxe_active = _unit_active(PXE_UNIT)
    tftp_active = _unit_active(TFTP_UNIT)
    ttl_active = _unit_active(f"{TTL_UNIT}.timer")
    print(f"units: {PXE_UNIT}={pxe_active} {TFTP_UNIT}={tftp_active} "
          f"{TTL_UNIT}.timer={ttl_active}")

    pending = Registry().list_pending()
    if pending:
        print(f"pending registrations ({len(pending)}):")
        for reg in pending:
            macs = ", ".join(reg.macs) or "any (single-pending fallback)"
            pools = ", ".join(
                f"{p['name']}={p['layout']}:{'+'.join(p['disks'])}"
                for p in reg.pools) or "none (ext4 TODO fallback)"
            print(f"  {reg.name}: macs=[{macs}] pools=[{pools}] "
                  f"created={reg.created}")
    else:
        print("pending registrations: none")

    dhcp_cmd = [
        _dhcp_manager(), *(_firewall_cli_args(firewall, no_ssl_verify,
                                              credential_file)),
        "pxe", "status", "--zone", zone,
    ]
    try:
        result = run(dhcp_cmd, check=False)
        dhcp_enabled = result.returncode == 0
    except (OSError, subprocess.SubprocessError) as e:
        warn(f"could not query dhcp-manager: {e}")
        dhcp_enabled = False

    return pxe_active == "active" and dhcp_enabled
