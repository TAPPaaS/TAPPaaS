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

People PRIMITIVES (S2b-2 — JSON to stdout, for the TypeScript people-manager):
  list-users | list-groups | list-roles    — JSON arrays
  get-user --name                           — one user object (or null)
  ensure-user --name --email --display [--inactive]
  disable-user --name | delete-user --name
  ensure-group --name --display | ensure-role --name --display
  add-member --user --group | remove-member --user --group
  assign-role --user --role | unassign-role --user --role
See ``people_primitives.py`` for the Authentik role-mapping decision.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import secrets

import httpx

from . import people_primitives as pp
from .authentik_manager import (
    AuthentikConfig,
    AuthentikManager,
    OidcApp,
    ProxyApp,
)


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


def _parse_attrs(pairs: list[str]) -> dict:
    """Turn ['k=v', 'a.b=c'] into a nested dict (dotted keys → nesting)."""
    out: dict = {}
    for pair in pairs or []:
        if "=" not in pair:
            raise SystemExit(f"--attr expects key=value, got {pair!r}")
        key, value = pair.split("=", 1)
        node = out
        parts = key.split(".")
        for p in parts[:-1]:
            node = node.setdefault(p, {})
        node[parts[-1]] = value
    return out


def cmd_group_ensure(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    g = mgr.group_ensure(
        args.name,
        parent_name=args.parent or None,
        is_superuser=args.superuser,
        attributes=_parse_attrs(args.attr) or None,
    )
    print(f"==> group '{g['name']}' pk={g['pk']} superuser={g.get('is_superuser')} parent={g.get('parent') or '-'}")
    return 0


def cmd_user_ensure(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    u = mgr.user_ensure(
        args.username,
        email=args.email,
        name=args.name or None,
        group_names=args.group or [],
        attributes=_parse_attrs(args.attr) or None,
    )
    print(f"==> user '{u['username']}' pk={u['pk']} groups={len(u.get('groups', []))} email={u.get('email')}")
    return 0


def cmd_user_add_to_groups(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    u = mgr.user_add_to_groups(args.username, args.group)
    print(f"==> user '{u['username']}' now in {len(u.get('groups', []))} group(s)")
    return 0


def cmd_user_remove_from_groups(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    u = mgr.user_remove_from_groups(args.username, args.group)
    print(f"==> user '{u['username']}' now in {len(u.get('groups', []))} group(s)")
    return 0


def cmd_user_delete(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    if mgr.user_delete(args.username):
        print(f"==> deleted user '{args.username}'")
    else:
        print(f"==> user '{args.username}' not found (already gone)")
    return 0


def cmd_user_set_password(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    password = args.password or secrets.token_urlsafe(16)
    mgr.user_set_password(args.username, password)
    print(f"==> password set for '{args.username}'")
    if not args.password:
        print(f"    generated password: {password}")
    return 0


def cmd_user_recovery_link(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    link = mgr.user_recovery_link(args.username)
    if link:
        print(link)
        return 0
    print("no recovery flow configured on the brand (set brand.flow_recovery) — "
          "use 'user-set-password' as a fallback", file=sys.stderr)
    return 2


def cmd_app_bind_groups(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    created = mgr.app_bind_groups(args.slug, args.group)
    print(f"==> app '{args.slug}': {created} new group binding(s); {len(args.group)} requested")
    return 0


def cmd_oidc_app_ensure(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    res = mgr.oidc_app_ensure(OidcApp(
        name=args.name or args.slug,
        slug=args.slug,
        redirect_uris=args.redirect_uri,
        scopes=args.scope or None,
        description=args.description,
    ))
    print(f"==> oidc app '{res.slug}': provider_pk={res.provider_pk} application_pk={res.application_pk}")
    if args.show_secret:
        print(f"    client_id={res.client_id}")
        print(f"    client_secret={res.client_secret}")
    else:
        print(f"    client_id={res.client_id}  (client_secret hidden; use --show-secret)")
    return 0


# ── People PRIMITIVES (S2b-2) — machine-readable JSON to stdout ──────────
# Each does ONE thing and prints JSON the TypeScript people-manager parses.
# No reconcile/managed-set/lifecycle policy lives here.

def _emit(obj) -> int:
    print(json.dumps(obj))
    return 0


def cmd_list_users(mgr: AuthentikManager, _args: argparse.Namespace) -> int:
    return _emit(pp.list_users(mgr))


def cmd_list_groups(mgr: AuthentikManager, _args: argparse.Namespace) -> int:
    return _emit(pp.list_groups(mgr))


def cmd_list_roles(mgr: AuthentikManager, _args: argparse.Namespace) -> int:
    return _emit(pp.list_roles(mgr))


def cmd_get_user(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    return _emit(pp.get_user(mgr, args.name))


def cmd_ensure_user(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    return _emit(pp.ensure_user(
        mgr, name=args.name, email=args.email, display=args.display,
        inactive=args.inactive,
    ))


def cmd_disable_user(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    return _emit(pp.disable_user(mgr, args.name))


def cmd_delete_user(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    return _emit({"name": args.name, "deleted": pp.delete_user(mgr, args.name)})


def cmd_ensure_group(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    return _emit(pp.ensure_group(mgr, name=args.name, display=args.display))


def cmd_ensure_role(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    return _emit(pp.ensure_role(mgr, name=args.name, display=args.display))


def cmd_add_member(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    return _emit(pp.add_member(mgr, user=args.user, group=args.group))


def cmd_remove_member(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    return _emit(pp.remove_member(mgr, user=args.user, group=args.group))


def cmd_assign_role(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    return _emit(pp.assign_role(mgr, user=args.user, role=args.role))


def cmd_unassign_role(mgr: AuthentikManager, args: argparse.Namespace) -> int:
    return _emit(pp.unassign_role(mgr, user=args.user, role=args.role))


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

    # ── Groups / Users / Roles (ADR-006) ────────────────────────────────
    ge = sub.add_parser("group-ensure", help="create/update a group (role)")
    ge.add_argument("name")
    ge.add_argument("--parent", default="", help="parent group name (must already exist)")
    ge.add_argument("--superuser", action="store_true", help="mark group is_superuser (Installer)")
    ge.add_argument("--attr", action="append", default=[], metavar="k=v",
                    help="group attribute (dotted keys nest, e.g. tappaas.variant=acme); repeatable")
    ge.set_defaults(handler=cmd_group_ensure)

    ue = sub.add_parser("user-ensure", help="create/update a user (additive group membership)")
    ue.add_argument("username")
    ue.add_argument("--email", default="")
    ue.add_argument("--name", default="", help="display name (default: username)")
    ue.add_argument("--group", action="append", default=[], help="group to add the user to; repeatable")
    ue.add_argument("--attr", action="append", default=[], metavar="k=v", help="user attribute; repeatable")
    ue.set_defaults(handler=cmd_user_ensure)

    ug = sub.add_parser("user-add-to-groups", help="add an existing user to groups (additive)")
    ug.add_argument("username")
    ug.add_argument("--group", action="append", required=True, default=[], help="group name; repeatable")
    ug.set_defaults(handler=cmd_user_add_to_groups)

    ur2 = sub.add_parser("user-remove-from-groups", help="remove a user from groups (idempotent)")
    ur2.add_argument("username")
    ur2.add_argument("--group", action="append", required=True, default=[], help="group name; repeatable")
    ur2.set_defaults(handler=cmd_user_remove_from_groups)

    ud = sub.add_parser("user-delete", help="delete a user entirely")
    ud.add_argument("username")
    ud.set_defaults(handler=cmd_user_delete)

    up = sub.add_parser("user-set-password", help="set a user's password (prints generated one if omitted)")
    up.add_argument("username")
    up.add_argument("--password", default="", help="explicit password (default: generate + print)")
    up.set_defaults(handler=cmd_user_set_password)

    ur = sub.add_parser("user-recovery-link", help="print a one-time recovery/enrollment link")
    ur.add_argument("username")
    ur.set_defaults(handler=cmd_user_recovery_link)

    bg = sub.add_parser("app-bind-groups",
                        help="bind groups to an application (the access gate; additive)")
    bg.add_argument("slug")
    bg.add_argument("--group", action="append", required=True, default=[], help="group name; repeatable")
    bg.set_defaults(handler=cmd_app_bind_groups)

    oe = sub.add_parser("oidc-app-ensure",
                        help="create/update an OIDC (OAuth2/OpenID) Provider + Application")
    oe.add_argument("slug", help="immutable URL slug (also used to match existing)")
    oe.add_argument("--name", default="", help="human-readable name (default: slug)")
    oe.add_argument("--redirect-uri", action="append", required=True, default=[],
                    help="exact redirect URI (strict match); repeatable")
    oe.add_argument("--scope", action="append", default=[],
                    help="OIDC scope-mapping name (default: openid email profile); repeatable")
    oe.add_argument("--description", default="")
    oe.add_argument("--show-secret", action="store_true", help="print the client_secret (sensitive)")
    oe.set_defaults(handler=cmd_oidc_app_ensure)

    # ── People PRIMITIVES (S2b-2) — JSON to stdout for the TS people-manager ─
    sub.add_parser("list-users", help="JSON array of users (name/active/email/displayName/groups/roles)")\
       .set_defaults(handler=cmd_list_users)
    sub.add_parser("list-groups", help="JSON array of {name, displayName} (excludes roles)")\
       .set_defaults(handler=cmd_list_groups)
    sub.add_parser("list-roles", help="JSON array of {name, displayName} (role-marked groups)")\
       .set_defaults(handler=cmd_list_roles)

    gu = sub.add_parser("get-user", help="JSON of one user object, or null if absent")
    gu.add_argument("--name", required=True)
    gu.set_defaults(handler=cmd_get_user)

    eu = sub.add_parser("ensure-user", help="create user if missing (idempotent); reconciles only active flag")
    eu.add_argument("--name", required=True)
    eu.add_argument("--email", required=True)
    eu.add_argument("--display", required=True)
    eu.add_argument("--inactive", action="store_true", help="create/keep the user inactive")
    eu.set_defaults(handler=cmd_ensure_user)

    du = sub.add_parser("disable-user", help="set is_active=false (idempotent)")
    du.add_argument("--name", required=True)
    du.set_defaults(handler=cmd_disable_user)

    dl = sub.add_parser("delete-user", help="delete a user (idempotent; no-op if absent)")
    dl.add_argument("--name", required=True)
    dl.set_defaults(handler=cmd_delete_user)

    eg = sub.add_parser("ensure-group", help="create a group if missing (idempotent)")
    eg.add_argument("--name", required=True)
    eg.add_argument("--display", required=True)
    eg.set_defaults(handler=cmd_ensure_group)

    er = sub.add_parser("ensure-role", help="create a role (marked group) if missing (idempotent)")
    er.add_argument("--name", required=True)
    er.add_argument("--display", required=True)
    er.set_defaults(handler=cmd_ensure_role)

    am = sub.add_parser("add-member", help="add a user to a group (idempotent)")
    am.add_argument("--user", required=True)
    am.add_argument("--group", required=True)
    am.set_defaults(handler=cmd_add_member)

    rm = sub.add_parser("remove-member", help="remove a user from a group (idempotent)")
    rm.add_argument("--user", required=True)
    rm.add_argument("--group", required=True)
    rm.set_defaults(handler=cmd_remove_member)

    ar = sub.add_parser("assign-role", help="assign a role to a user directly (idempotent)")
    ar.add_argument("--user", required=True)
    ar.add_argument("--role", required=True)
    ar.set_defaults(handler=cmd_assign_role)

    uar = sub.add_parser("unassign-role", help="remove a role from a user (idempotent)")
    uar.add_argument("--user", required=True)
    uar.add_argument("--role", required=True)
    uar.set_defaults(handler=cmd_unassign_role)

    args = p.parse_args(argv)
    try:
        with _make_manager(args) as mgr:
            return args.handler(mgr, args)
    except httpx.HTTPStatusError as e:
        body = ""
        try:
            body = e.response.text
        except Exception:  # noqa: BLE001
            pass
        print(f"Authentik API error: {e} {body}".strip(), file=sys.stderr)
        return 1
    except (httpx.HTTPError, RuntimeError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
