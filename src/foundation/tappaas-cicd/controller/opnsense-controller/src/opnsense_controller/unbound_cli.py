#!/usr/bin/env python3
"""unbound-manager — manage OPNsense Unbound host overrides (ADR-005 #316, #269).

Unbound is the resolver TAPPaaS clients query on 10.0.0.1:53. Split-horizon DNS
for PUBLIC domains (e.g. *.tappaas.org -> the DMZ gateway where Caddy listens)
must live in Unbound Host Overrides, NOT in Dnsmasq host entries (which Unbound
does not serve for public domains, and which cannot express a wildcard). The
hostname "*" is a valid wildcard host override in Unbound.

Commands:
  unbound-manager add <hostname> <domain> <ip> [--description ...]
  unbound-manager delete <hostname> <domain>
  unbound-manager list

`*` is a valid hostname (wildcard). Changes reload Unbound automatically.
"""

import argparse
import ipaddress
import sys

from .cli_globals import make_global_parent, parse_with_globals
from .config import Config
from .dhcp_manager import DhcpManager  # reused only as a connected-Client provider
from .service_health import check_unbound_dns, unbound_checkconf


def _client(args):
    """Build a connected oxl Client from CLI args (same shape as dns-manager)."""
    config_kwargs = {
        "firewall": args.firewall,
        "ssl_verify": not args.no_ssl_verify,
        "debug": args.debug,
    }
    if args.port is not None:
        config_kwargs["port"] = args.port
    if args.credential_file:
        config_kwargs["credential_file"] = args.credential_file
    return DhcpManager(Config(**config_kwargs))


def _verify_resolver_after_write(firewall: str, what: str) -> bool:
    """Confirm Unbound still answers after a host-override write, else fail loud.

    An `unbound_host` write can return changed=True while leaving the resolver
    DEAD: a per-service override under a wildcard "redirect" zone permits
    local-data only at the apex, so it fails `unbound-checkconf` and stops the
    daemon — taking cluster DNS down (#474). OPNsense's API reports success
    anyway and the fatal line lands only in the firewall's /var/log/resolver, so
    the write silently returns 0 and the damage surfaces in later modules (#516).

    Probes the resolver (retries tolerate the normal post-write reload). On
    failure prints the service state + where to find the cause and returns False,
    so the caller exits non-zero at the write that broke DNS instead of much
    later. `firewall` is the OPNsense host we just wrote to; we probe its :53 by
    IP literal — probing a hostname would need the very resolver we are testing.
    """
    probe_ip = _resolver_probe_ip(firewall)
    if check_unbound_dns(host=probe_ip, label="POST-WRITE", retries=5, delay=2.0):
        return True
    # Resolver is down. Run the validator on the firewall to surface the exact
    # cause deterministically (#474: "local-data in redirect zone must reside at
    # top of zone") rather than leaving the operator to hunt the rotated log.
    valid, checkconf_out = unbound_checkconf(probe_ip)
    cause = (checkconf_out or "unbound-checkconf produced no output").strip()
    print(
        f"ERROR: {what} was applied but Unbound at {probe_ip}:53 stopped "
        f"answering — the write broke the resolver config (typically a "
        f"per-service override colliding with a wildcard redirect zone: "
        f"local-data must sit at the zone apex, #474). Cluster DNS is DOWN.\n"
        f"  unbound-checkconf on the firewall reports:\n"
        f"    {cause}\n"
        f"  Recover via the firewall's mgmt IP ({probe_ip}), NOT by name — name "
        f"resolution is what just broke.",
        file=sys.stderr,
    )
    return False


def _resolver_probe_ip(firewall: str) -> str:
    """The IP to probe :53 on. If `firewall` is already an IP literal use it;
    otherwise fall back to the canonical resolver mgmt IP (10.0.0.1, the default
    firewall.mgmt.internal target) — a hostname would need the resolver first."""
    try:
        ipaddress.ip_address(firewall)
        return firewall
    except ValueError:
        return "10.0.0.1"


def _find_a_overrides(mgr, hostname: str, domain: str) -> list:
    """Existing A host-overrides for <hostname>.<domain>, newest API shape."""
    result = mgr.client.run_module(
        "raw",
        params={
            "module": "unbound",
            "controller": "settings",
            "command": "searchHostOverride",
            "action": "get",
        },
    )
    rows = result.get("result", {}).get("response", {}).get("rows", []) or []
    return [
        r for r in rows
        if r.get("hostname") == hostname
        and r.get("domain") == domain
        and str(r.get("rr", "")).startswith("A")
    ]


def _delete_all_a_overrides(mgr, args, hostname: str, domain: str) -> int:
    """Remove every A override for <hostname>.<domain>. Returns how many went.

    `unbound_host` state=absent removes ONE row per call, so duplicates need a
    loop. Bounded so a delete that silently fails cannot spin forever.
    """
    removed = 0
    for _ in range(20):
        if not _find_a_overrides(mgr, hostname, domain):
            break
        res = mgr.client.run_module(
            "unbound_host",
            check_mode=args.check_mode,
            params={
                "hostname": hostname,
                "domain": domain,
                "record_type": "A",
                "state": "absent",
                "match_fields": ["hostname", "domain", "record_type"],
            },
        )
        if res.get("error") or not (res.get("result") or {}).get("changed"):
            break
        removed += 1
    return removed


def add_override(args) -> bool:
    desc = args.description or f"{args.hostname}.{args.domain}"
    with _client(args) as mgr:
        # Converge, do not accumulate. The underlying `unbound_host` module does
        # NOT reliably match an existing row on re-add — two identical calls
        # produce two rows with different uuids — so a caller that runs on every
        # reconcile (network:proxy's update-service.sh) would add one duplicate
        # per run, without bound. state=absent also removes only one row per
        # call, so duplicates never self-heal either.
        #
        # Decide here, where the match is explicit, rather than relying on the
        # module's default match_fields (which the delete path already had to
        # override for the same reason): exactly-right is a no-op, anything else
        # is flattened to a single correct row.
        existing = _find_a_overrides(mgr, args.hostname, args.domain)
        if len(existing) == 1 and existing[0].get("server") == args.ip:
            print(f"Already up to date: {args.hostname}.{args.domain} -> "
                  f"{args.ip} (Unbound host override)")
            return True
        if existing:
            n = _delete_all_a_overrides(mgr, args, args.hostname, args.domain)
            if n:
                print(f"Removed {n} stale/duplicate A override(s) for "
                      f"{args.hostname}.{args.domain}")
        result = mgr.client.run_module(
            "unbound_host",
            check_mode=args.check_mode,
            params={
                "hostname": args.hostname,
                "domain": args.domain,
                "record_type": "A",
                "value": args.ip,
                "description": desc,
                "state": "present",
            },
        )
    if result.get("error"):
        print(f"ERROR: {result['error']}", file=sys.stderr)
        return False
    changed = (result.get("result") or {}).get("changed")
    print(f"{'Created/updated' if changed else 'Already up to date'}: "
          f"{args.hostname}.{args.domain} -> {args.ip} (Unbound host override)")
    # Only a real change can have broken the resolver; a no-op skips the probe.
    if changed:
        return _verify_resolver_after_write(
            args.firewall, f"host override {args.hostname}.{args.domain} -> {args.ip}")
    return True


def delete_override(args) -> bool:
    with _client(args) as mgr:
        result = mgr.client.run_module(
            "unbound_host",
            check_mode=args.check_mode,
            params={
                "hostname": args.hostname,
                "domain": args.domain,
                "record_type": "A",
                "state": "absent",
                # Match without `value` (we don't know the IP at delete time);
                # the default match_fields includes value, which would never match.
                "match_fields": ["hostname", "domain", "record_type"],
            },
        )
    if result.get("error"):
        print(f"ERROR: {result['error']}", file=sys.stderr)
        return False
    changed = (result.get("result") or {}).get("changed")
    print(f"{'Deleted' if changed else 'Not present'}: {args.hostname}.{args.domain}")
    # A delete reloads Unbound too; verify it came back (a no-op skips the probe).
    if changed:
        return _verify_resolver_after_write(
            args.firewall, f"host override delete {args.hostname}.{args.domain}")
    return True


def list_overrides(args) -> bool:
    with _client(args) as mgr:
        result = mgr.client.run_module(
            "raw",
            params={
                "module": "unbound",
                "controller": "settings",
                "command": "searchHostOverride",
                "action": "get",
            },
        )
    rows = result.get("result", {}).get("response", {}).get("rows", [])
    if not rows:
        print("No Unbound host overrides.")
        return True
    print(f"{'HOST':<20} {'DOMAIN':<28} {'TYPE':<6} {'VALUE':<16} DESCRIPTION")
    for r in rows:
        print(f"{r.get('hostname',''):<20} {r.get('domain',''):<28} "
              f"{r.get('rr',''):<6} {r.get('server',''):<16} {r.get('description','')}")
    return True


def checkconf(args) -> bool:
    """Validate the firewall's live Unbound config (unbound-checkconf over ssh).

    Prints the validator output and exits 0 when valid, non-zero when the config
    is broken or the validator could not be run. update-tappaas's between-module
    health check calls this to capture the deterministic cause of a resolver
    outage into the sweep artifact (#516/#517). No OPNsense API — pure ssh — so
    it still works when the API is up but the resolver daemon is dead.
    """
    probe_ip = _resolver_probe_ip(args.firewall)
    valid, out = unbound_checkconf(probe_ip)
    if out:
        print(out)
    if valid:
        print(f"unbound-checkconf: config on {probe_ip} is valid")
    else:
        print(f"unbound-checkconf: config on {probe_ip} is INVALID or the "
              f"validator could not run", file=sys.stderr)
    return valid


def main():
    # Global options work on either side of the subcommand (#379); see cli_globals.py.
    gp = make_global_parent()
    gp.add_argument("--firewall", help="Firewall IP/hostname (default: firewall.mgmt.internal)")
    gp.add_argument("--port", type=int, help="API port (default: probe 443/8443)")
    gp.add_argument("--credential-file", help="Path to credential file")
    gp.add_argument("--no-ssl-verify", action="store_true", help="Disable SSL verification")
    gp.add_argument("--debug", action="store_true", help="Enable debug logging")
    gp.add_argument("--check-mode", action="store_true", help="Dry-run (no changes)")

    parser = argparse.ArgumentParser(
        description="OPNsense Unbound host-override management (split-horizon DNS)",
        parents=[gp],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  unbound-manager add '*' tappaas.org 10.6.0.1 --description "wildcard -> Caddy (DMZ)"
  unbound-manager add nextcloud tappaas.org 10.6.0.1
  unbound-manager delete nextcloud tappaas.org
  unbound-manager list
""",
    )

    sub = parser.add_subparsers(dest="command", help="Command")

    p_add = sub.add_parser("add", parents=[gp], help="Add/update an Unbound host override")
    p_add.add_argument("hostname", help="Hostname (use '*' for a wildcard)")
    p_add.add_argument("domain", help="Domain (e.g., tappaas.org)")
    p_add.add_argument("ip", help="IP address (A record target)")
    p_add.add_argument("--description", help="Description (default: hostname.domain)")

    p_del = sub.add_parser("delete", parents=[gp], help="Delete an Unbound host override")
    p_del.add_argument("hostname", help="Hostname (use '*' for a wildcard)")
    p_del.add_argument("domain", help="Domain")

    sub.add_parser("list", parents=[gp], help="List Unbound host overrides")

    sub.add_parser("checkconf", parents=[gp],
                   help="Validate the firewall's live Unbound config (unbound-checkconf)")

    args = parse_with_globals(parser, {
        "firewall": "firewall.mgmt.internal", "port": None,
        "credential_file": None, "no_ssl_verify": False,
        "debug": False, "check_mode": False,
    })
    if not args.command:
        parser.print_help()
        sys.exit(1)

    try:
        if args.command == "add":
            ok = add_override(args)
        elif args.command == "delete":
            ok = delete_override(args)
        elif args.command == "list":
            ok = list_overrides(args)
        elif args.command == "checkconf":
            ok = checkconf(args)
        else:
            parser.print_help()
            ok = False
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        if args.debug:
            raise
        sys.exit(1)

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
