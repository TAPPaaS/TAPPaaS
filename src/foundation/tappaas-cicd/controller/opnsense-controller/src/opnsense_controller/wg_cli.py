#!/usr/bin/env python3
"""CLI for the ADR-010 home-side WireGuard (os-wireguard) tunnel — SCAFFOLD (P2).

Plans (and, once the os-wireguard live binding is confirmed, applies) the home
OPNsense interface + the satellite peer for the satellite infra tunnel.

Until the live binding is confirmed on hardware (P2 deep test), use --dry-run
(the default), which prints the intended operations as JSON without touching
OPNsense.

Usage:
    opnsense-wg ensure-server --name edge-sat1 --address 10.255.0.1/31
    opnsense-wg ensure-peer   --server edge-sat1 --name satellite-sat1 \\
        --public-key <KEY> --endpoint 203.0.113.10:51820 --allowed-ips 10.255.0.0/32
    opnsense-wg apply
"""

from __future__ import annotations

import argparse
import json
import sys

from .config import Config
from .wg_manager import WgPeer, WgServer, WireGuardManager


def _config(args) -> Config:
    # In dry-run we only PLAN — never connect — so inject placeholder creds to
    # satisfy Config's credential check without needing real OPNsense access.
    extra = {"token": "dry-run", "secret": "dry-run", "credential_file": None} if args.dry_run else {}
    return Config(firewall=args.firewall, ssl_verify=not args.no_ssl_verify, debug=args.debug, **extra)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="opnsense-wg", description="ADR-010 home-side WireGuard (scaffold)")
    p.add_argument("--firewall", default="firewall.mgmt.internal")
    p.add_argument("--no-ssl-verify", action="store_true")
    p.add_argument("--debug", action="store_true")
    p.add_argument("--dry-run", action="store_true", default=True,
                   help="record intended ops only (default; live binding pending P2 deep test)")
    p.add_argument("--execute", dest="dry_run", action="store_false",
                   help="apply against OPNsense (raises until the os-wireguard binding is confirmed)")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("ensure-server")
    s.add_argument("--name", required=True)
    s.add_argument("--address", required=True)
    s.add_argument("--listen-port", type=int, default=51820)

    pe = sub.add_parser("ensure-peer")
    pe.add_argument("--server", required=True)
    pe.add_argument("--name", required=True)
    pe.add_argument("--public-key", required=True)
    pe.add_argument("--endpoint", required=True)
    pe.add_argument("--allowed-ips", required=True, help="comma-separated")
    pe.add_argument("--keepalive", type=int, default=25)

    rp = sub.add_parser("remove-peer")
    rp.add_argument("--server", required=True)
    rp.add_argument("--name", required=True)

    sub.add_parser("apply")

    args = p.parse_args(argv)
    mgr = WireGuardManager(_config(args), dry_run=args.dry_run)
    try:
        with mgr:
            if args.cmd == "ensure-server":
                mgr.ensure_server(WgServer(args.name, args.address, args.listen_port))
            elif args.cmd == "ensure-peer":
                mgr.ensure_peer(args.server, WgPeer(
                    name=args.name, public_key=args.public_key, endpoint=args.endpoint,
                    allowed_ips=[s.strip() for s in args.allowed_ips.split(",")],
                    keepalive=args.keepalive))
            elif args.cmd == "remove-peer":
                mgr.remove_peer(args.server, args.name)
            elif args.cmd == "apply":
                mgr.apply()
    except NotImplementedError as e:
        print(f"[wg] {e}", file=sys.stderr)
        return 3

    print(json.dumps({"dry_run": args.dry_run, "planned": mgr.planned}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
