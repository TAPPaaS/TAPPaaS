"""TAPPaaS trust-manager CLI — the firewall's trust store (ADR-043 D7).

Driven by ca-manager. Prints the refid of what it ensured on stdout, alone, so a
caller can read it; everything else goes to stderr. A key comes on stdin, never
in an argument:

    trust-manager ca-ensure --name 'TAPPaaS: lab2.hrossen.dk CA' --pem-file ca.pem
    trust-manager cert-ensure --name 'TAPPaaS: wildcard mgmt' --pem-file chain.pem --key-stdin < key.pem
    trust-manager list [--json]
"""

from __future__ import annotations

import json
import os
import sys

from .cli_globals import StrictArgumentParser, make_global_parent, parse_with_globals
from .config import Config
from .trust_manager import TrustManager


def _first_cert(pem: str) -> str:
    """The leaf of a chain: the trust store holds one certificate per entry."""
    end = "-----END CERTIFICATE-----"
    i = pem.find(end)
    return pem[: i + len(end)] + "\n" if i >= 0 else pem


def cmd_ca_ensure(mgr: TrustManager, args) -> int:
    with open(args.pem_file, encoding="utf-8") as f:
        pem = _first_cert(f.read())
    refid, changed = mgr.ca_ensure(args.name, pem)
    print(f"{'imported' if changed else 'present'}: {args.name}", file=sys.stderr)
    print(refid)
    return 0


def cmd_cert_ensure(mgr: TrustManager, args) -> int:
    if not args.key_stdin:
        print("cert-ensure needs --key-stdin: the key comes on stdin", file=sys.stderr)
        return 2
    with open(args.pem_file, encoding="utf-8") as f:
        pem = _first_cert(f.read())
    key = sys.stdin.read()
    if "PRIVATE KEY" not in key:
        print("cert-ensure: no private key on stdin", file=sys.stderr)
        return 2
    refid, changed = mgr.cert_ensure(args.name, pem, key)
    print(f"{'updated' if changed else 'present'}: {args.name}", file=sys.stderr)
    print(refid)
    return 0


def cmd_list(mgr: TrustManager, args) -> int:
    rows = [{"kind": k, "descr": e.descr, "refid": e.refid, "caref": e.caref} for k, es in (("ca", mgr.cas()), ("cert", mgr.certs())) for e in es]
    if args.json:
        print(json.dumps(rows, indent=1))
    else:
        for r in rows:
            print(f"{r['kind']:4} {r['refid']:14} {r['descr']}")
    return 0


def main(argv: list[str] | None = None) -> int:
    gp = make_global_parent()
    gp.add_argument("--firewall")
    gp.add_argument("--port", type=int)
    gp.add_argument("--credential-file")
    gp.add_argument("--no-ssl-verify", action="store_true")
    gp.add_argument("--debug", action="store_true")

    parser = StrictArgumentParser(prog="trust-manager", description="The OPNsense trust store, for ca-manager (ADR-043).", parents=[gp])
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("ca-ensure", parents=[gp], help="Import a CA's certificate (never its key); print its refid")
    p.add_argument("--name", required=True)
    p.add_argument("--pem-file", required=True)
    p.set_defaults(handler=cmd_ca_ensure)

    p = sub.add_parser("cert-ensure", parents=[gp], help="Import or replace a served certificate with its key (stdin); print its refid")
    p.add_argument("--name", required=True)
    p.add_argument("--pem-file", required=True)
    p.add_argument("--key-stdin", action="store_true")
    p.set_defaults(handler=cmd_cert_ensure)

    p = sub.add_parser("list", parents=[gp], help="The trust store's CAs and certificates")
    p.add_argument("--json", action="store_true")
    p.set_defaults(handler=cmd_list)

    args = parse_with_globals(parser, {
        "firewall": os.environ.get("OPNSENSE_HOST", "firewall.mgmt.internal"),
        "port": None,
        "credential_file": None,
        "no_ssl_verify": False,
        "debug": False,
    }, argv)

    config_kwargs: dict = {"firewall": args.firewall, "ssl_verify": not args.no_ssl_verify, "debug": args.debug}
    if args.port is not None:
        config_kwargs["port"] = args.port
    if args.credential_file:
        config_kwargs["credential_file"] = args.credential_file
    try:
        with TrustManager(Config(**config_kwargs)) as mgr:
            return args.handler(mgr, args)
    except RuntimeError as e:
        print(f"trust-manager: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
