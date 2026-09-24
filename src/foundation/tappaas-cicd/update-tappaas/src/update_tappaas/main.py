#!/usr/bin/env python3
"""TAPPaaS update scheduler - updates all foundation modules then app modules.

Output goes through Python's `logging` module. When invoked by systemd (timer
or `systemctl start`), records carry `<N>` priority prefixes that
systemd-journald maps to syslog severities — Alloy then surfaces them as
the `severity` label in Loki, so LogQL queries like
`{unit="update-tappaas.service", severity="err"}` work.

When invoked interactively (no `JOURNAL_STREAM`/`INVOCATION_ID` in env), the
prefixes are suppressed so `--dry-run` output stays human-readable.
"""

import argparse
import json
import logging
import os
import re
import socket
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

CONFIG_PATH = Path("/home/tappaas/config/site.json")
CONFIG_DIR = Path("/home/tappaas/config")
# Journal-free outcome of the last REAL sweep (#506). The hourly no-op run exits
# at the schedule gate before a sweep, so this file is never overwritten by a
# no-op — unlike the systemd unit's Result, which the no-op clobbers to success.
RESULT_PATH = CONFIG_DIR / "last-update-result.json"
# ADR-017 D3/D4: update-tappaas.service's prepare step leaves its markers and the
# claimed operator request in the unit's RuntimeDirectory; site-manager update
# writes the request to config/.update-request.json; config/.update-stage names
# the step a failed run stopped in, for the #651 notice.
RUN_DIR = Path(os.environ.get("RUNTIME_DIRECTORY", "/run/update-tappaas"))
REQUEST_PATH = CONFIG_DIR / ".update-request.json"
STAGE_PATH = CONFIG_DIR / ".update-stage"
REQUEST_MAX_AGE = 600
# The verb-aligned front door (ADR-007 #3/#5). `module module modify <m>` delegates
# to update-module.sh, so behaviour is unchanged — we just stop calling the script
# directly. Override for tests with MODULE_MANAGER_CMD.
MODULE_MANAGER_CMD = os.environ.get("MODULE_MANAGER_CMD", "/home/tappaas/bin/module-manager")
# unbound-manager, used only to capture deterministic evidence (the validator
# output) when the between-module check finds the resolver down (#516/#517).
# Override for tests with UNBOUND_MANAGER_CMD.
UNBOUND_MANAGER_CMD = os.environ.get("UNBOUND_MANAGER_CMD", "/home/tappaas/bin/unbound-manager")
# The mothership's self-refresh: pull the tracked repositories, relink ~/bin, and
# rebuild every compiled component. Run as Phase 0 — BEFORE any module is touched
# — because the control plane is not a module like the others, it is the thing
# running this sweep (#595). Invoked by repo path, not through ~/bin: the run that
# first pulls this script is also the run that links it, so ~/bin cannot be
# assumed to have it yet. Override for tests with REFRESH_CONTROL_PLANE_CMD.
REFRESH_CONTROL_PLANE_CMD = os.environ.get(
    "REFRESH_CONTROL_PLANE_CMD",
    "/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/refresh-control-plane.sh",
)
# The config-migration runner (ADR-025 D2). The sweep never runs it — it runs in
# the same ExecStartPre chain, one step later — but --dry-run asks it what is
# pending, so an operator sees a migration before it happens (D6).
RUN_MIGRATIONS_CMD = os.environ.get(
    "RUN_MIGRATIONS_CMD",
    "/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/run-migrations.sh",
)
# refresh-control-plane.sh's "built, but some component group failed" exit code:
# the bins are STALE, not broken, so the sweep proceeds — loudly.
REFRESH_RC_STALE = 10

# Foundation modules in their required update order
FOUNDATION_MODULES = [
    "cluster",       # Proxmox nodes (apt update/upgrade + file distribution)
    "tappaas-cicd",  # Mothership VM
    "templates",     # NixOS/Debian VM templates (config: templates.json)
    "network",       # OPNsense network module (routing/DNS/DHCP/NAT/firewall rules/proxy)
    "backup",        # Proxmox Backup Server
    "identity",      # Authentik identity provider
    "logging",       # Loki/Grafana/Alloy
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
    # switch/AP controller runtime state — NOT modules (they have no vmname/kind).
    "switch-configuration-actual.json",
    "switch-configuration-desired.json",
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
    """Tag records [Info]/[Debug]/… like the bash helpers.

    Under systemd the `<N>` code journald reads as syslog severity goes in
    front as well; the label stays, because `site-manager update` follows the
    journal with `-o cat`, which shows no priority.
    """

    PRIORITY = {
        logging.DEBUG:    "<7>",
        logging.INFO:     "<6>",
        logging.WARNING:  "<4>",
        logging.ERROR:    "<3>",
        logging.CRITICAL: "<2>",
    }

    # Interactive: tag lines like the bash helpers ([Info]/[Warning]/…) so the
    # console is consistent across the update-tappaas driver and the scripts it calls.
    LABEL = {
        logging.DEBUG:    "[Debug]",
        logging.INFO:     "[Info]",
        logging.WARNING:  "[Warning]",
        logging.ERROR:    "[Error]",
        logging.CRITICAL: "[Fatal]",
    }

    # ANSI colors matching common-install-routines.sh so the label color is
    # identical whether a line comes from this driver or a bash script it calls:
    # Info=green, Debug=cyan, Warning=yellow, Error/Fatal=red.
    _CLEAR = "\033[m"
    LABEL_COLOR = {
        logging.DEBUG:    "\033[36m",      # cyan  (BL)
        logging.INFO:     "\033[32m",      # green (DGN)
        logging.WARNING:  "\033[33m",      # yellow (YW)
        logging.ERROR:    "\033[01;31m",   # red   (RD)
        logging.CRITICAL: "\033[01;31m",   # red   (RD)
    }

    def format(self, record: logging.LogRecord) -> str:
        body = super().format(record)
        label = self.LABEL.get(record.levelno, "[Info]")
        color = self.LABEL_COLOR.get(record.levelno)
        # Colorize on a real TTY, and in the journal, where the bash steps of
        # the same unit write colored labels too; piped runs stay plain text.
        if color and (UNDER_SYSTEMD or sys.stdout.isatty()):
            label = f"{color}{label}{self._CLEAR}"
        prio = self.PRIORITY.get(record.levelno, "<6>") if UNDER_SYSTEMD else ""
        return f"{prio}{label} {body}"


def setup_logging() -> None:
    handler = logging.StreamHandler(stream=sys.stdout)
    handler.setFormatter(SystemdPriorityFormatter("%(message)s"))
    root = logging.getLogger()
    # TAPPAAS_DEBUG=1 shows [Debug], as it does for the bash helpers.
    root.setLevel(logging.DEBUG if os.environ.get("TAPPAAS_DEBUG") == "1" else logging.INFO)
    root.handlers.clear()
    root.addHandler(handler)


log = logging.getLogger("update-tappaas")


_ANSI = re.compile(r"\x1b\[[0-9;]*m")
_LABELLED = {"[Warning]": logging.WARNING, "[Error]": logging.ERROR, "[Fatal]": logging.CRITICAL}


def relog_output(text: str) -> None:
    """Relog a manager's human output at the sweep's levels.

    The TS managers' info() carries no label, so their lines arrive bare. Here
    a line's own [Warning]/[Error] label is kept, action lines (indented) and
    the closing summary go to [Info], and the rest (headers, blank lines) is
    [Debug].
    """
    lines = [_ANSI.sub("", ln).rstrip() for ln in (text or "").splitlines()]
    lines = [ln for ln in lines if ln.strip()]
    for i, ln in enumerate(lines):
        label, _, rest = ln.partition(" ")
        if label in _LABELLED:
            log.log(_LABELLED[label], "  %s", rest)
        elif ln.startswith(" ") or i == len(lines) - 1:
            log.info("  %s", ln.strip())
        else:
            log.debug("  %s", ln)


# ── Config / schedule ────────────────────────────────────────────────


def load_config() -> dict:
    """Load the TAPPaaS configuration file."""
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        log.error("Error loading configuration: %s", e)
        return {}


def ensure_default_environment(
    config: dict, dry_run: bool, config_path: Path = CONFIG_PATH
) -> None:
    """Backfill a missing site.json .defaultEnvironment (ADR-007d #426).

    #426 made defaultEnvironment a required field, but a site.json written
    before it — the schema migration only fires on the configuration.json →
    site.json conversion, so an already-migrated file is skipped — lacks it and
    fails the tappaas-cicd post-update schema validation. Mirror
    create-site.sh: default it to .owner (falling
    back to .name). Mutates `config` in place and rewrites site.json. Idempotent
    — a no-op once the field is present.
    """
    if str(config.get("defaultEnvironment") or "").strip():
        return
    value = str(config.get("owner") or config.get("name") or "").strip()
    if not value:
        log.warning(
            "site.json missing defaultEnvironment and no owner/name to derive it "
            "from — leaving as-is (fix manually)"
        )
        return
    if dry_run:
        log.info(
            "Phase 0 - would backfill site.json defaultEnvironment=%s (was missing)",
            value,
        )
        return
    config["defaultEnvironment"] = value
    try:
        with open(config_path, "w") as f:
            json.dump(config, f, indent=2)
            f.write("\n")
        log.info(
            "Backfilled site.json defaultEnvironment=%s (was missing; ADR-007d #426)",
            value,
        )
    except OSError as e:
        log.warning(
            "Could not write backfilled defaultEnvironment to %s: %s — continuing",
            config_path, e,
        )


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


# The workload kinds a module authors (ADR-022f D1) — as lib/ts/src/module-discovery.ts.
WORKLOAD_KINDS = {"vm", "lxc", "machine", "application", "device"}
# Off-site peer configs (ADR-012 §1.4): peers, not modules.
PEER_PREFIXES = ("pull-", "remote-", "receive-")


def _is_module_json(path) -> bool:
    """True if a config/*.json is an actual deployed MODULE, not a co-located
    state file — the SAME shape rule as module-manager's discovery
    (lib/ts/src/module-discovery.ts, #544): a workload `kind`, or the legacy
    `kind: "module"` marker, or a module-shaped field (dependsOn / integratesWith
    / provides / moduleSource, or its pre-#609 name location). A `vmname` is kept
    as a last fallback for configs older than all of those.

    It used to be `kind == "module" or vmname` only. #611 retired the marker and a
    `kind: machine` instance has no vmname, so every machine — a debianhost, a
    pvehost — silently fell out of the sweep (found 2026-09-19). A satellite is a
    machine module too, swept while managed (ADR-010 §8.4)."""
    if path.name in NON_MODULE_JSONS or path.name.startswith(PEER_PREFIXES):
        return False
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return False
    if not isinstance(data, dict):
        return False
    kind = data.get("kind")
    if kind == "module" or kind in WORKLOAD_KINDS:
        return True
    if any(isinstance(data.get(f), list) for f in ("dependsOn", "integratesWith", "provides")):
        return True
    if any(isinstance(data.get(f), str) and data.get(f) for f in ("moduleSource", "location")):
        return True
    return bool(data.get("vmname"))


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
        # Robust guard: only real modules (kind=module / has vmname), so state
        # files that slipped past NON_MODULE_JSONS are never treated as apps.
        if not _is_module_json(json_file):
            continue
        apps.append(module_name)
    return apps


def _module_config(module_name: str) -> dict:
    try:
        with open(CONFIG_DIR / f"{module_name}.json") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def foundation_machines(modules: list[str]) -> list[str]:
    """The discovered modules that are foundation machines, in sweep order.

    A machine instance (kind: machine, tier: foundation) is named after the host,
    not its module — tappaas1 is an instance of pvehost (ADR-026 D6) — so it never
    matches a FOUNDATION_MODULES name and used to fall through to the app phase.
    Its module says foundation; the sweep runs it right after `cluster`. Cluster
    nodes (pvehost) go first, then other machines (a debianhost may carry the
    PBS, so it must precede `backup`), each group by name."""
    def is_pvehost(name: str) -> bool:
        return os.path.basename(str(_module_config(name).get("moduleSource") or "").rstrip("/")) == "pvehost"
    machines = [
        m for m in modules
        if _module_config(m).get("kind") == "machine" and _module_config(m).get("tier") == "foundation"
    ]
    return sorted(machines, key=lambda m: (not is_pvehost(m), m))


def foundation_order(installed: list[str], machines: list[str]) -> list[str]:
    """Insert the foundation machines right after `cluster` (at the front when no
    cluster module is deployed)."""
    if "cluster" in installed:
        i = installed.index("cluster") + 1
        return installed[:i] + machines + installed[i:]
    return machines + installed


# ── Update lifecycle membership (#441) ───────────────────────────────
#
# Statuses that take a module OUT of the update sweep:
#   archived (#215) — delete-module.sh --archive removed the VM but kept the
#                     config (and its PBS backups) so the module stays restorable.
#   external (#216) — a guest managed OUTSIDE TAPPaaS; per module-fields.json,
#                     "no install/update/test/delete lifecycle applies".
#
#   management: unmanaged (ADR-022g) — registered, no lifecycle: a locked-down
#                     satellite patches itself and admits no login from home
#                     (ADR-010 §8.4.4). What takes it out is the field, not
#                     what the module is.
#
# All keep `kind`/`vmname`, so the module selectors above still match them and
# they used to enter Phase 1/2, where the pre-update snapshot found no VM and the
# pre-update test then aborted the module with exit 2 — counting an intentionally
# decommissioned module as a sweep FAILURE.
#
# `Deprecated` is deliberately NOT here: unmaintained is not decommissioned. Its
# VM is still running and still needs its OS patches.
NON_LIFECYCLE_STATUSES = {"archived", "external"}


def module_status(module_name: str) -> str:
    """Return a module's `.status`, lowercased. '' when absent or unreadable."""
    try:
        with open(CONFIG_DIR / f"{module_name}.json") as f:
            return str(json.load(f).get("status") or "").strip().lower()
    except (OSError, ValueError):
        return ""


def module_management(module_name: str) -> str:
    """Return a module's `.management`, lowercased. '' when absent (= managed)."""
    try:
        with open(CONFIG_DIR / f"{module_name}.json") as f:
            return str(json.load(f).get("management") or "").strip().lower()
    except (OSError, ValueError):
        return ""


def partition_by_lifecycle(modules: list[str]) -> tuple[list[str], list[tuple[str, str]]]:
    """Split module names into (to_update, [(name, reason), ...] skipped), the
    reason being `status=<s>` or `management=unmanaged`.

    Status matching is case-insensitive: module-fields.json spells the lifecycle
    values lowercase (archived/external) but the development ones capitalised
    (Production/Testing/…), so neither casing can be assumed.
    """
    active: list[str] = []
    skipped: list[tuple[str, str]] = []
    for name in modules:
        status = module_status(name)
        if status in NON_LIFECYCLE_STATUSES:
            skipped.append((name, f"status={status}"))
        elif module_management(name) == "unmanaged":
            skipped.append((name, "management=unmanaged"))
        else:
            active.append(name)
    return active, skipped


def log_skipped(skipped: list[tuple[str, str]]) -> None:
    """Report modules out of the lifecycle. Skipping is visible, never silent — an
    operator reading the plan must still see that the module exists."""
    for name, reason in skipped:
        log.info("  (skipped: %s — %s, not in the update lifecycle)", name, reason)


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
        # Exclude self-references: a module may list its own provided
        # capability in dependsOn to sequence its per-service scripts (e.g.
        # alfen -> alfen:nat). That is not a scheduling edge — keeping it would
        # be a self-loop whose in-degree never reaches 0, falsely flagging the
        # module (and its dependents) as a cycle. dependsOn is left untouched in
        # get_module_dependencies, so per-service invocation still sees it. (#514)
        deps[app] = [p for p in providers if p in app_set and p != app]

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


# Disruptive changes a converge held back for want of authorization (ADR-020
# D8). Each provider prints a machine-parseable "DEFERRED: <module> <unit> …"
# line and still exits 0 — not applying a change is not a failure — so the sweep
# collects them and says so once at the end. Without that they would scroll past
# in a per-module log nobody reads, which is the same as not reporting them.
DEFERRED_CHANGES: list[str] = []
_DEFERRED_PREFIX = "DEFERRED:"

# Checks that failed before a module's update and still fail after it (#635).
# update-module.sh lets such an update succeed — it did not cause them — and
# prints one "TEST-WARN: <module>: …" line, kept apart from DEFERRED because the
# remedy is fixing what the check points at, not authorizing a reboot.
TEST_WARNINGS: list[str] = []
_TEST_WARN_PREFIX = "TEST-WARN:"


def update_module(module_name: str) -> bool:
    """Update a single module via `module-manager module modify` (which delegates
    to update-module.sh — same behaviour, through the verb-aligned front door).

    NOTE the absent --force. `update-tappaas --force` means "run the sweep NOW",
    a scheduling override; `module modify --force` AUTHORIZES DISRUPTION. Passing
    one as the other would let a routine hourly update reboot production guests,
    which is exactly the conflation ADR-020 D8 exists to prevent. Standing
    permission is expressed per module, by rebootOk, and honoured only because
    TAPPAAS_SCHEDULED_PASS is exported below.

    ADR-020 v0.10: `site-manager update --force` forwards `--force` to every
    module update — proceed past a fatally failed pre-update test or an
    archived/external status, and nothing else. Downtime is a separate lever,
    `--allow-disruption`, which opens the window for rebootOk modules
    (see disruption_window_open) and is never passed per module by the sweep."""
    args = [MODULE_MANAGER_CMD, "module", "update", module_name]
    if os.environ.get("TAPPAAS_MODULE_FORCE") == "1":
        args.append("--force")
    try:
        # Stream line by line: the operator watches this live. Capturing the
        # whole run and writing it afterwards left minutes of silence per module
        # and moved every stderr line to the end of its block; stderr is merged
        # so errors stay where they happened.
        with subprocess.Popen(args, text=True, bufsize=1,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as proc:
            assert proc.stdout is not None
            for line in proc.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
                for prefix, sink in ((_DEFERRED_PREFIX, DEFERRED_CHANGES),
                                     (_TEST_WARN_PREFIX, TEST_WARNINGS)):
                    idx = line.find(prefix)
                    if idx != -1:
                        sink.append(line[idx + len(prefix):].strip())
        return proc.returncode == 0
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        log.error("Error running 'module-manager module modify %s': %s", module_name, e)
        return False


def disruption_window_open(automatic_reboot: bool, scheduled: bool, allow_disruption: bool) -> bool:
    """May a module with rebootOk be disrupted in this sweep (ADR-020 v0.10 D8)?

    Yes for the scheduled run when the site accepts downtime in its window
    (automaticReboot, the same setting that gates the Phase 3 node reboots), and
    for an operator run with `site-manager update --allow-disruption`. A plain
    operator run opens no window, and neither does `--force` — that one only
    proceeds past a refusal. Either way only rebootOk modules are disrupted:
    overriding rebootOk:false is `module update <m> --allow-disruption`, typed
    for one module (#633)."""
    return allow_disruption or (scheduled and automatic_reboot)


def _read_json(path: Path) -> dict | None:
    try:
        with open(path) as f:
            value = json.load(f)
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


def claim_request() -> dict | None:
    """Claim site-manager update's one-shot request outside the new unit.

    Under the new unit (ADR-017 D3) the prepare step has already moved it into
    the RuntimeDirectory. Without that step — the old unit during the first
    activation, or a bare run — this run claims it itself, so a request is still
    used by exactly one run (ADR-017 Bootstrap)."""
    if not REQUEST_PATH.exists():
        return None
    try:
        age = time.time() - REQUEST_PATH.stat().st_mtime
        request = _read_json(REQUEST_PATH)
        REQUEST_PATH.unlink()
    except OSError:
        return None
    if age > REQUEST_MAX_AGE:
        log.warning("Discarding an operator request written %ds ago (older than %ds)",
                    int(age), REQUEST_MAX_AGE)
        return None
    return request


def run_context() -> dict:
    """Which path this run takes (ADR-017 D3, Bootstrap).

    "unit": started by update-tappaas.service after its prepare and rebuild
    steps — no schedule check and no Phase 0 here, the control-plane state comes
    from the prepare step. "legacy": the old unit or a bare run — R-1's
    behaviour, schedule gate and Phase 0 included, kept until the interim path
    goes."""
    if (RUN_DIR / "prepared").exists():
        try:
            control_plane = (RUN_DIR / "control-plane").read_text().strip() or "refreshed"
        except OSError:
            control_plane = "refreshed"
        return {"path": "unit", "request": _read_json(RUN_DIR / "request.json"),
                "control_plane": control_plane}
    return {"path": "legacy", "request": claim_request(), "control_plane": None}


def set_stage(stage: str | None) -> None:
    """Record the step a failed run stopped in (#651 notice); None clears it."""
    try:
        if stage is None:
            STAGE_PATH.unlink(missing_ok=True)
        else:
            STAGE_PATH.write_text(stage + "\n")
    except OSError:
        pass


# ── Between-module shared-dependency invariant (#517) ────────────────

# Every module reaches the same resolver, proxy and firewall through the same
# hooks. When one of those shared services dies mid-sweep the remaining modules
# fail one by one with different-looking messages — the run ends with dozens of
# failures that have one cause. Probing the shared dependencies BETWEEN modules
# lets the sweep name the boundary (the module whose update coincided with the
# outage) and stop, instead of reporting each dependent module's symptom
# separately. IP literals only: the probe must never depend on the resolver it
# is checking (mirrors zone_manager's pre/post-flight checks). Override the
# firewall mgmt IP for a relocated site with TAPPAAS_FIREWALL_MGMT_IP.
FIREWALL_MGMT_IP = os.environ.get("TAPPAAS_FIREWALL_MGMT_IP", "10.0.0.1")


def _probe_unbound_dns(retries: int = 1, delay: float = 2.0) -> bool:
    """True if Unbound answers a UDP query on <mgmt-ip>:53. Retries tolerate a
    resolver still stabilising right after the network module reloads it (the
    same reason zone_manager's _check_unbound_dns and update.sh's dig retry)."""
    # Minimal DNS query for firewall.mgmt.internal A (ID 0x1234, standard query).
    query = (
        b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
        b"\x08firewall\x04mgmt\x08internal\x00\x00\x01\x00\x01"
    )
    attempts = max(1, retries)
    for attempt in range(attempts):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.settimeout(2.0)
            sock.sendto(query, (FIREWALL_MGMT_IP, 53))
            response, _ = sock.recvfrom(512)
            if len(response) >= 12:  # a DNS header at minimum
                return True
        except socket.timeout:
            pass
        except OSError:
            return False
        finally:
            sock.close()
        if attempt < attempts - 1:
            time.sleep(delay)
    return False


def _probe_tcp(port: int, retries: int = 1, delay: float = 2.0, timeout: float = 3.0) -> bool:
    """True if a TCP connection to <mgmt-ip>:<port> opens. Retries absorb a
    brief OPNsense API bounce during the network module's own reconfigure."""
    for attempt in range(max(1, retries)):
        try:
            with socket.create_connection((FIREWALL_MGMT_IP, port), timeout=timeout):
                return True
        except OSError:
            pass
        if attempt < retries - 1:
            time.sleep(delay)
    return False


def _opnsense_reachable(retries: int = 1) -> bool:
    return _probe_tcp(443, retries=retries) or _probe_tcp(8443, retries=retries)


def check_shared_dependencies() -> list[dict]:
    """Probe the shared services a mid-sweep outage cascades from.

    Returns a list of failures (empty list == healthy); each is a dict with
    `dependency` and `detail`. Kept deliberately small: the resolver (whose
    death silently fails every .internal name, #516/#517) and OPNsense API
    reachability (the "Cannot reach OPNsense" cascade).

    Fast path first: single-attempt probes, so a healthy sweep pays ~no latency
    between modules. Only when something looks down do we re-probe with retries
    — that absorbs the transient reload the network module causes during its own
    update before declaring a real outage (avoids a false boundary)."""
    dns_ok = _probe_unbound_dns()
    opn_ok = _opnsense_reachable()
    if dns_ok and opn_ok:
        return []
    failures: list[dict] = []
    if not dns_ok and not _probe_unbound_dns(retries=5, delay=2.0):
        failures.append({
            "dependency": "unbound-dns",
            "detail": f"Unbound DNS ({FIREWALL_MGMT_IP}:53) is not answering",
        })
    if not opn_ok and not _opnsense_reachable(retries=3):
        failures.append({
            "dependency": "opnsense",
            "detail": f"OPNsense at {FIREWALL_MGMT_IP} unreachable on 443/8443",
        })
    return failures


def collect_dependency_evidence(failures: list[dict]) -> dict:
    """Best-effort, deterministic evidence for a shared-dependency outage.

    For a dead resolver, run the Unbound validator on the firewall
    (`unbound-manager checkconf`, which ssh-es by IP) to capture the exact fatal
    config line — e.g. "local-data in redirect zone must reside at top of zone"
    (#474) — far more actionable than the rotated firewall log (#516/#517).
    Returns a dict of evidence (empty when there is nothing to collect); never
    raises, so a missing/slow validator never derails the sweep summary."""
    evidence: dict = {}
    if any(f.get("dependency") == "unbound-dns" for f in failures):
        try:
            r = subprocess.run([UNBOUND_MANAGER_CMD, "checkconf"],
                               text=True, capture_output=True, timeout=30)
            out = ((r.stdout or "") + (r.stderr or "")).strip()
            if out:
                evidence["unbound_checkconf"] = out
        except (subprocess.SubprocessError, FileNotFoundError, OSError) as e:
            evidence["unbound_checkconf"] = f"could not run unbound-manager checkconf: {e}"
    return evidence


def run_update_phase(
    modules: list[str], phase_label: str, failed_modules: list[str], dep: dict
) -> list[str]:
    """Update each module in order, asserting the shared-dependency invariant
    between modules (#517).

    `dep` is the shared mutable dependency-state carried across both phases:
    {"down": bool, "culprit": str|None, "last_good": str|None, "failures": list}.
    On the first probe failure the boundary is recorded (culprit = the module
    just updated, last_good = the previous healthy module) and the phase HALTS:
    the remaining modules reach the same downed service and would only add
    same-cause noise. Returns the modules NOT attempted (already-down entry, or
    everything after the boundary)."""
    not_attempted: list[str] = []
    for module in modules:
        if dep["down"]:
            not_attempted.append(module)
            continue
        if not update_module(module):
            log.error("FAILED: %s", module)
            failed_modules.append(module)
        # Between-module invariant: did this module's update take a shared
        # dependency down? Retries inside the probes tolerate a transient reload.
        failures = check_shared_dependencies()
        if failures:
            dep["down"] = True
            dep["culprit"] = module
            dep["failures"] = failures
            dep["evidence"] = collect_dependency_evidence(failures)
            detail = "; ".join(f["detail"] for f in failures)
            log.error("SHARED DEPENDENCY DOWN after updating '%s' (%s phase): %s",
                      module, phase_label, detail)
            log.error("Last module after which shared services were healthy: %s",
                      dep["last_good"] or "(none — down before the first module)")
            checkconf = dep["evidence"].get("unbound_checkconf")
            if checkconf:
                log.error("unbound-checkconf on the firewall reports: %s", checkconf)
            log.error("Halting the remaining %s modules — they reach the same "
                      "service and would fail with this one root cause.", phase_label)
        else:
            dep["last_good"] = module
    return not_attempted


# ── Phase 3: cluster node reboot pass (issue #275) ───────────────────


def reboot_cluster_script() -> Path | None:
    """Resolve cluster/reboot-cluster.sh from the installed cluster module."""
    try:
        with open(CONFIG_DIR / "cluster.json") as f:
            cfg = json.load(f)
        # .moduleSource since #609; .location until migration 0006 has run.
        location = cfg.get("moduleSource") or cfg.get("location", "")
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    if not location:
        return None
    script = Path(location) / "reboot-cluster.sh"
    return script if script.is_file() else None


def pending_migrations() -> list:
    """The runner's --list output, indented for the dry-run plan (ADR-025 D6).

    --list writes nothing and exits 0 whether or not anything is pending, so a
    dry run can always ask. A runner that is missing (a site that has not yet
    pulled this release) or that fails is reported in one line rather than
    failing the preview: the plan is still worth printing.
    """
    if not os.path.exists(RUN_MIGRATIONS_CMD):
        return ["  (the migration runner is not on this site yet)"]
    try:
        out = subprocess.run(
            [RUN_MIGRATIONS_CMD, "--list"],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return [f"  (could not list pending migrations: {exc})"]
    if out.returncode != 0:
        return ["  (could not list pending migrations)"]
    # The runner labels its own lines ([Info] …); this plan is logged at [Info]
    # already, so the runner's label and colour would print twice.
    lines = [_ANSI.sub("", ln).strip() for ln in out.stdout.splitlines() if ln.strip()]
    lines = [ln[len("[Info]"):].strip() if ln.startswith("[Info]") else ln for ln in lines]
    return ["  " + ln for ln in lines if ln] or ["  no pending migrations"]


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


# ── Result artefact ──────────────────────────────────────────────────


def refresh_control_plane() -> str:
    """Phase 0: refresh the control plane before any module is updated (#595).

    This used to happen inside tappaas-cicd's OWN module update, at
    pre-update.sh — i.e. behind update-module.sh's Step 2 pre-update test. One
    failing check there aborted the module update before the `git pull` ran, so
    the pull that would have carried the fix sat behind a test of the broken
    code and the sweep stalled the same way every night (2026-09-07..09) until a
    human intervened. Hoisting it out of the gated path is what breaks that
    ratchet: the mothership can always update itself.

    Returns one of "refreshed" | "stale" | "failed" | "skipped", recorded in the
    sweep summary and in last-update-result.json. A stale/failed refresh does
    NOT halt the sweep — the previous binaries still work — but it must never be
    silent: #467 ran for weeks on exactly that silence, and the 14 downstream
    "no module drift verb" failures of #595 were this condition seen from the
    far end, one module at a time.
    """
    if not os.path.exists(REFRESH_CONTROL_PLANE_CMD):
        # A checkout that predates this script: the OLD pre-update.sh still does
        # the refresh inline, and the pull it performs is what puts this file on
        # disk for the next run. Not an error, but say so.
        log.warning("Control-plane refresh script not found at %s — this checkout "
                    "predates it; the refresh falls back to pre-update.sh this run.",
                    REFRESH_CONTROL_PLANE_CMD)
        return "skipped"
    try:
        rc = subprocess.run([REFRESH_CONTROL_PLANE_CMD], text=True).returncode
    except (subprocess.SubprocessError, OSError) as e:
        log.error("Control-plane refresh could not run (%s) — shared manager "
                  "binaries may be STALE for this whole sweep.", e)
        return "failed"
    if rc == 0:
        return "refreshed"
    if rc == REFRESH_RC_STALE:
        log.error("Control-plane refresh incomplete: one or more component groups "
                  "failed to BUILD. The shared manager/controller binaries every "
                  "module reconciles through are STALE (previous build). Module "
                  "failures below may be symptoms of this, not of the module.")
        return "stale"
    log.error("Control-plane refresh FAILED (rc=%d) — the repositories may not be "
              "pulled and the shared manager binaries may be STALE for this whole "
              "sweep.", rc)
    return "failed"


def write_result_artifact(result: dict) -> None:
    """Persist the outcome of a real sweep to a journal-free artefact (#506).

    Written atomically (temp + replace) so a reader never sees a half-written
    file. Only real sweeps reach the call site — a not-due hourly run exits at
    the schedule gate first — so the file always reflects the last sweep that
    actually ran. Query it with e.g. `jq .ok /home/tappaas/config/last-update-result.json`.
    """
    try:
        tmp = RESULT_PATH.with_name(RESULT_PATH.name + ".tmp")
        with open(tmp, "w") as f:
            json.dump(result, f, indent=2)
            f.write("\n")
        os.replace(tmp, RESULT_PATH)
    except OSError as e:
        log.warning("Could not write result artefact %s: %s", RESULT_PATH, e)


# ── Main ─────────────────────────────────────────────────────────────


def require_operator() -> None:
    """#533: update-tappaas must run as the tappaas operator, never root.

    Under sudo (euid 0) OpenSSH resolves its identity from /root/.ssh via
    getpwuid() and never finds the operator key (ADR-018), and the managers this
    spawns inherit root and write root-owned config — the trap that makes the
    next run need sudo. The systemd unit already runs as User=tappaas; this
    refuses a manual `sudo update-tappaas`.
    """
    operator = os.environ.get("TAPPAAS_OPERATOR", "tappaas")
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        log.error(
            "update-tappaas must run as the '%s' operator, not root — do not use "
            "sudo. If a config or repo file is root-owned, repair it as %s: "
            "tappaas-repair-ownership.sh",
            operator, operator,
        )
        sys.exit(1)


def main():
    setup_logging()
    require_operator()  # #533: refuse root before touching config or spawning managers

    parser = argparse.ArgumentParser(
        allow_abbrev=False,  # an option only by its full name (#644)
        description="TAPPaaS update scheduler - updates foundation and app modules across all nodes"
    )
    parser.add_argument(
        "--force", action="store_true",
        help="DEPRECATED (ADR-017 D5): no effect under update-tappaas.service; "
             "run an update now with `site-manager update`",
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

    ctx = run_context()
    request = ctx["request"]
    # systemd names the unit that triggered this start (TRIGGER_UNIT, v254+):
    # only the timer's start is the scheduled pass. A request that a timer run
    # happened to claim belongs to the operator's own start, not to this run.
    scheduled = os.environ.get("TRIGGER_UNIT") == "update-tappaas.timer"
    if scheduled and request:
        log.warning("Ignoring an operator request picked up by the timer's run: %s",
                    json.dumps(request, sort_keys=True))
        request = None
    if args.force:
        log.warning("update-tappaas --force is deprecated (ADR-017 D5)%s — run an "
                    "update now with: site-manager update",
                    "; it has no effect under update-tappaas.service" if ctx["path"] == "unit" else "")
    if not UNDER_SYSTEMD and not args.dry_run:
        log.warning("update-tappaas outside update-tappaas.service does not update the "
                    "mothership itself (ADR-017 D3) — use: site-manager update")
    if request:
        log.debug("Operator request: %s", json.dumps(request, sort_keys=True))

    if ctx["path"] == "unit":
        log.debug("Started by update-tappaas.service after its prepare and rebuild "
                  "steps (ADR-017 D3): no schedule check, control plane %s",
                  ctx["control_plane"])
    elif not (args.force or args.dry_run or request):
        # The old unit's hourly timer (first activation, ADR-017 Bootstrap).
        log.info("Checking update schedule")
        if not should_update_now(config, current_hour):
            log.info("Not scheduled for update at this time")
            sys.exit(0)

    # --force of `site-manager update` (the request, or the env of R-1's
    # site-manager): every module passes a failing pre-update test, and the
    # disruption window opens for rebootOk modules (ADR-020 D8).
    module_force = (request is not None and request.get("force") is True) \
        or os.environ.get("TAPPAAS_MODULE_FORCE") == "1"
    if module_force:
        os.environ["TAPPAAS_MODULE_FORCE"] = "1"
    allow_disruption = (request is not None and request.get("allowDisruption") is True) \
        or os.environ.get("TAPPAAS_ALLOW_DISRUPTION") == "1"
    if not args.dry_run:
        set_stage("sweep")

    # Backfill a missing site.json defaultEnvironment (ADR-007d #426) before any
    # module runs, so the tappaas-cicd post-update schema validation passes on
    # sites whose site.json predates the field. Idempotent; honours --dry-run.
    ensure_default_environment(config, args.dry_run)

    # Decommissioned modules (archived/external) are dropped BEFORE the
    # topological sort (#441), so a dependent of an archived provider simply
    # loses that edge instead of being ordered behind a module we never run.
    discovered = get_installed_apps()
    machines = foundation_machines(discovered)
    apps, skipped_apps = partition_by_lifecycle([m for m in discovered if m not in machines])
    sorted_apps = topological_sort(apps)

    # Resolve each canonical foundation module to its deployed config name,
    # honouring the ADR-007 P8 legacy alias (network → firewall). The deployed name
    # is passed to `module-manager module modify` so a not-yet-migrated firewall.json
    # updates correctly in the network slot.
    installed_foundation, skipped_foundation = partition_by_lifecycle(foundation_order([
        name
        for m in FOUNDATION_MODULES
        if (name := deployed_foundation_name(m)) is not None
    ], machines))

    # automaticReboot (default true) gates the Phase 3 node reboot pass.
    # site.json is flat (ADR-007): .automaticReboot (was .tappaas.automaticReboot).
    automatic_reboot = config.get("automaticReboot", True)

    # Dry run: show the update plan
    if args.dry_run:
        log.info("=== DRY RUN MODE ===")
        if module_force:
            log.info("(--force: every module updates even if its pre-update test failed)")
        if allow_disruption:
            log.info("(--allow-disruption: modules with rebootOk may have disruptive "
                     "changes applied now; the others keep them deferred)")
        log.info("Before the sweep - update-tappaas.service ExecStartPre (ADR-017 D3):")
        log.info("  pull (holds respected) + relink ~/bin + component builds: %s",
                 REFRESH_CONTROL_PLANE_CMD)
        log.info("  config migrations (ADR-025): %s", RUN_MIGRATIONS_CMD)
        for line in pending_migrations():
            log.info("  %s", line)
        log.info("  nixos-rebuild switch of the mothership (tappaas-self-rebuild.sh)")
        log.info("Phase 1 - Foundation update order:")
        for i, mod in enumerate(installed_foundation, 1):
            log.info("  %d. module-manager module update %s", i, mod)
        log_skipped(skipped_foundation)
        not_installed = [m for m in FOUNDATION_MODULES if deployed_foundation_name(m) is None]
        if not_installed:
            log.info("  (not installed: %s)", ", ".join(not_installed))
        log.info("Phase 2 - App update order (%d module(s)):", len(sorted_apps))
        if sorted_apps:
            for i, app in enumerate(sorted_apps, 1):
                dep_providers = get_module_dependencies(app)
                dep_str = f" (depends on: {', '.join(dep_providers)})" if dep_providers else ""
                log.info("  %d. module-manager module update %s%s", i, app, dep_str)
        else:
            log.info("  (no app modules installed)")
        log_skipped(skipped_apps)
        log.info("Phase 3 - Node reboot pass (automaticReboot=%s):", automatic_reboot)
        log.info("Phase 4 - Postgres collation reconciliation (#726)")
        reboot_pass(automatic_reboot, dry_run=True)
        log.info("To run these updates: site-manager update")
        sys.exit(0)

    failed_modules = []

    # Phase 0: refresh the control plane — pull the repositories, relink ~/bin,
    # rebuild every compiled component — BEFORE any module is touched (#595).
    #
    # Placed AFTER the schedule gate above, never before it: this unit fires
    # hourly and exits there on a not-due run, so hoisting the refresh any
    # earlier would `git pull` against the forge every hour instead of once per
    # scheduled sweep.
    #
    # This also settles an ordering inconsistency that predates the hoist: the
    # pull used to happen inside tappaas-cicd's update, the SECOND foundation
    # module, so `cluster` (the first) updated against the previous run's source
    # while everything after it saw the new one. Now every module in the sweep
    # runs against the same tree.
    if ctx["path"] == "unit":
        control_plane = ctx["control_plane"]
    else:
        log.info("Phase 0: Refresh the control plane (repositories, ~/bin, components)")
        control_plane = refresh_control_plane()

    # Phase 0.5: capture cluster membership into site.json (node-provisioning
    # design N1). A node joined via `install.sh --join` cannot register itself
    # in this site.json; the HA fold / zone distribution read
    # .hardware.nodes, so an uncaptured node is invisible to them. Non-fatal:
    # a failure warns and the update proceeds with the known nodes.
    # Override for tests with SITE_MANAGER_CMD.
    site_manager_cmd = os.environ.get("SITE_MANAGER_CMD", "/home/tappaas/bin/site-manager")
    log.info("Phase 0.5: reconcile cluster node inventory into site.json")
    try:
        result = subprocess.run(
            [site_manager_cmd, "node", "reconcile", "--apply"], text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        relog_output(result.stdout)
        if result.returncode != 0:
            log.warning("site-manager node reconcile reported issues (rc=%d) — continuing", result.returncode)
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        log.warning("site-manager node reconcile could not run (%s) — continuing", e)

    # Shared-dependency state carried across both phases (#517). A baseline probe
    # first: if the resolver/OPNsense are ALREADY down before we touch anything,
    # the outage is not attributable to a module and every module is skipped
    # (updating against a dead shared service cannot succeed).
    dep = {"down": False, "culprit": None, "last_good": None, "failures": [], "evidence": {}}
    baseline = check_shared_dependencies()
    if baseline:
        dep["down"] = True
        dep["failures"] = baseline
        dep["evidence"] = collect_dependency_evidence(baseline)
        detail = "; ".join(f["detail"] for f in baseline)
        log.error("Shared dependencies are DOWN before the sweep started (not "
                  "attributed to any module): %s — skipping all module updates.", detail)
        checkconf = dep["evidence"].get("unbound_checkconf")
        if checkconf:
            log.error("unbound-checkconf on the firewall reports: %s", checkconf)

    # ADR-020 D8: a module that declares rebootOk may have a disruptive change
    # applied only when the window is open (disruption_window_open): the
    # scheduled run with automaticReboot, or an operator run with --force.
    if disruption_window_open(automatic_reboot, scheduled, allow_disruption):
        os.environ["TAPPAAS_SCHEDULED_PASS"] = "1"
    else:
        os.environ.pop("TAPPAAS_SCHEDULED_PASS", None)

    # Phase 1: Foundation modules in fixed order
    # No "[i/N] Updating <module>" line — update-module.sh's own banner
    # ("TAPPaaS Module Update: <module>") immediately repeats it.
    log.info("Phase 1: Updating foundation modules")
    log_skipped(skipped_foundation)
    not_attempted = run_update_phase(installed_foundation, "foundation", failed_modules, dep)

    # Phase 2: App modules in dependency order
    log.info("Phase 2: Updating app modules")
    log_skipped(skipped_apps)
    if sorted_apps:
        not_attempted += run_update_phase(sorted_apps, "app", failed_modules, dep)
    else:
        log.info("No app modules found to update")

    # Phase 3: controlled node reboot pass (issue #275)
    log.info("Phase 3: Node reboot pass (automaticReboot=%s)", automatic_reboot)
    reboot_ok = reboot_pass(automatic_reboot, dry_run=False)
    if not reboot_ok:
        log.error("FAILED: node reboot pass")

    # Phase 4: settle Postgres collation versions (#726).
    # A nixpkgs release move changes glibc, and Postgres warns on every
    # connection until the recorded version is refreshed — permanently, and
    # loudly enough to drown out a future glibc bump that genuinely reorders
    # text. The script earns each refresh by verifying that database's btree
    # indexes first, and refuses where they do not verify, so this cannot
    # silence a real problem. Cheap when there is nothing to do: one query per
    # Postgres guest.
    log.info("Phase 4: Postgres collation reconciliation")
    collation_ok = True
    _coll = Path("/home/tappaas/bin/tappaas-collation-reconcile.sh")
    if _coll.exists():
        _rc = subprocess.run([str(_coll), "--apply"], capture_output=True, text=True)
        for _line in (_rc.stdout or "").splitlines():
            log.info("  %s", _line)
        if _rc.returncode != 0:
            collation_ok = False
            for _line in (_rc.stderr or "").splitlines():
                log.warning("  %s", _line)
            log.warning(
                "collation reconciliation needs attention — a database's indexes did "
                "not verify, so its recorded version was left alone on purpose (#726)"
            )
    else:
        log.info("  tappaas-collation-reconcile.sh not installed — skipped")

    # Summary
    end_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    total = len(installed_foundation) + len(sorted_apps)
    # not_attempted modules never ran (halted at the boundary / baseline-down),
    # so they are neither successes nor per-module failures.
    succeeded = total - len(failed_modules) - len(not_attempted)

    log.info("=" * 60)
    if DEFERRED_CHANGES:
        log.warning(
            "%d module(s) have pending disruptive changes, deferred for want of "
            "authorization:", len(DEFERRED_CHANGES),
        )
        for d in DEFERRED_CHANGES:
            log.warning("  %s", d)
        log.warning(
            "Apply one in a maintenance window with: module-manager module modify "
            "<module> --force   (or set rebootOk on the module to permit it in the "
            "scheduled pass)"
        )
    if TEST_WARNINGS:
        log.warning(
            "%d module(s) updated with checks that were already failing before "
            "the update (not caused by it):", len(TEST_WARNINGS),
        )
        for w in TEST_WARNINGS:
            log.warning("  %s", w)
    log.info(
        "update-tappaas completed: %s | control_plane=%s total=%d succeeded=%d "
        "failed=%d not_attempted=%d skipped=%d reboot=%s collation=%s",
        end_time, control_plane, total, succeeded, len(failed_modules),
        len(not_attempted), len(skipped_foundation) + len(skipped_apps),
        "ok" if reboot_ok else "failed",
        "ok" if collation_ok else "needs-attention",
    )

    # Persist a journal-free result artefact (#506). This is the durable,
    # queryable record of the last real sweep; the systemd unit's own Result is
    # unreliable because the next hourly no-op run overwrites it with success.
    artifact = {
        "start_time": start_time,
        "end_time": end_time,
        # What started this run (ADR-017 D4): the operator's request, or none
        # for the scheduled run; and which path it took (unit / legacy).
        "request": request,
        "path": ctx["path"],
        "total": total,
        "succeeded": succeeded,
        "failed": len(failed_modules),
        "failed_modules": failed_modules,
        "not_attempted": len(not_attempted),
        "skipped": len(skipped_foundation) + len(skipped_apps),
        "reboot": "ok" if reboot_ok else "failed",
        # Whether the mothership managed to update ITSELF this run (#595). A
        # sweep whose shared binaries are stale did not fully succeed, however
        # green the per-module tally looks — same doctrine as #519.
        "control_plane": control_plane,
        # Deferrals are recorded, not counted as failures (ADR-020 D8): the
        # converge did everything it was allowed to do. They belong in the
        # artefact so "what is still pending" survives the log.
        "deferred": len(DEFERRED_CHANGES),
        "deferred_changes": DEFERRED_CHANGES,
        # Recorded, not failed (#635): the update did not introduce them.
        "test_warnings": TEST_WARNINGS,
        "ok": (not failed_modules and not dep["down"] and reboot_ok
               and control_plane in ("refreshed", "skipped")),
    }
    # When a shared service went down mid-sweep, carry the boundary so the run is
    # attributable to one root cause instead of N per-module symptoms (#517).
    if dep["down"]:
        artifact["shared_dependency_down"] = {
            "failures": dep["failures"],
            "culprit_module": dep["culprit"],
            "last_good_module": dep["last_good"],
            "not_attempted_modules": not_attempted,
            "evidence": dep.get("evidence", {}),
        }
    write_result_artifact(artifact)

    control_plane_bad = control_plane in ("stale", "failed")
    if failed_modules or dep["down"] or not reboot_ok or control_plane_bad:
        if control_plane_bad:
            # Named FIRST and as a candidate root cause: every module reconciles
            # through the shared manager binaries, so a stale control plane
            # shows up as N unrelated-looking module failures. That inversion —
            # 14 symptoms reported, the one cause not — is #595.
            log.error("Control plane is %s — the shared manager/controller "
                      "binaries are not this checkout's. Any module failure "
                      "above may be a symptom of that; rebuild with %s",
                      control_plane.upper(), REFRESH_CONTROL_PLANE_CMD)
        if dep["down"]:
            detail = "; ".join(f["detail"] for f in dep["failures"])
            if dep["culprit"]:
                log.error("Root cause: shared dependency down after '%s' (%s) — "
                          "%d module(s) not attempted.",
                          dep["culprit"], detail, len(not_attempted))
            else:
                log.error("Root cause: shared dependency down before the sweep (%s) "
                          "— %d module(s) not attempted.", detail, len(not_attempted))
        if failed_modules:
            log.error("Failed modules: %s", ", ".join(failed_modules))
        sys.exit(1)

    log.info("All modules updated successfully (control plane %s)", control_plane)
    set_stage(None)


if __name__ == "__main__":
    main()
