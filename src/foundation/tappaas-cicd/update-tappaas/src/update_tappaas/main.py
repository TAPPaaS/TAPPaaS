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
# The verb-aligned front door (ADR-007 #3/#5). `module module modify <m>` delegates
# to update-module.sh, so behaviour is unchanged — we just stop calling the script
# directly. Override for tests with MODULE_MANAGER_CMD.
MODULE_MANAGER_CMD = os.environ.get("MODULE_MANAGER_CMD", "/home/tappaas/bin/module-manager")
# unbound-manager, used only to capture deterministic evidence (the validator
# output) when the between-module check finds the resolver down (#516/#517).
# Override for tests with UNBOUND_MANAGER_CMD.
UNBOUND_MANAGER_CMD = os.environ.get("UNBOUND_MANAGER_CMD", "/home/tappaas/bin/unbound-manager")

# ADR-007 P2: the Phase-0 migration orchestrator (ADR-007 P1). Run before the
# foundation loop so ordering is deterministic (not a side-effect of tappaas-cicd
# being the 2nd module). Idempotent + guarded — a no-op on an already-migrated
# system. Override the resolved path for tests with MIGRATE_SCRIPT.
MIGRATE_SCRIPT = os.environ.get("MIGRATE_SCRIPT", "")
MIGRATE_SCRIPT_NAME = "migrate-to-adr007.sh"

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
        if UNDER_SYSTEMD:
            return self.PRIORITY.get(record.levelno, "<6>") + body
        label = self.LABEL.get(record.levelno, "[Info]")
        color = self.LABEL_COLOR.get(record.levelno)
        # Colorize only on a real TTY so captured/piped logs stay plain text.
        if color and sys.stdout.isatty():
            label = f"{color}{label}{self._CLEAR}"
        return f"{label} {body}"


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


def ensure_default_environment(
    config: dict, dry_run: bool, config_path: Path = CONFIG_PATH
) -> None:
    """Backfill a missing site.json .defaultEnvironment (ADR-007d #426).

    #426 made defaultEnvironment a required field, but a site.json written
    before it — the schema migration only fires on the configuration.json →
    site.json conversion, so an already-migrated file is skipped — lacks it and
    fails the tappaas-cicd post-update schema validation. Mirror
    migrate-configuration.sh / create-site.sh: default it to .owner (falling
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


def _is_module_json(path) -> bool:
    """True if a config/*.json is an actual deployed MODULE, not a co-located
    state file. Mirrors module-manager's selector (ADR-007 #3): the `kind:"module"`
    tag (written by install-module.sh), with a `vmname` heuristic fallback for
    not-yet-tagged configs. Excludes state files like
    switch-configuration-{actual,desired}.json that `glob("*.json")` also matches."""
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return False
    if not isinstance(data, dict):
        return False
    return data.get("kind") == "module" or bool(data.get("vmname"))


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


# ── Update lifecycle membership (#441) ───────────────────────────────
#
# Statuses that take a module OUT of the update sweep:
#   archived (#215) — delete-module.sh --archive removed the VM but kept the
#                     config (and its PBS backups) so the module stays restorable.
#   external (#216) — a guest managed OUTSIDE TAPPaaS; per module-fields.json,
#                     "no install/update/test/delete lifecycle applies".
#
# Both keep `kind`/`vmname`, so the module selectors above still match them and
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


def partition_by_lifecycle(modules: list[str]) -> tuple[list[str], list[tuple[str, str]]]:
    """Split module names into (to_update, [(name, status), ...] skipped).

    Status matching is case-insensitive: module-fields.json spells the lifecycle
    values lowercase (archived/external) but the development ones capitalised
    (Production/Testing/…), so neither casing can be assumed.
    """
    active: list[str] = []
    skipped: list[tuple[str, str]] = []
    for name in modules:
        status = module_status(name)
        if status in NON_LIFECYCLE_STATUSES:
            skipped.append((name, status))
        else:
            active.append(name)
    return active, skipped


def log_skipped(skipped: list[tuple[str, str]]) -> None:
    """Report decommissioned modules. Skipping is visible, never silent — an
    operator reading the plan must still see that the module exists."""
    for name, status in skipped:
        log.info("  (skipped: %s — status=%s, not in the update lifecycle)", name, status)


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


def update_module(module_name: str) -> bool:
    """Update a single module via `module-manager module modify` (which delegates
    to update-module.sh — same behaviour, through the verb-aligned front door)."""
    try:
        result = subprocess.run(
            [MODULE_MANAGER_CMD, "module", "modify", module_name], text=True
        )
        return result.returncode == 0
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        log.error("Error running 'module-manager module modify %s': %s", module_name, e)
        return False


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


# ── Phase 0: ADR-007 migration pass (ADR-007 P2 / orchestrator P1) ───


def migrate_script() -> Path | None:
    """Resolve the ADR-007 migration orchestrator (migrate-to-adr007.sh).

    Prefers $MIGRATE_SCRIPT, then ~/bin (the deployed name), then the in-repo
    source. Returns None when not found (e.g. a first run before tappaas-cicd's
    pre-update.sh has linked it — the next run picks it up)."""
    if MIGRATE_SCRIPT:
        p = Path(MIGRATE_SCRIPT)
        return p if p.is_file() else None
    candidates = [
        Path("/home/tappaas/bin") / MIGRATE_SCRIPT_NAME,
        Path("/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts") / MIGRATE_SCRIPT_NAME,
    ]
    for c in candidates:
        if c.is_file():
            return c
    return None


def migration_pass(dry_run: bool) -> bool:
    """Phase 0: converge the system onto the ADR-007 model before touching modules.

    Idempotent + guarded (a no-op on an already-migrated system). Deliberately
    NON-FATAL: a migration hiccup logs loudly but never blocks the module updates
    — the orchestrator is idempotent and retries on the next run. The supervised
    firewall->network step is never triggered from here (no --include-firewall);
    when it is still pending the orchestrator returns rc=2 and we surface that as
    an action-required warning. Returns True when the run may proceed."""
    script = migrate_script()
    if script is None:
        log.warning("Phase 0: %s not found yet — skipping migration pass "
                    "(it is linked when tappaas-cicd updates; next run will run it).",
                    MIGRATE_SCRIPT_NAME)
        return True
    cmd = [str(script), "--yes"]
    if dry_run:
        cmd.append("--dry-run")
    log.debug("Phase 0: ADR-007 migration pass (%s)", " ".join(cmd))
    try:
        result = subprocess.run(cmd, text=True)
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        log.error("Phase 0: error running %s: %s — continuing with module updates.",
                  MIGRATE_SCRIPT_NAME, e)
        return False
    if result.returncode == 0:
        return True
    if result.returncode == 2:
        log.warning("Phase 0: migration INCOMPLETE — a manual action is still required "
                    "(see above, e.g. the supervised firewall->network step). Continuing.")
        return True
    log.error("Phase 0: migration pass failed (rc=%d) — continuing with module updates.",
              result.returncode)
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


# ── Result artefact ──────────────────────────────────────────────────


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

    # Backfill a missing site.json defaultEnvironment (ADR-007d #426) before any
    # module runs, so the tappaas-cicd post-update schema validation passes on
    # sites whose site.json predates the field. Idempotent; honours --dry-run.
    ensure_default_environment(config, args.dry_run)

    # Decommissioned modules (archived/external) are dropped BEFORE the
    # topological sort (#441), so a dependent of an archived provider simply
    # loses that edge instead of being ordered behind a module we never run.
    apps, skipped_apps = partition_by_lifecycle(get_installed_apps())
    sorted_apps = topological_sort(apps)

    # Resolve each canonical foundation module to its deployed config name,
    # honouring the ADR-007 P8 legacy alias (network → firewall). The deployed name
    # is passed to `module-manager module modify` so a not-yet-migrated firewall.json
    # updates correctly in the network slot.
    installed_foundation, skipped_foundation = partition_by_lifecycle([
        name
        for m in FOUNDATION_MODULES
        if (name := deployed_foundation_name(m)) is not None
    ])

    # automaticReboot (default true) gates the Phase 3 node reboot pass.
    # site.json is flat (ADR-007): .automaticReboot (was .tappaas.automaticReboot).
    automatic_reboot = config.get("automaticReboot", True)

    # Dry run: show the update plan
    if args.dry_run:
        log.info("=== DRY RUN MODE ===")
        log.info("Phase 0 - ADR-007 migration pass:")
        migration_pass(dry_run=True)
        log.info("Phase 1 - Foundation update order:")
        for i, mod in enumerate(installed_foundation, 1):
            log.info("  %d. module-manager module modify %s", i, mod)
        log_skipped(skipped_foundation)
        not_installed = [m for m in FOUNDATION_MODULES if deployed_foundation_name(m) is None]
        if not_installed:
            log.info("  (not installed: %s)", ", ".join(not_installed))
        log.info("Phase 2 - App update order (%d module(s)):", len(sorted_apps))
        if sorted_apps:
            for i, app in enumerate(sorted_apps, 1):
                dep_providers = get_module_dependencies(app)
                dep_str = f" (depends on: {', '.join(dep_providers)})" if dep_providers else ""
                log.info("  %d. module-manager module modify %s%s", i, app, dep_str)
        else:
            log.info("  (no app modules installed)")
        log_skipped(skipped_apps)
        log.info("Phase 3 - Node reboot pass (automaticReboot=%s):", automatic_reboot)
        reboot_pass(automatic_reboot, dry_run=True)
        log.info("To run these updates: update-tappaas --force")
        sys.exit(0)

    failed_modules = []

    # Phase 0: ADR-007 migration pass (idempotent; converges the system onto the
    # site/environments/network model before any module is touched). Non-fatal.
    log.info("Phase 0: check for ADR-007 migration")
    migration_pass(dry_run=False)

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
            [site_manager_cmd, "node", "reconcile", "--apply"], text=True
        )
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

    # Summary
    end_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    total = len(installed_foundation) + len(sorted_apps)
    # not_attempted modules never ran (halted at the boundary / baseline-down),
    # so they are neither successes nor per-module failures.
    succeeded = total - len(failed_modules) - len(not_attempted)

    log.info("=" * 60)
    log.info(
        "update-tappaas completed: %s | total=%d succeeded=%d failed=%d "
        "not_attempted=%d skipped=%d reboot=%s",
        end_time, total, succeeded, len(failed_modules), len(not_attempted),
        len(skipped_foundation) + len(skipped_apps),
        "ok" if reboot_ok else "failed",
    )

    # Persist a journal-free result artefact (#506). This is the durable,
    # queryable record of the last real sweep; the systemd unit's own Result is
    # unreliable because the next hourly no-op run overwrites it with success.
    artifact = {
        "start_time": start_time,
        "end_time": end_time,
        "forced": args.force,
        "total": total,
        "succeeded": succeeded,
        "failed": len(failed_modules),
        "failed_modules": failed_modules,
        "not_attempted": len(not_attempted),
        "skipped": len(skipped_foundation) + len(skipped_apps),
        "reboot": "ok" if reboot_ok else "failed",
        "ok": not failed_modules and not dep["down"] and reboot_ok,
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

    if failed_modules or dep["down"] or not reboot_ok:
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

    log.info("All modules updated successfully")


if __name__ == "__main__":
    main()
