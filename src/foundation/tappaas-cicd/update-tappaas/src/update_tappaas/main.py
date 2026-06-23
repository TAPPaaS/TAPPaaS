#!/usr/bin/env python3
"""TAPPaaS update scheduler - updates all foundation modules then app modules.

Output goes through Python's `logging` module. When invoked by systemd (timer
or `systemctl start`), records carry `<N>` priority prefixes that
systemd-journald maps to syslog severities — Promtail then surfaces them as
the `severity` label in Loki, so LogQL queries like
`{unit="update-tappaas.service", severity="err"}` work.

When invoked interactively (no `JOURNAL_STREAM`/`INVOCATION_ID` in env), the
prefixes are suppressed so `--dry-run` output stays human-readable.
"""

import argparse
import json
import logging
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

CONFIG_PATH = Path("/home/tappaas/config/site.json")
CONFIG_DIR = Path("/home/tappaas/config")
UPDATE_MODULE_CMD = "/home/tappaas/bin/update-module.sh"

# Foundation modules in their required update order
FOUNDATION_MODULES = [
    "cluster",       # Proxmox nodes (apt update/upgrade + file distribution)
    "tappaas-cicd",  # Mothership VM
    "templates",     # NixOS/Debian VM templates (config: templates.json)
    "network",       # OPNsense network module (routing/DNS/DHCP/NAT/firewall rules/proxy)
    "backup",        # Proxmox Backup Server
    "identity",      # Authentik identity provider
    "logging",       # Loki/Grafana/Promtail
]

# ADR-007 P8 back-compat: the "firewall" module was renamed to "network". A fresh
# install deploys config/network.json; a not-yet-migrated live system still has
# config/firewall.json. Map each canonical foundation name to the legacy name its
# deployed config may use, so such a system is still recognised and updated in the
# correct foundation slot (zero live change required — the host rename is deferred).
FOUNDATION_LEGACY_NAMES = {
    "network": "firewall",
}


def deployed_foundation_name(module: str) -> str | None:
    """Return the deployed config name for a canonical foundation module.

    Prefers the canonical name (e.g. network.json); falls back to the legacy
    name (e.g. firewall.json) for systems not yet migrated. Returns None when
    neither config file exists (module not installed).
    """
    if (CONFIG_DIR / f"{module}.json").exists():
        return module
    legacy = FOUNDATION_LEGACY_NAMES.get(module)
    if legacy and (CONFIG_DIR / f"{legacy}.json").exists():
        return legacy
    return None

# Config JSONs that are not modules (system/foundation files in config/)
NON_MODULE_JSONS = {
    "configuration.json",   # retired (kept for back-compat with old installs)
    "site.json",
    "zones.json",
    "zones.json.orig",
    "zones.rename.json",
    "cert-refids.json",
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


# ── Logging setup ────────────────────────────────────────────────────

UNDER_SYSTEMD = bool(os.environ.get("JOURNAL_STREAM") or os.environ.get("INVOCATION_ID"))


class SystemdPriorityFormatter(logging.Formatter):
    """Prefix records with `<N>` codes journald reads as syslog severity.

    Only applied when running under systemd (so interactive `--dry-run` stays
    readable).
    """

    PRIORITY = {
        logging.DEBUG:    "<7>",
        logging.INFO:     "<6>",
        logging.WARNING:  "<4>",
        logging.ERROR:    "<3>",
        logging.CRITICAL: "<2>",
    }

    def format(self, record: logging.LogRecord) -> str:
        body = super().format(record)
        if UNDER_SYSTEMD:
            return self.PRIORITY.get(record.levelno, "<6>") + body
        return body


def setup_logging() -> None:
    handler = logging.StreamHandler(stream=sys.stdout)
    handler.setFormatter(SystemdPriorityFormatter("%(message)s"))
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.handlers.clear()
    root.addHandler(handler)


log = logging.getLogger("update-tappaas")


# ── Config / schedule ────────────────────────────────────────────────


def load_config() -> dict:
    """Load the TAPPaaS configuration file."""
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        log.error("Error loading configuration: %s", e)
        return {}


def parse_schedule(schedule: list) -> tuple[str, int | None, int]:
    """Parse updateSchedule list into (frequency, weekday, hour)."""
    if not schedule or len(schedule) < 3:
        return ("daily", None, 2)

    frequency = schedule[0].lower()
    weekday_str = schedule[1].lower() if schedule[1] else None
    hour = int(schedule[2]) if schedule[2] is not None else 2

    weekday = WEEKDAYS.get(weekday_str) if weekday_str else None

    return (frequency, weekday, hour)


def should_update_now(config: dict, current_hour: int) -> bool:
    """Decide whether updates should run based on the global updateSchedule."""
    # site.json is flat (ADR-007): .updateSchedule (was .tappaas.updateSchedule).
    schedule = config.get("updateSchedule", [])

    frequency, scheduled_weekday, scheduled_hour = parse_schedule(schedule)

    if frequency == "none":
        log.info("Updates disabled (frequency=none), skipping")
        return False

    today = datetime.now()
    current_weekday = today.weekday()
    day_of_month = today.day

    if current_hour != scheduled_hour:
        log.info(
            "Scheduled for hour %d, current hour is %d, skipping",
            scheduled_hour, current_hour,
        )
        return False

    if frequency == "daily":
        log.info("Daily schedule at hour %d — running updates", scheduled_hour)
        return True

    if frequency == "weekly":
        if scheduled_weekday is None:
            log.warning("Weekly schedule but no weekday specified, skipping")
            return False

        weekday_name = list(WEEKDAYS.keys())[scheduled_weekday].capitalize()
        if current_weekday == scheduled_weekday:
            log.info("Weekly schedule on %s — running updates", weekday_name)
            return True
        current_day_name = list(WEEKDAYS.keys())[current_weekday].capitalize()
        log.info(
            "Weekly schedule on %s, today is %s, skipping",
            weekday_name, current_day_name,
        )
        return False

    if frequency == "monthly":
        if scheduled_weekday is None:
            log.warning("Monthly schedule but no weekday specified, skipping")
            return False

        weekday_name = list(WEEKDAYS.keys())[scheduled_weekday].capitalize()

        if day_of_month > 7:
            log.info(
                "Monthly schedule, day %d is not in the first week, skipping",
                day_of_month,
            )
            return False

        if current_weekday == scheduled_weekday:
            log.info("Monthly schedule on the first %s — running updates", weekday_name)
            return True

        current_day_name = list(WEEKDAYS.keys())[current_weekday].capitalize()
        log.info(
            "Monthly schedule on %s, today is %s, skipping",
            weekday_name, current_day_name,
        )
        return False

    log.warning("Unknown frequency %r, skipping", frequency)
    return False


# ── Module discovery / ordering ──────────────────────────────────────


def get_installed_apps() -> list[str]:
    """Get list of installed app modules (non-foundation)."""
    # Include legacy foundation names (e.g. firewall) so a not-yet-migrated
    # config/firewall.json is treated as the foundation network module, not an app.
    foundation_set = set(FOUNDATION_MODULES) | set(FOUNDATION_LEGACY_NAMES.values())
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
    """Get provider module names from a module's dependsOn field."""
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
    """Sort apps so dependsOn modules are updated before their dependents."""
    app_set = set(apps)

    deps = {}
    for app in apps:
        providers = get_module_dependencies(app)
        deps[app] = [p for p in providers if p in app_set]

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

    remaining = sorted(set(apps) - set(result))
    if remaining:
        log.warning(
            "Circular dependencies detected among: %s",
            ", ".join(remaining),
        )
        result.extend(remaining)

    return result


def update_module(module_name: str) -> bool:
    """Call update-module.sh to update a single module."""
    try:
        result = subprocess.run([UPDATE_MODULE_CMD, module_name], text=True)
        return result.returncode == 0
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        log.error("Error running update-module.sh for %s: %s", module_name, e)
        return False


# ── Phase 3: cluster node reboot pass (issue #275) ───────────────────


def reboot_cluster_script() -> Path | None:
    """Resolve cluster/reboot-cluster.sh from the installed cluster module."""
    try:
        with open(CONFIG_DIR / "cluster.json") as f:
            location = json.load(f).get("location", "")
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    if not location:
        return None
    script = Path(location) / "reboot-cluster.sh"
    return script if script.is_file() else None


def reboot_pass(automatic_reboot: bool, dry_run: bool) -> bool:
    """Run the controlled node reboot pass after all module updates.

    Reboots Proxmox nodes that have a pending kernel upgrade (one at a time,
    quorum-checked, cicd host last, abort on failure). Gated by
    tappaas.automaticReboot: when false, reboot-cluster.sh only reports which
    nodes are pending. Returns True on success (or nothing to do).
    """
    script = reboot_cluster_script()
    if script is None:
        log.warning("reboot-cluster.sh not found (cluster module location?) — skipping reboot pass")
        return True

    # --dry-run previews; --execute acts. When automaticReboot is false the
    # script itself only reports pending nodes, so --execute is still safe.
    mode = "--dry-run" if (dry_run or not automatic_reboot) else "--execute"
    try:
        result = subprocess.run([str(script), mode], text=True)
        return result.returncode == 0
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        log.error("Error running reboot-cluster.sh: %s", e)
        return False


# ── Main ─────────────────────────────────────────────────────────────


def main():
    setup_logging()

    parser = argparse.ArgumentParser(
        description="TAPPaaS update scheduler - updates foundation and app modules across all nodes"
    )
    parser.add_argument(
        "--force", action="store_true",
        help="Force update regardless of schedule",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show what would be updated without actually running updates",
    )
    args = parser.parse_args()

    now = datetime.now()
    current_hour = now.hour
    start_time = now.strftime("%Y-%m-%d %H:%M:%S")
    log.info("update-tappaas started: %s", start_time)

    config = load_config()
    if not config:
        log.error("Could not load configuration — aborting")
        sys.exit(1)

    log.info("Checking update schedule")
    if not args.force and not should_update_now(config, current_hour):
        log.info("Not scheduled for update at this time")
        sys.exit(0)

    apps = get_installed_apps()
    sorted_apps = topological_sort(apps)

    # Resolve each canonical foundation module to its deployed config name,
    # honouring the ADR-007 P8 legacy alias (network → firewall). update-module.sh
    # is invoked with the deployed name so a not-yet-migrated firewall.json updates
    # correctly in the network slot.
    installed_foundation = [
        name
        for m in FOUNDATION_MODULES
        if (name := deployed_foundation_name(m)) is not None
    ]

    # automaticReboot (default true) gates the Phase 3 node reboot pass.
    # site.json is flat (ADR-007): .automaticReboot (was .tappaas.automaticReboot).
    automatic_reboot = config.get("automaticReboot", True)

    # Dry run: show the update plan
    if args.dry_run:
        log.info("=== DRY RUN MODE ===")
        log.info("Phase 1 - Foundation update order:")
        for i, mod in enumerate(installed_foundation, 1):
            log.info("  %d. update-module.sh %s", i, mod)
        skipped = [m for m in FOUNDATION_MODULES if deployed_foundation_name(m) is None]
        if skipped:
            log.info("  (not installed: %s)", ", ".join(skipped))
        log.info("Phase 2 - App update order (%d module(s)):", len(sorted_apps))
        if sorted_apps:
            for i, app in enumerate(sorted_apps, 1):
                dep_providers = get_module_dependencies(app)
                dep_str = f" (depends on: {', '.join(dep_providers)})" if dep_providers else ""
                log.info("  %d. update-module.sh %s%s", i, app, dep_str)
        else:
            log.info("  (no app modules installed)")
        log.info("Phase 3 - Node reboot pass (automaticReboot=%s):", automatic_reboot)
        reboot_pass(automatic_reboot, dry_run=True)
        log.info("To run these updates: update-tappaas --force")
        sys.exit(0)

    failed_modules = []

    # Phase 1: Foundation modules in fixed order
    log.info("=" * 60)
    log.info("Phase 1: Updating foundation modules")
    log.info("=" * 60)

    for i, module in enumerate(installed_foundation, 1):
        log.info("[%d/%d] Updating %s", i, len(installed_foundation), module)
        if not update_module(module):
            log.error("FAILED: %s", module)
            failed_modules.append(module)

    # Phase 2: App modules in dependency order
    log.info("=" * 60)
    log.info("Phase 2: Updating app modules")
    log.info("=" * 60)

    if sorted_apps:
        for i, app in enumerate(sorted_apps, 1):
            log.info("[%d/%d] Updating %s", i, len(sorted_apps), app)
            if not update_module(app):
                log.error("FAILED: %s", app)
                failed_modules.append(app)
    else:
        log.info("No app modules found to update")

    # Phase 3: controlled node reboot pass (issue #275)
    log.info("=" * 60)
    log.info("Phase 3: Node reboot pass (automaticReboot=%s)", automatic_reboot)
    log.info("=" * 60)
    reboot_ok = reboot_pass(automatic_reboot, dry_run=False)
    if not reboot_ok:
        log.error("FAILED: node reboot pass")

    # Summary
    end_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    total = len(installed_foundation) + len(sorted_apps)
    succeeded = total - len(failed_modules)

    log.info("=" * 60)
    log.info(
        "update-tappaas completed: %s | total=%d succeeded=%d failed=%d reboot=%s",
        end_time, total, succeeded, len(failed_modules),
        "ok" if reboot_ok else "failed",
    )

    if failed_modules or not reboot_ok:
        if failed_modules:
            log.error("Failed modules: %s", ", ".join(failed_modules))
        sys.exit(1)

    log.info("All modules updated successfully")


if __name__ == "__main__":
    main()
