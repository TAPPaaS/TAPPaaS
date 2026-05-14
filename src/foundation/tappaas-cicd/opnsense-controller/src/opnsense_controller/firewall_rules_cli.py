#!/usr/bin/env python3
"""Module Firewall Rules Management CLI for TAPPaaS.

This module provides a dedicated CLI for managing per-module firewall
rules on OPNsense. It is the command-line front end for
firewall_rules_manager.FirewallRulesManager and is invoked by the
firewall:firewall service scripts (install/update/delete/test-service.sh).

It is the firewall-rules analogue of caddy_cli.py (firewall:proxy).
"""

import argparse
import json
import sys

from .config import Config
from .firewall_rules_manager import FirewallRulesManager, ValidationError
from .log import error, info


def add_rules(
    manager: FirewallRulesManager,
    module_name: str,
    check_mode: bool = False,
) -> bool:
    """Compile and apply a module's firewall rules.

    Args:
        manager: FirewallRulesManager instance.
        module_name: Name of the consuming module (e.g., vaultwarden).
        check_mode: If True, validate and compile but do not apply.

    Returns:
        True if successful.
    """
    try:
        spec = manager.load_module(module_name)
    except ValidationError as exc:
        error(str(exc))
        return False

    errors = manager.validate_module(spec)
    if errors:
        for e in errors:
            error(e)
        return False

    if check_mode:
        rules = manager.compile_module(spec)
        print(f"Would apply {len(rules)} rule(s) for {module_name} (dry-run):")
        for rule in rules:
            print(f"  [{rule.sequence}] {rule.description}")
        for alias_name in spec.aliases:
            print(f"  alias: {alias_name}")
        return True

    try:
        result = manager.add_rules(module_name)
    except (ValidationError, RuntimeError) as exc:
        error(str(exc))
        return False

    if "skipped" in result:
        print(f"Skipped {module_name}: {result['skipped']}")
        return True

    print(
        f"Applied {result['applied']} rule(s) and "
        f"{result.get('aliases', 0)} alias(es) for {module_name}"
    )
    return True


def reconcile(
    manager: FirewallRulesManager,
    module_name: str,
    check_mode: bool = False,
) -> bool:
    """Reconcile a module's firewall rules (diff, apply, prune orphans).

    Args:
        manager: FirewallRulesManager instance.
        module_name: Name of the consuming module.
        check_mode: If True, report the diff but do not apply.

    Returns:
        True if successful.
    """
    try:
        spec = manager.load_module(module_name)
    except ValidationError as exc:
        error(str(exc))
        return False

    errors = manager.validate_module(spec)
    if errors:
        for e in errors:
            error(e)
        return False

    if check_mode:
        desired = manager.compile_module(spec)
        desired_descriptions = {r.description for r in desired}
        live = manager.firewall.list_rules(f"TAPPaaS: {spec.vmname}")
        orphans = [r for r in live if r.description not in desired_descriptions]
        print(
            f"Would reconcile {module_name} (dry-run): "
            f"{len(desired)} desired, {len(orphans)} orphan(s) to prune"
        )
        return True

    try:
        result = manager.reconcile(module_name)
    except (ValidationError, RuntimeError) as exc:
        error(str(exc))
        return False

    print(
        f"Reconciled {module_name}: {result['applied']} rule(s) applied, "
        f"{result['deleted']} orphan(s) pruned"
    )
    return True


def remove_rules(
    manager: FirewallRulesManager,
    module_name: str,
    check_mode: bool = False,
) -> bool:
    """Remove all firewall rules and aliases owned by a module.

    Args:
        manager: FirewallRulesManager instance.
        module_name: Name of the consuming module.
        check_mode: If True, report what would be removed but do not remove.

    Returns:
        True if successful.
    """
    if check_mode:
        live = manager.list_rules(module_name)
        print(
            f"Would remove {len(live)} rule(s) for {module_name} (dry-run)"
        )
        return True

    try:
        result = manager.remove_rules(module_name)
    except RuntimeError as exc:
        error(str(exc))
        return False

    print(f"Removed {result['deleted']} rule(s) for {module_name}")
    return True


def verify_rules(manager: FirewallRulesManager, module_name: str) -> bool:
    """Verify that a module's declared rules exist in OPNsense.

    Args:
        manager: FirewallRulesManager instance.
        module_name: Name of the consuming module.

    Returns:
        True if all declared rules are present, False otherwise.
    """
    try:
        result = manager.verify_rules(module_name)
    except ValidationError as exc:
        error(str(exc))
        return False

    if "skipped" in result:
        print(f"Skipped {module_name}: {result['skipped']}")
        return True

    print(
        f"{module_name}: {result['found']}/{result['expected']} declared "
        f"rule(s) present"
    )
    if result["missing"]:
        for desc in result["missing"]:
            error(f"  missing: {desc}")
        return False
    return True


def list_rules(
    manager: FirewallRulesManager,
    module_name: str | None = None,
) -> bool:
    """List firewall rules created by this manager.

    Args:
        manager: FirewallRulesManager instance.
        module_name: Optional module name to filter by.

    Returns:
        True if successful.
    """
    rules = manager.list_rules(module_name)

    if not rules:
        scope = f"for {module_name}" if module_name else "from this manager"
        print(f"No firewall rules found {scope}")
        return True

    print(f"Firewall rules ({len(rules)}):")
    for rule in sorted(rules, key=lambda r: r.sequence or 0):
        status = "enabled" if rule.enabled else "disabled"
        seq = rule.sequence if rule.sequence is not None else "-"
        src_port = rule.source_port or "*"
        dst_port = rule.destination_port or "*"
        print(
            f"  [{seq}] {rule.action.upper()} {rule.protocol} "
            f"{rule.source_net}:{src_port} -> "
            f"{rule.destination_net}:{dst_port} "
            f"on {rule.interface} [{status}]  ({rule.description})"
        )
    return True


def main():
    """Main entry point for firewall-rules-manager CLI."""
    # Shared global options available before or after the subcommand.
    global_parser = argparse.ArgumentParser(add_help=False)
    global_parser.add_argument(
        "--firewall",
        default="firewall.mgmt.internal",
        help="Firewall IP/hostname (default: firewall.mgmt.internal)",
    )
    global_parser.add_argument(
        "--api-port",
        type=int,
        default=None,
        dest="api_port",
        help="OPNsense API port (default: auto-detect by probing 443, then 8443)",
    )
    global_parser.add_argument(
        "--credential-file",
        help="Path to credential file (default: $HOME/.opnsense-credentials.txt)",
    )
    global_parser.add_argument(
        "--config-dir",
        default="/home/tappaas/config",
        help="Directory with module JSONs and zones.json (default: /home/tappaas/config)",
    )
    global_parser.add_argument(
        "--no-ssl-verify",
        action="store_true",
        help="Disable SSL certificate verification",
    )
    global_parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable debug logging",
    )
    global_parser.add_argument(
        "--check-mode",
        action="store_true",
        help="Dry-run mode (don't make actual changes)",
    )
    global_parser.add_argument(
        "--json",
        action="store_true",
        help="Output in JSON format where supported",
    )

    parser = argparse.ArgumentParser(
        description="Per-Module Firewall Rules Management for OPNsense (firewall:firewall)",
        parents=[global_parser],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Compile and apply a module's firewall rules
  firewall-rules-manager add-rules vaultwarden --no-ssl-verify

  # Reconcile (diff against module.json, apply changes, prune orphans)
  firewall-rules-manager reconcile vaultwarden --no-ssl-verify

  # Remove all rules owned by a module
  firewall-rules-manager remove-rules vaultwarden --no-ssl-verify

  # Verify a module's declared rules are present
  firewall-rules-manager verify-rules vaultwarden --no-ssl-verify

  # List rules created by this manager (optionally filtered by module)
  firewall-rules-manager list-rules --module vaultwarden --no-ssl-verify

  # Dry-run: show what would change without applying
  firewall-rules-manager add-rules vaultwarden --check-mode
        """,
    )

    subparsers = parser.add_subparsers(dest="command", help="Command to execute")

    # add-rules
    add_parser = subparsers.add_parser(
        "add-rules", parents=[global_parser], help="Compile and apply a module's rules"
    )
    add_parser.add_argument("module", help="Module name (e.g., vaultwarden)")

    # reconcile
    reconcile_parser = subparsers.add_parser(
        "reconcile", parents=[global_parser],
        help="Diff against module.json, apply changes, prune orphans",
    )
    reconcile_parser.add_argument("module", help="Module name (e.g., vaultwarden)")

    # remove-rules
    remove_parser = subparsers.add_parser(
        "remove-rules", parents=[global_parser],
        help="Remove all rules and aliases owned by a module",
    )
    remove_parser.add_argument("module", help="Module name (e.g., vaultwarden)")

    # verify-rules
    verify_parser = subparsers.add_parser(
        "verify-rules", parents=[global_parser],
        help="Verify a module's declared rules are present",
    )
    verify_parser.add_argument("module", help="Module name (e.g., vaultwarden)")

    # list-rules
    list_parser = subparsers.add_parser(
        "list-rules", parents=[global_parser],
        help="List rules created by this manager",
    )
    list_parser.add_argument(
        "--module", help="Filter rules by module name"
    )

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Build configuration
    config_kwargs = {
        "firewall": args.firewall,
        "ssl_verify": not args.no_ssl_verify,
        "debug": args.debug,
    }
    if args.api_port is not None:
        config_kwargs["port"] = args.api_port
    if args.credential_file:
        config_kwargs["credential_file"] = args.credential_file

    try:
        config = Config(**config_kwargs)
    except ValueError as e:
        print(f"Configuration error: {e}", file=sys.stderr)
        sys.exit(1)

    # Execute command
    try:
        with FirewallRulesManager(config, config_dir=args.config_dir) as manager:
            if not manager.test_connection():
                print("ERROR: Cannot connect to OPNsense firewall", file=sys.stderr)
                sys.exit(1)

            if args.debug:
                print(f"Connected to OPNsense at {config.firewall}")

            success = False
            if args.command == "add-rules":
                success = add_rules(manager, args.module, args.check_mode)
            elif args.command == "reconcile":
                success = reconcile(manager, args.module, args.check_mode)
            elif args.command == "remove-rules":
                success = remove_rules(manager, args.module, args.check_mode)
            elif args.command == "verify-rules":
                success = verify_rules(manager, args.module)
            elif args.command == "list-rules":
                success = list_rules(manager, getattr(args, "module", None))

            sys.exit(0 if success else 1)

    except KeyboardInterrupt:
        print("\nInterrupted by user", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        if args.debug:
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
