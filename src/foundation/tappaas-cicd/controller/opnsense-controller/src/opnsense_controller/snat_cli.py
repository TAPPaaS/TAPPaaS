#!/usr/bin/env python3
"""CLI for OPNsense source-NAT (masquerade) management.

Manages "Firewall → NAT → Outbound" rules on OPNsense via the
``firewall/source_nat`` API (ADR-016). Source NAT rewrites the *source*
address of traffic entering a zone, for devices whose firmware only accepts
sessions from their own subnet; ``nat-manager`` is the opposite direction —
destination NAT, publishing an inside port outward.

This is the low-level controller. Modules do not call it: they declare
``snatFrom``/``snatReason`` and depend on ``network:snat``, and
``network-manager snat`` applies the zone gate before reaching this layer.

Usage:
    snat-manager mode
    snat-manager mode --set hybrid
    snat-manager add-rule --description "tappaas-snat:alfen:home->iotCloud" \\
        --interface opt4 --source 10.3.10.0/24 --destination 10.4.20.0/24 --target opt4ip
    snat-manager list-rules
    snat-manager delete-rule --description "tappaas-snat:alfen:home->iotCloud"
    snat-manager apply
"""

import argparse
import json
import os
import sys

from pathlib import Path

from .cli_globals import StrictArgumentParser, make_global_parent, parse_with_globals
from .config import Config
from .snat_manager import MODES, SnatManager, SnatModeError, SnatRule
from .snat_policy import (
    DESC_PREFIX,
    apply_gate,
    desired_rules,
    load_request,
    load_zones,
    owned_prefix,
    plan_reconcile,
    validate_zone_gate,
)
from .vlan_manager import VlanManager

# Reuse rules_manager's resolver rather than writing a second one. It prefers
# the DEPLOYED zones.json over the source tree, resolves `serves` links through
# zones.effective.json, and carries a staleness guard for exactly the case that
# broke this service's first deep run: network/test.sh --deep jq-merges its
# probe zones straight into the deployed file, so a resolver that read the
# source tree saw a zone graph the running system had already moved past.
# Two implementations of "which zones.json" is two answers waiting to disagree.
from .rules_manager import _find_zones_file

DEFAULT_CONFIG_DIR = Path("/home/tappaas/config")


def get_config(args) -> Config:
    """Build configuration from CLI arguments and environment."""
    firewall = os.environ.get("OPNSENSE_HOST", args.firewall)
    if args.firewall != "firewall.mgmt.internal":
        firewall = args.firewall

    config_kwargs = {
        "firewall": firewall,
        "ssl_verify": not args.no_ssl_verify,
        "debug": args.debug,
    }
    if getattr(args, "port", None) is not None:
        config_kwargs["port"] = args.port
    if args.credential_file:
        config_kwargs["credential_file"] = args.credential_file

    try:
        return Config(**config_kwargs)
    except ValueError as e:
        print(f"Configuration error: {e}", file=sys.stderr)
        sys.exit(1)


def cmd_mode(args) -> int:
    """Read, or set, the firewall-wide outbound-NAT mode."""
    config = get_config(args)

    try:
        with SnatManager(config) as manager:
            if args.set:
                previous = manager.get_mode()
                if args.set == previous:
                    if args.json:
                        print(json.dumps({"mode": previous, "changed": False}))
                    else:
                        print(f"Outbound-NAT mode already {previous}")
                    return 0
                manager.set_mode(args.set, apply=not args.no_apply)
                if args.json:
                    print(
                        json.dumps(
                            {"mode": args.set, "previous": previous, "changed": True}
                        )
                    )
                else:
                    print(f"Outbound-NAT mode: {previous} -> {args.set}")
                return 0

            mode = manager.get_mode()
            enforcing = manager.is_enforcing(mode)
            if args.json:
                print(json.dumps({"mode": mode, "enforcing": enforcing}))
            else:
                print(f"Outbound-NAT mode: {mode}")
                if not enforcing:
                    # The whole point of #239: a stored rule in this mode is
                    # accepted and never evaluated. Say so where it is read.
                    print(
                        "  Custom source-NAT rules are NOT enforced in this mode "
                        "(they are accepted into config and excluded from the ruleset)."
                    )
            return 0
    except SnatModeError as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error: {e}", file=sys.stderr)
        return 1
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error reading outbound-NAT mode: {e}", file=sys.stderr)
        return 1


def cmd_add_rule(args) -> int:
    """Create or update a source-NAT rule."""
    config = get_config(args)

    rule = SnatRule(
        description=args.description,
        interface=args.interface,
        source_net=args.source,
        destination_net=args.destination,
        target=args.target,
        ip_protocol=args.ip_protocol,
        enabled=not args.disabled,
    )

    try:
        with SnatManager(config) as manager:
            # The mode is DERIVED: declaring a rule is declaring that it must
            # work, so making it enforceable is part of applying it, not a
            # separate opt-in. Additive, reported, and refused on 'disabled'.
            _, flipped = manager.ensure_enforcing(apply=not args.no_apply)
            result = manager.add_rule(rule, apply=not args.no_apply)
            mode = manager.get_mode()
            enforcing = manager.is_enforcing(mode)

            if args.json:
                print(
                    json.dumps(
                        {
                            "result": result,
                            "mode": mode,
                            "enforcing": enforcing,
                            "mode_changed": flipped,
                        }
                    )
                )
            else:
                if flipped:
                    print("Outbound-NAT mode: automatic -> hybrid (additive)")
                print(
                    f"Source NAT set: {args.source} -> {args.destination} "
                    f"masqueraded to {args.target} on {args.interface} "
                    f"[{args.description}]"
                )
                if not enforcing:
                    print(
                        f"  WARNING: mode is {mode} — this rule is stored but NOT enforced. "
                        "Set 'snat-manager mode --set hybrid' to make it take effect.",
                        file=sys.stderr,
                    )
            return 0
    except SnatModeError as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error: {e}", file=sys.stderr)
        return 1
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error creating source-NAT rule: {e}", file=sys.stderr)
        return 1


def cmd_list_rules(args) -> int:
    """List source-NAT rules stored in config."""
    config = get_config(args)

    try:
        with SnatManager(config) as manager:
            rules = manager.list_rules(args.search or "")
            mode = manager.get_mode()
            enforcing = manager.is_enforcing(mode)

            if args.json:
                print(
                    json.dumps(
                        {
                            "mode": mode,
                            "enforcing": enforcing,
                            "rules": [
                                {
                                    "uuid": r.uuid,
                                    "description": r.description,
                                    "enabled": r.enabled,
                                    "interface": r.interface,
                                    "source_net": r.source_net,
                                    "destination_net": r.destination_net,
                                    "target": r.target,
                                }
                                for r in rules
                            ],
                        },
                        indent=2,
                    )
                )
            else:
                if not rules:
                    print("No source-NAT rules found")
                else:
                    for r in rules:
                        status = "enabled" if r.enabled else "disabled"
                        print(
                            f"[{status}] {r.source_net} -> {r.destination_net} "
                            f"via {r.target} on {r.interface} ({r.description})"
                        )
                if rules and not enforcing:
                    print(
                        f"  WARNING: mode is {mode} — the rules above are stored but NOT enforced.",
                        file=sys.stderr,
                    )
            return 0
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error listing source-NAT rules: {e}", file=sys.stderr)
        return 1


def cmd_delete_rule(args) -> int:
    """Delete a source-NAT rule."""
    config = get_config(args)

    try:
        with SnatManager(config) as manager:
            if args.uuid:
                result = manager.delete_rule_by_uuid(args.uuid, apply=not args.no_apply)
                target = args.uuid
            else:
                result = manager.delete_rule(args.description, apply=not args.no_apply)
                target = args.description

            if args.json:
                print(json.dumps(result))
            elif result.get("result") == "not_found":
                print(f"No source-NAT rule found: {target}")
            else:
                print(f"Source-NAT rule deleted: {target}")
            return 0
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error deleting source-NAT rule: {e}", file=sys.stderr)
        return 1


def cmd_apply(args) -> int:
    """Apply pending source-NAT changes."""
    config = get_config(args)

    try:
        with SnatManager(config) as manager:
            result = manager.apply_changes()
            if args.json:
                print(json.dumps(result))
            else:
                print("Source-NAT changes applied")
            return 0
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error applying source-NAT changes: {e}", file=sys.stderr)
        return 1


def cmd_test(args) -> int:
    """Test the connection to OPNsense."""
    config = get_config(args)

    try:
        with SnatManager(config) as manager:
            ok = manager.test_connection()
            if args.json:
                print(json.dumps({"connected": ok}))
            else:
                print("Connection OK" if ok else "Connection failed")
            return 0 if ok else 1
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Connection error: {e}", file=sys.stderr)
        return 1


# =============================================================================
# Module-level verbs — the gated surface the service hooks call
# =============================================================================


def _iface_resolver(manager: SnatManager, config: Config):
    """Return a ZoneSpec -> OPNsense interface identifier function.

    zone-manager assigns VLAN interfaces with description = zone name, but the
    rule API wants the identifier (opt<n>), so the tag has to be looked up.
    Cached for the life of the call; falls back to the bridge, which makes the
    API reject with a message naming the mismatch rather than writing a rule
    onto the wrong interface.
    """
    cache: dict[int, str] = {}
    loaded = [False]

    def resolve(zone) -> str:
        if zone.vlan_tag > 0:
            if not loaded[0]:
                loaded[0] = True
                try:
                    with VlanManager(config) as vlan_mgr:
                        for v in vlan_mgr.get_assigned_vlans():
                            tag, ident = v.get("vlan_tag"), v.get("identifier")
                            if tag and ident:
                                try:
                                    cache[int(str(tag))] = ident
                                except ValueError:
                                    continue
                except Exception as exc:  # noqa: BLE001 - surfaced, not swallowed
                    print(
                        f"Warning: could not load VLAN->interface map: {exc}",
                        file=sys.stderr,
                    )
            if zone.vlan_tag in cache:
                return cache[zone.vlan_tag]
            print(
                f"Warning: zone '{zone.name}' (VLAN {zone.vlan_tag}) is not assigned "
                f"to any OPNsense interface — falling back to bridge '{zone.bridge}'",
                file=sys.stderr,
            )
        return zone.bridge.lower()

    return resolve


def _gate_or_die(args, manager, config):
    """Load the module's request, apply the zone gate, and build its rules.

    Returns ``(request, plan, desired)``. Raises SnatModeError carrying every
    gate message when the request cannot proceed — R3 makes a partial grant a
    whole-request failure, so there is no half-applied path out of here.
    """
    zones = load_zones(_find_zones_file(args.zones_file))
    request = load_request(Path(args.config_dir), args.module)
    gate = apply_gate(request, zones)
    if not gate.ok:
        raise SnatModeError("\n  ".join(gate.errors))

    desired = desired_rules(request, zones, gate.allowed, _iface_resolver(manager, config))
    live = [
        r for r in manager.list_rules(owned_prefix(request.module))
        if r.description.startswith(owned_prefix(request.module))
    ]
    return request, plan_reconcile(desired, live), desired


def cmd_apply_module(args) -> int:
    """Reconcile one module's declared source NAT onto the firewall.

    Idempotent and symmetric: a zone added to snatFrom gains a rule, a zone
    REMOVED loses one. update-service.sh calls exactly this, which is what
    makes an edited module JSON take effect in both directions — a dropped
    zone whose rule lingers is drift that reads as success.
    """
    config = get_config(args)

    try:
        with SnatManager(config) as manager:
            request, plan, desired = _gate_or_die(args, manager, config)

            if args.check:
                if args.json:
                    print(json.dumps({
                        "module": request.module, "dry_run": True,
                        "to_apply": [r["description"] for r in plan.to_apply],
                        "to_delete": plan.to_delete, "unchanged": plan.unchanged,
                    }, indent=2))
                else:
                    for r in plan.to_apply:
                        print(f"  + {r['description']}")
                    for d in plan.to_delete:
                        print(f"  - {d}")
                    for u in plan.unchanged:
                        print(f"  = {u}")
                    if plan.empty:
                        print(f"{request.module}: source NAT already converged")
                return 0

            flipped = False
            if desired:
                # Derived, not requested: a declared rule is a rule that must
                # work, so enforceability comes with it.
                _, flipped = manager.ensure_enforcing(apply=False)
                if flipped:
                    print("Outbound-NAT mode: automatic -> hybrid (additive)")

            for rule in plan.to_apply:
                manager.add_rule(SnatRule(**rule), apply=False)
                print(f"  + {rule['description']}")
            for desc in plan.to_delete:
                manager.delete_rule(desc, apply=False)
                print(f"  - {desc}")

            if not plan.empty or flipped:
                manager.apply_changes()

            mode = manager.get_mode()
            if desired and not manager.is_enforcing(mode):
                print(
                    f"  ERROR: mode is {mode} — the rules above are stored but NOT enforced.",
                    file=sys.stderr,
                )
                return 1

            if args.json:
                print(json.dumps({
                    "module": request.module, "applied": len(plan.to_apply),
                    "deleted": len(plan.to_delete), "mode": mode, "mode_changed": flipped,
                }))
            elif plan.empty:
                print(f"{request.module}: source NAT already converged")
            return 0
    except SnatModeError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001
        print(f"Error applying source NAT for {args.module}: {e}", file=sys.stderr)
        return 1


def cmd_delete_module(args) -> int:
    """Remove every source-NAT rule this module owns.

    Unconditional by design: a module whose declaration was emptied before it
    was deleted must still have its rules cleaned up, so this works off the
    ownership prefix rather than off the current declaration.
    """
    config = get_config(args)

    try:
        with SnatManager(config) as manager:
            prefix = owned_prefix(args.module)
            live = [r for r in manager.list_rules(prefix) if r.description.startswith(prefix)]
            for rule in live:
                if not args.check:
                    manager.delete_rule_by_uuid(rule.uuid, apply=False)
                print(f"  - {rule.description}")
            if live and not args.check:
                manager.apply_changes()
            if args.json:
                print(json.dumps({"module": args.module, "deleted": len(live)}))
            elif not live:
                print(f"{args.module}: no source-NAT rules to remove")
            return 0
    except Exception as e:  # noqa: BLE001
        print(f"Error removing source NAT for {args.module}: {e}", file=sys.stderr)
        return 1


def cmd_verify_module(args) -> int:
    """Assert declared == live AND enforced.

    Enforcement is the point. A rule present in config while the mode is
    'automatic' is the #239 failure exactly: reported installed, never in the
    ruleset. Presence alone is not a pass here.
    """
    config = get_config(args)

    try:
        with SnatManager(config) as manager:
            request, plan, desired = _gate_or_die(args, manager, config)
            mode = manager.get_mode()
            enforcing = manager.is_enforcing(mode)

            drifted = [r["description"] for r in plan.to_apply]
            orphans = plan.to_delete
            ok = not drifted and not orphans and (enforcing or not desired)

            if args.json:
                print(json.dumps({
                    "module": request.module, "ok": ok, "mode": mode,
                    "enforcing": enforcing, "missing": drifted, "orphaned": orphans,
                    "present": plan.unchanged,
                }, indent=2))
            else:
                for desc in plan.unchanged:
                    print(f"  present: {desc}")
                for desc in drifted:
                    print(f"  MISSING: {desc}")
                for desc in orphans:
                    print(f"  ORPHANED (declared nowhere): {desc}")
                if desired and not enforcing:
                    print(
                        f"  NOT ENFORCED: outbound-NAT mode is {mode} — these rules "
                        f"are in config and excluded from the ruleset."
                    )
            return 0 if ok else 1
    except SnatModeError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001
        print(f"Error verifying source NAT for {args.module}: {e}", file=sys.stderr)
        return 1


def cmd_validate(args) -> int:
    """Check R1 across zones.json, offline. No firewall contact.

    This is the enforcement point for the zone gate — network-manager validate
    does not read it (#629).
    """
    problems = validate_zone_gate(load_zones(_find_zones_file(args.zones_file)))
    if args.json:
        print(json.dumps({"ok": not problems, "problems": problems}, indent=2))
    elif problems:
        for p in problems:
            print(f"  {p}", file=sys.stderr)
    else:
        print("zones.json: every snat-allowed-from source can reach its zone (R1)")
    return 1 if problems else 0


def make_globals() -> argparse.ArgumentParser:
    """Build the shared global-option parent (works on either side of the
    subcommand, #379; see cli_globals.py). No ``default=`` — the parent's
    SUPPRESS default plus parse_with_globals seeding supplies the real values.
    """
    gp = make_global_parent()
    gp.add_argument(
        "--firewall",
        help="Firewall IP/hostname (default: firewall.mgmt.internal)",
    )
    gp.add_argument(
        "--port",
        type=int,
        help="API port (default: auto-detect by probing 443, then 8443)",
    )
    gp.add_argument("--credential-file", help="Path to credential file")
    gp.add_argument(
        "--no-ssl-verify",
        action="store_true",
        help="Disable SSL certificate verification",
    )
    gp.add_argument("--debug", action="store_true", help="Enable debug logging")
    gp.add_argument("--json", action="store_true", help="Output in JSON format")
    return gp


def main():
    """Main entry point for the source-NAT CLI."""
    gp = make_globals()
    parser = StrictArgumentParser(
        description="Manage OPNsense source-NAT (masquerade) rules",
        parents=[gp],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # mode
    mode_parser = subparsers.add_parser(
        "mode",
        parents=[gp],
        help="Read or set the firewall-wide outbound-NAT mode",
    )
    mode_parser.add_argument(
        "--set",
        choices=MODES,
        help="Set the mode. 'advanced' is the API spelling of the GUI's 'Manual'; "
        "it REPLACES automatic rule generation and can drop outbound connectivity "
        "site-wide, so set it only deliberately.",
    )
    mode_parser.add_argument(
        "--no-apply", action="store_true", help="Do not apply changes immediately"
    )
    mode_parser.set_defaults(func=cmd_mode)

    # add-rule
    add_parser = subparsers.add_parser(
        "add-rule", parents=[gp], help="Create or update a source-NAT rule"
    )
    add_parser.add_argument(
        "--description", required=True, help="Rule description (the idempotency key)"
    )
    add_parser.add_argument(
        "--interface", required=True, help="OPNsense interface of the destination zone"
    )
    add_parser.add_argument("--source", required=True, help="Source network CIDR")
    add_parser.add_argument(
        "--destination", required=True, help="Destination network CIDR"
    )
    add_parser.add_argument(
        "--target", required=True, help="Address to translate to (e.g. opt4ip)"
    )
    add_parser.add_argument(
        "--ip-protocol", default="inet", choices=["inet", "inet6"], help="Address family"
    )
    add_parser.add_argument(
        "--disabled", action="store_true", help="Create the rule disabled"
    )
    add_parser.add_argument(
        "--no-apply", action="store_true", help="Do not apply changes immediately"
    )
    add_parser.set_defaults(func=cmd_add_rule)

    # list-rules
    list_parser = subparsers.add_parser(
        "list-rules", parents=[gp], help="List source-NAT rules stored in config"
    )
    list_parser.add_argument("--search", help="Filter rules by description")
    list_parser.set_defaults(func=cmd_list_rules)

    # delete-rule
    delete_parser = subparsers.add_parser(
        "delete-rule", parents=[gp], help="Delete a source-NAT rule"
    )
    delete_group = delete_parser.add_mutually_exclusive_group(required=True)
    delete_group.add_argument("--description", help="Rule description to delete")
    delete_group.add_argument("--uuid", help="Rule UUID to delete")
    delete_parser.add_argument(
        "--no-apply", action="store_true", help="Do not apply changes immediately"
    )
    delete_parser.set_defaults(func=cmd_delete_rule)

    # apply
    apply_parser = subparsers.add_parser(
        "apply", parents=[gp], help="Apply pending source-NAT changes"
    )
    apply_parser.set_defaults(func=cmd_apply)

    # test
    test_parser = subparsers.add_parser(
        "test", parents=[gp], help="Test the connection to OPNsense"
    )
    test_parser.set_defaults(func=cmd_test)

    # ── module-level verbs (the gated surface the service hooks call) ──

    def _module_parser(name: str, helptext: str, func):
        sp = subparsers.add_parser(name, parents=[gp], help=helptext)
        sp.add_argument("module", help="Module name (its deployed <name>.json)")
        sp.add_argument(
            "--zones-file",
            default=None,
            help="Path to zones.json (default: the deployed file, resolved)",
        )
        sp.add_argument(
            "--config-dir",
            default=str(DEFAULT_CONFIG_DIR),
            help="Directory holding deployed module JSON",
        )
        sp.add_argument(
            "--check", action="store_true", help="Dry run — report, change nothing"
        )
        sp.set_defaults(func=func)
        return sp

    _module_parser(
        "apply-module",
        "Reconcile a module's declared source NAT (adds AND removes)",
        cmd_apply_module,
    )
    _module_parser(
        "delete-module", "Remove every source-NAT rule a module owns", cmd_delete_module
    )
    _module_parser(
        "verify-module",
        "Assert a module's rules are declared, live AND enforced",
        cmd_verify_module,
    )

    # validate — offline, no firewall contact
    validate_parser = subparsers.add_parser(
        "validate",
        parents=[gp],
        help="Check zones.json R1: snat-allowed-from subset of pinhole-allowed-from",
    )
    validate_parser.add_argument(
        "--zones-file",
        default=None,
        help="Path to zones.json (default: the deployed file, resolved)",
    )
    validate_parser.set_defaults(func=cmd_validate)


    args = parse_with_globals(parser, {
        "firewall": "firewall.mgmt.internal",
        "port": None,
        "credential_file": None,
        "no_ssl_verify": False,
        "debug": False,
        "json": False,
    })

    if not args.command:
        parser.print_help()
        return 1

    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
