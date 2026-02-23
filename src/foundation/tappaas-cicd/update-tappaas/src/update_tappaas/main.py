#!/usr/bin/env python3
"""TAPPaaS update scheduler - updates all foundation modules then app modules."""

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

CONFIG_PATH = Path("/home/tappaas/config/configuration.json")
CONFIG_DIR = Path("/home/tappaas/config")
UPDATE_MODULE_CMD = "/home/tappaas/bin/update-module.sh"

# Foundation modules in their required update order
FOUNDATION_MODULES = [
    "cluster",       # Proxmox nodes (apt update/upgrade + file distribution)
    "tappaas-cicd",  # Mothership VM
    "template",      # NixOS/Debian VM templates
    "firewall",      # OPNsense firewall
    "backup",        # Proxmox Backup Server
    "identity",      # Authentik identity provider
]

# Config JSONs that are not modules
NON_MODULE_JSONS = {
    "configuration.json",
    "zones.json",
    "module-fields.json",
}

WEEKDAYS = {
    "monday": 0,
    "tuesday": 1,
    "wednesday": 2,
    "thursday": 3,
    "friday": 4,
    "saturday": 5,
    "sunday": 6,
}


def load_config() -> dict:
    """Load the TAPPaaS configuration file."""
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"Error loading configuration: {e}")
        return {}


def parse_schedule(schedule: list) -> tuple[str, int | None, int]:
    """Parse updateSchedule list into (frequency, weekday, hour).

    Args:
        schedule: List of [frequency, weekday, hour]

    Returns:
        Tuple of (frequency, weekday_number, hour)
        weekday_number is None for daily frequency
    """
    if not schedule or len(schedule) < 3:
        return ("daily", None, 2)

    frequency = schedule[0].lower()
    weekday_str = schedule[1].lower() if schedule[1] else None
    hour = int(schedule[2]) if schedule[2] is not None else 2

    weekday = WEEKDAYS.get(weekday_str) if weekday_str else None

    return (frequency, weekday, hour)


def should_update_now(config: dict, current_hour: int) -> bool:
    """Determine if updates should run based on the global updateSchedule.

    Args:
        config: Full TAPPaaS configuration dict
        current_hour: Current hour of the day (0-23)

    Returns:
        True if updates should run now, False otherwise
    """
    tappaas_config = config.get("tappaas", {})
    schedule = tappaas_config.get("updateSchedule", [])

    frequency, scheduled_weekday, scheduled_hour = parse_schedule(schedule)

    if frequency == "none":
        print("  Updates disabled (frequency=none), skipping")
        return False

    today = datetime.now()
    current_weekday = today.weekday()
    day_of_month = today.day

    if current_hour != scheduled_hour:
        print(f"  Scheduled for hour {scheduled_hour}, current hour is {current_hour}, skipping")
        return False

    if frequency == "daily":
        print(f"  Daily schedule at hour {scheduled_hour}, running updates")
        return True

    elif frequency == "weekly":
        if scheduled_weekday is None:
            print("  Weekly schedule but no weekday specified, skipping")
            return False

        weekday_name = list(WEEKDAYS.keys())[scheduled_weekday].capitalize()
        if current_weekday == scheduled_weekday:
            print(f"  Weekly schedule on {weekday_name}, running updates")
            return True
        else:
            current_day_name = list(WEEKDAYS.keys())[current_weekday].capitalize()
            print(f"  Weekly schedule on {weekday_name}, today is {current_day_name}, skipping")
            return False

    elif frequency == "monthly":
        if scheduled_weekday is None:
            print("  Monthly schedule but no weekday specified, skipping")
            return False

        weekday_name = list(WEEKDAYS.keys())[scheduled_weekday].capitalize()

        if day_of_month > 7:
            print(f"  Monthly schedule, day {day_of_month} is not in first week, skipping")
            return False

        if current_weekday == scheduled_weekday:
            print(f"  Monthly schedule on first {weekday_name}, running updates")
            return True
        else:
            current_day_name = list(WEEKDAYS.keys())[current_weekday].capitalize()
            print(f"  Monthly schedule on {weekday_name}, today is {current_day_name}, skipping")
            return False

    else:
        print(f"  Unknown frequency '{frequency}', skipping")
        return False


def get_installed_apps() -> list[str]:
    """Get list of installed app modules (non-foundation).

    Reads JSON files in CONFIG_DIR, excluding foundation modules and
    non-module config files.
    """
    foundation_set = set(FOUNDATION_MODULES)
    apps = []

    for json_file in CONFIG_DIR.glob("*.json"):
        if json_file.name in NON_MODULE_JSONS:
            continue
        module_name = json_file.stem
        if module_name in foundation_set:
            continue
        apps.append(module_name)

    return apps


def get_module_dependencies(module_name: str) -> list[str]:
    """Get provider module names from a module's dependsOn field.

    Parses entries like "cluster:vm" to extract "cluster" as a dependency.
    """
    json_path = CONFIG_DIR / f"{module_name}.json"
    try:
        with open(json_path) as f:
            config = json.load(f)
        depends_on = config.get("dependsOn", [])
        providers = set()
        for dep in depends_on:
            if ":" in dep:
                providers.add(dep.split(":")[0])
            else:
                providers.add(dep)
        return sorted(providers)
    except (FileNotFoundError, json.JSONDecodeError):
        return []


def topological_sort(apps: list[str]) -> list[str]:
    """Sort apps so dependsOn modules are updated before their dependents.

    Only considers dependencies between apps in the list.
    Foundation dependencies are ignored (already updated in phase 1).
    Ties are broken alphabetically for deterministic ordering.
    """
    app_set = set(apps)

    # Build dependency graph: app -> list of apps it depends on (within app_set)
    deps = {}
    for app in apps:
        providers = get_module_dependencies(app)
        deps[app] = [p for p in providers if p in app_set]

    # Kahn's algorithm
    in_degree = {app: len(deps[app]) for app in apps}
    dependents = {app: [] for app in apps}
    for app, app_deps in deps.items():
        for dep in app_deps:
            dependents[dep].append(app)

    queue = sorted([app for app in apps if in_degree[app] == 0])
    result = []

    while queue:
        node = queue.pop(0)
        result.append(node)
        for dependent in sorted(dependents[node]):
            in_degree[dependent] -= 1
            if in_degree[dependent] == 0:
                queue.append(dependent)
                queue.sort()

    # Handle circular dependencies by appending remaining nodes
    remaining = sorted(set(apps) - set(result))
    if remaining:
        print(f"  Warning: Circular dependencies detected among: {', '.join(remaining)}")
        result.extend(remaining)

    return result


def update_module(module_name: str) -> bool:
    """Call update-module.sh to update a single module."""
    try:
        result = subprocess.run(
            [UPDATE_MODULE_CMD, module_name],
            text=True
        )
        return result.returncode == 0
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        print(f"Error running update-module.sh for {module_name}: {e}")
        return False


def main():
    """Main entry point for update-tappaas."""
    parser = argparse.ArgumentParser(
        description="TAPPaaS update scheduler - updates foundation and app modules across all nodes"
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Force update regardless of schedule"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be updated without actually running updates"
    )
    args = parser.parse_args()

    now = datetime.now()
    current_hour = now.hour
    start_time = now.strftime("%Y-%m-%d %H:%M:%S")
    print(f"update-tappaas started: {start_time}")

    # Load configuration
    config = load_config()
    if not config:
        print("Error: Could not load configuration")
        sys.exit(1)

    # Check schedule
    print("\nChecking update schedule:")
    if not args.force and not should_update_now(config, current_hour):
        print("\nNot scheduled for update at this time")
        sys.exit(0)

    # Discover installed apps and sort by dependencies
    apps = get_installed_apps()
    sorted_apps = topological_sort(apps)

    # Determine which foundation modules are installed
    installed_foundation = [
        m for m in FOUNDATION_MODULES
        if (CONFIG_DIR / f"{m}.json").exists()
    ]

    # Dry run: show the update plan
    if args.dry_run:
        print("\n=== DRY RUN MODE ===")
        print("\nPhase 1 - Foundation update order:")
        for i, mod in enumerate(installed_foundation, 1):
            print(f"  {i}. update-module.sh {mod}")
        skipped = [m for m in FOUNDATION_MODULES if m not in installed_foundation]
        if skipped:
            print(f"  (not installed: {', '.join(skipped)})")
        print(f"\nPhase 2 - App update order ({len(sorted_apps)} module(s)):")
        if sorted_apps:
            for i, app in enumerate(sorted_apps, 1):
                dep_providers = get_module_dependencies(app)
                dep_str = f" (depends on: {', '.join(dep_providers)})" if dep_providers else ""
                print(f"  {i}. update-module.sh {app}{dep_str}")
        else:
            print("  (no app modules installed)")
        print("\nTo run these updates:")
        print("  update-tappaas --force")
        sys.exit(0)

    failed_modules = []

    # Phase 1: Foundation modules in fixed order
    print("\n" + "=" * 60)
    print("Phase 1: Updating foundation modules")
    print("=" * 60)

    for i, module in enumerate(installed_foundation, 1):
        print(f"\n[{i}/{len(installed_foundation)}] Updating {module}...")
        if not update_module(module):
            print(f"FAILED: {module}")
            failed_modules.append(module)

    # Phase 2: App modules in dependency order
    print("\n" + "=" * 60)
    print("Phase 2: Updating app modules")
    print("=" * 60)

    if sorted_apps:
        for i, app in enumerate(sorted_apps, 1):
            print(f"\n[{i}/{len(sorted_apps)}] Updating {app}...")
            if not update_module(app):
                print(f"FAILED: {app}")
                failed_modules.append(app)
    else:
        print("\nNo app modules found to update")

    # Summary
    end_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    total = len(installed_foundation) + len(sorted_apps)
    succeeded = total - len(failed_modules)

    print("\n" + "=" * 60)
    print(f"update-tappaas completed: {end_time}")
    print(f"  Total modules: {total}  |  Succeeded: {succeeded}  |  Failed: {len(failed_modules)}")

    if failed_modules:
        print(f"  Failed: {', '.join(failed_modules)}")
        sys.exit(1)

    print("All modules updated successfully")


if __name__ == "__main__":
    main()
