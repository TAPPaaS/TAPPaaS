"""TAPPaaS authentik-manager CLI — automate Authentik integration (issue #45).

Drives a running Authentik over its REST API. Used by:

  * ``identity/install.sh`` at install time (sets the embedded outpost's
    authentik_host, registers the identity self-app).
  * ``identity/services/accessControl/install-service.sh`` for every consumer
    that ``dependsOn: [identity:accessControl]`` — creates the per-app Proxy
    Provider + Application and attaches it to the embedded outpost.

Credentials are read from ``~/.authentik-credentials.txt`` (mode 600),
populated at identity install time. The file format mirrors
``~/.opnsense-credentials.txt``:

    url=http://identity.mgmt.internal:9000
    token=<AUTHENTIK_BOOTSTRAP_TOKEN>

Subcommands:
  test                                     — confirm token + reachability
  proxy-app-ensure <slug> --name … --external-host …
                                            — idempotent Proxy app for forward-auth
  app-delete <slug>                         — remove an app + its provider
  outpost-attach <slug>                     — attach the app's provider to the embedded outpost
  outpost-set-authentik-host <url>          — set the public URL the outpost redirects to
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from .authentik_manager import AuthentikConfig, AuthentikManager, ProxyApp


DEFAULT_CRED_FILE = Path.home() / ".authentik-credentials.txt"


def _read_creds(path: Path) -> tuple[str, str]:
    """Return (url, token) from a key=value credentials file."""
    if not path.is_file():
        raise SystemExit(
            f"credentials file not found: {path} (created by identity/install.sh; "
            "format: url=...\\ntoken=...)"
        )
    url = token = ""
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k.strip() == "url":
            url = v.strip()
        elif k.strip() == "token":
            token = v.strip()
    if not url or not token:
        raise SystemExit(f"{path} must define both url= and token=")
    return url, token


def _make_manager(args: argparse.Namespace) -> AuthentikManager:
    if args.url and args.token:
        url, token = args.url, args.token
    else:
        url, token = _read_creds(Path(args.credential_file))
    return AuthentikManager(AuthentikConfig(
        base_url=url, token=token, verify_tls=not args.no_tls_verify,
    ))


def cmd_test(mgr: AuthentikManager, _args: argparse.Namespace) -> int:
    print(f"==> {mgr.config.base_url}")
    if mgr.test_connection():
        print("    ✓ token accepted, API reachable")
        return 0
    print("    ✗ unable to authenticate (wrong token or Authentik unreachable)", file=sys.stderr)
    return 1


def cmd_proxy_app_ensure(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    res = mgr.proxy_app_ensure(ProxyApp(
        name=args.name or args.slug,
        slug=args.slug,
        external_host=args.external_host,
        description=args.description,
    ))
    print(f"==> proxy app '{res.slug}': provider_pk={res.provider_pk} application_pk={res.application_pk}")
    if args.attach_outpost:
        mgr.outpost_attach_provider(res.provider_pk)
        print("    ✓ attached to embedded outpost")
    return 0


def cmd_app_delete(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    # Detach from the outpost first so we leave the outpost provider list clean.
    apps = mgr._get_json("/core/applications/", slug=args.slug).get("results", [])  # noqa: SLF001
    for a in apps:
        if a.get("provider"):
            mgr.outpost_detach_provider(a["provider"])
    mgr.app_delete(args.slug)
    print(f"==> deleted app/provider '{args.slug}' (idempotent)")
    return 0


def cmd_outpost_attach(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    apps = mgr._get_json("/core/applications/", slug=args.slug).get("results", [])  # noqa: SLF001
    if not apps:
        print(f"no application with slug {args.slug!r}", file=sys.stderr)
        return 1
    provider_pk = apps[0].get("provider")
    if not provider_pk:
        print(f"application {args.slug!r} has no provider", file=sys.stderr)
        return 1
    mgr.outpost_attach_provider(provider_pk)
    print(f"==> attached provider_pk={provider_pk} to embedded outpost")
    return 0


def cmd_outpost_set_authentik_host(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    mgr.outpost_set_authentik_host(args.host)
    print(f"==> embedded outpost authentik_host = {args.host}")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="authentik-manager",
        description="Drive Authentik over its REST API for TAPPaaS (issue #45).",
    )
    p.add_argument("--credential-file", default=str(DEFAULT_CRED_FILE),
                   help=f"path to credentials file (default: {DEFAULT_CRED_FILE})")
    p.add_argument("--url", default=os.environ.get("AUTHENTIK_URL", ""),
                   help="override the URL from the credentials file")
    p.add_argument("--token", default=os.environ.get("AUTHENTIK_TOKEN", ""),
                   help="override the token from the credentials file")
    p.add_argument("--no-tls-verify", action="store_true",
                   help="skip TLS certificate verification")

    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("test", help="verify the token + connectivity")\
       .set_defaults(handler=cmd_test)

    pa = sub.add_parser("proxy-app-ensure",
                        help="create/update a forward-auth Proxy Provider + Application")
    pa.add_argument("slug", help="immutable URL slug (also used to match existing)")
    pa.add_argument("--name", default="", help="human-readable name (default: slug)")
    pa.add_argument("--external-host", required=True,
                    help="public URL of the protected service (e.g. https://app.example.org)")
    pa.add_argument("--description", default="")
    pa.add_argument("--attach-outpost", action="store_true",
                    help="also attach the new provider to the embedded outpost")
    pa.set_defaults(handler=cmd_proxy_app_ensure)

    ad = sub.add_parser("app-delete", help="remove an application + its provider")
    ad.add_argument("slug")
    ad.set_defaults(handler=cmd_app_delete)

    oa = sub.add_parser("outpost-attach",
                        help="attach an application's provider to the embedded outpost")
    oa.add_argument("slug")
    oa.set_defaults(handler=cmd_outpost_attach)

    oh = sub.add_parser("outpost-set-authentik-host",
                        help="set the embedded outpost's authentik_host (public URL for redirects)")
    oh.add_argument("host", help="full URL, e.g. https://identity.example.org")
    oh.set_defaults(handler=cmd_outpost_set_authentik_host)

    args = p.parse_args(argv)
    with _make_manager(args) as mgr:
        return args.handler(mgr, args)


if __name__ == "__main__":
    sys.exit(main())
