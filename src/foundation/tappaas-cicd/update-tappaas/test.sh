#!/usr/bin/env bash
# update-tappaas/test.sh — offline smoke: the built CLI loads (argparse help),
# plus a unit test of the defaultEnvironment backfill (ADR-007d #426). Fast +
# non-disruptive; TAPPAAS_TEST_DEEP adds nothing here (a real update run is
# exercised by the module-level deep suites).
set -uo pipefail

passed=0
failed=0

# ── 1) CLI smoke: the built bin loads ────────────────────────────────
if ! command -v update-tappaas >/dev/null 2>&1; then
    echo "update-tappaas: bin not installed — skipping (run install.sh first)"
    exit 0
fi
if update-tappaas --help >/dev/null 2>&1; then
    passed=$((passed + 1))
else
    echo "  ✗ update-tappaas --help FAILED (broken build linked into ~/bin?)"
    failed=$((failed + 1))
fi

# ── 2) Unit: ensure_default_environment backfill (#426) ──────────────
# Import the source module with the same interpreter that runs the built CLI,
# and exercise every branch against temp site.json files (owner→name fallback,
# idempotency, dry-run, and the nothing-to-derive skip).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
main_py="$here/src/update_tappaas/main.py"
py="$(dirname "$(readlink -f "$(command -v update-tappaas)")")/python3"

if [[ -f "$main_py" && -x "$py" ]]; then
    if "$py" - "$main_py" <<'PY'
import importlib.util, json, sys, tempfile, logging
from pathlib import Path
logging.disable(logging.CRITICAL)
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = Path(tempfile.mkdtemp()); p = d / "site.json"

# owner backfill
cfg = {"name": "rossen", "owner": "rossen"}; p.write_text(json.dumps(cfg, indent=2))
m.ensure_default_environment(cfg, False, p)
assert json.loads(p.read_text())["defaultEnvironment"] == "rossen", "owner backfill"

# idempotent (no rewrite once present)
cfg2 = json.loads(p.read_text()); before = p.read_text()
m.ensure_default_environment(cfg2, False, p)
assert p.read_text() == before, "idempotent"

# fallback to name when owner absent
cfg3 = {"name": "acme"}; p.write_text(json.dumps(cfg3, indent=2))
m.ensure_default_environment(cfg3, False, p)
assert json.loads(p.read_text())["defaultEnvironment"] == "acme", "name fallback"

# dry-run writes nothing
cfg4 = {"name": "foo", "owner": "foo"}; p.write_text(json.dumps(cfg4, indent=2)); b4 = p.read_text()
m.ensure_default_environment(cfg4, True, p)
assert p.read_text() == b4 and "defaultEnvironment" not in json.loads(p.read_text()), "dry-run"

# nothing to derive -> skip, no crash
cfg5 = {"name": "", "owner": ""}; p.write_text(json.dumps(cfg5, indent=2))
m.ensure_default_environment(cfg5, False, p)
assert "defaultEnvironment" not in json.loads(p.read_text()), "skip when undecidable"
PY
    then
        passed=$((passed + 1))
    else
        echo "  ✗ ensure_default_environment backfill unit test FAILED"
        failed=$((failed + 1))
    fi
else
    echo "  ⊘ backfill unit test skipped (source or env python not found)"
fi

# ── 2b) Unit: the ADR-020 D8 deferral contract ───────────────────────
# Two invariants that are easy to break and expensive to notice:
#   - update-tappaas NEVER passes --force to `module modify`. Its own --force
#     means "run the sweep now"; forwarding it as DISRUPTION authority would let
#     a routine hourly update reboot production guests.
#   - a converge's DEFERRED: lines are collected, so the sweep can end with one
#     summary of what is still pending instead of leaving them in per-module logs.
if [[ -f "$main_py" && -x "$py" ]]; then
    if "$py" - "$main_py" <<'PYDEFER'
import importlib.util, sys, logging
logging.disable(logging.CRITICAL)
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

seen = {}

class R:
    def __init__(self, rc=0, out="", err=""):
        self.returncode, self.stdout, self.stderr = rc, out, err

def fake_run(argv, **kw):
    seen["argv"] = argv
    return R(0,
             "  applying cores\n"
             "[Warning] DEFERRED: demo net0 needs a disruptive change that is not authorized\n",
             "[Warning] DEFERRED: demo node needs downtime\n")

m.subprocess.run = fake_run
m.DEFERRED_CHANGES.clear()
assert m.update_module("demo") is True, "a deferral is not a failure"

argv = seen["argv"]
assert "--force" not in argv, "update-tappaas must never forward --force: %r" % (argv,)
assert argv[1:3] == ["module", "modify"], "unexpected invocation: %r" % (argv,)

# Both streams are scanned: a provider may warn on either.
assert len(m.DEFERRED_CHANGES) == 2, m.DEFERRED_CHANGES
assert m.DEFERRED_CHANGES[0].startswith("demo net0"), m.DEFERRED_CHANGES
assert any(d.startswith("demo node") for d in m.DEFERRED_CHANGES), m.DEFERRED_CHANGES

# A clean converge adds nothing.
m.subprocess.run = lambda argv, **kw: R(0, "  in sync\n", "")
m.DEFERRED_CHANGES.clear()
m.update_module("demo")
assert m.DEFERRED_CHANGES == [], "a clean converge must not invent deferrals"

# A real failure is still a failure.
m.subprocess.run = lambda argv, **kw: R(1, "", "boom")
assert m.update_module("demo") is False, "a non-zero converge is a failed module"
PYDEFER
    then
        passed=$((passed + 1))
    else
        echo "  ✗ ADR-020 deferral / no-force-forwarding unit test FAILED"
        failed=$((failed + 1))
    fi
else
    echo "  ⊘ deferral unit test skipped (source or env python not found)"
fi

# ── 3) Unit: decommissioned modules stay out of the sweep (#441) ─────
# archived (#215) and external (#216) configs keep their kind/vmname, so the
# module selectors still match them and they used to enter Phase 1/2 — where the
# snapshot found no VM and the pre-update test aborted them as FAILED updates.
if [[ -f "$main_py" && -x "$py" ]]; then
    if "$py" - "$main_py" <<'PY'
import importlib.util, json, sys, tempfile, logging
from pathlib import Path
logging.disable(logging.CRITICAL)
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

d = Path(tempfile.mkdtemp())
m.CONFIG_DIR = d
def w(name, **kw):
    (d / f"{name}.json").write_text(json.dumps({"kind": "module", "vmname": name, **kw}))

# Apps: two decommissioned, four that must still be swept.
w("gone",       status="archived", dependsOn=["cluster:vm"])
w("pfsense",    status="external")
w("shouty",     status="Archived")            # case-insensitive
w("nextcloud",  status="Production", dependsOn=["cluster:vm"])
w("beta",       status="Testing")
w("old",        status="Deprecated")          # unmaintained != decommissioned
w("plain")                                    # no status at all

apps, skipped = m.partition_by_lifecycle(m.get_installed_apps())
assert sorted(apps) == ["beta", "nextcloud", "old", "plain"], f"apps kept: {sorted(apps)}"
assert sorted(n for n, _ in skipped) == ["gone", "pfsense", "shouty"], f"skipped: {skipped}"
assert all(s in ("archived", "external") for _, s in skipped), "skip reason is the status"

# Foundation loop is filtered by the same predicate (it selects on file
# existence alone, so an archived foundation module entered Phase 1 too).
w("logging", status="archived")
w("identity", status="Production")
found = [n for f in m.FOUNDATION_MODULES if (n := m.deployed_foundation_name(f))]
active, skipped_f = m.partition_by_lifecycle(found)
assert active == ["identity"], f"foundation kept: {active}"
assert [n for n, _ in skipped_f] == ["logging"], f"foundation skipped: {skipped_f}"

# An archived PROVIDER must not distort the order of what remains: filtering
# happens before the sort, so the dependent just loses that edge.
d2 = Path(tempfile.mkdtemp()); m.CONFIG_DIR = d2
(d2 / "litellm.json").write_text(json.dumps({"kind": "module", "vmname": "litellm", "status": "archived"}))
(d2 / "openwebui.json").write_text(json.dumps(
    {"kind": "module", "vmname": "openwebui", "status": "Production", "dependsOn": ["litellm:models"]}))
apps2, skipped2 = m.partition_by_lifecycle(m.get_installed_apps())
order = m.topological_sort(apps2)
assert order == ["openwebui"], f"dependent still planned exactly once: {order}"
assert [n for n, _ in skipped2] == ["litellm"], f"archived provider skipped: {skipped2}"

# An unreadable/absent config must not crash the partition (defaults to active,
# so a malformed config is still attempted rather than silently dropped).
assert m.module_status("does-not-exist") == "", "missing config -> no status"
(d2 / "broken.json").write_text("{ not json")
assert m.module_status("broken") == "", "unparseable config -> no status"

# A module that lists one of its OWN provided capabilities in dependsOn (to
# sequence its per-service scripts) must not self-loop into a false circular-
# dependency flag — nor strand modules that legitimately depend on it. (#514)
d3 = Path(tempfile.mkdtemp()); m.CONFIG_DIR = d3
(d3 / "alfen.json").write_text(json.dumps(
    {"kind": "module", "vmname": "alfen", "status": "Production",
     "dependsOn": ["cluster:vm", "alfen:nat"]}))
(d3 / "hassanova.json").write_text(json.dumps(
    {"kind": "module", "vmname": "hassanova", "status": "Production",
     "dependsOn": ["alfen:nat", "alfen:mqtt", "alfen:modbus"]}))
apps3, _ = m.partition_by_lifecycle(m.get_installed_apps())
order3 = m.topological_sort(apps3)
assert set(order3) == {"alfen", "hassanova"}, f"both planned: {order3}"
assert order3.index("alfen") < order3.index("hassanova"), f"alfen before hassanova: {order3}"
PY
    then
        passed=$((passed + 1))
    else
        echo "  ✗ #441 decommissioned-module skip unit test FAILED"
        failed=$((failed + 1))
    fi
else
    echo "  ⊘ #441 skip unit test skipped (source or env python not found)"
fi

# ── 4) Unit: between-module shared-dependency invariant (#517) ───────
# Drive run_update_phase with stubbed update_module / probes: a healthy sweep
# updates everything and records last_good; a probe that flips to DOWN after
# module "b" halts the phase, names the boundary, and leaves "c" not attempted.
if [[ -f "$main_py" && -x "$py" ]]; then
    if "$py" - "$main_py" <<'PY'
import importlib.util, sys, logging
logging.disable(logging.CRITICAL)
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# Keep the test hermetic: stub the evidence collector (it would ssh a validator).
m.collect_dependency_evidence = lambda failures: {"unbound_checkconf": "STUB"}

def newdep():
    return {"down": False, "culprit": None, "last_good": None, "failures": [], "evidence": {}}

# All modules update fine; shared deps stay healthy.
m.update_module = lambda name: True
m.check_shared_dependencies = lambda: []
failed = []; dep = newdep()
na = m.run_update_phase(["a", "b", "c"], "app", failed, dep)
assert failed == [] and na == [], f"healthy: failed={failed} not_attempted={na}"
assert dep["down"] is False and dep["last_good"] == "c", f"healthy last_good: {dep}"
assert dep["evidence"] == {}, f"healthy sweep collects no evidence: {dep}"

# Resolver dies right after "b": boundary is b, last_good a, c not attempted.
calls = {"n": 0}
def flip():
    calls["n"] += 1
    # healthy after "a" (call 1); down after "b" (call 2 onward)
    return [] if calls["n"] < 2 else [{"dependency": "unbound-dns", "detail": "down"}]
m.update_module = lambda name: True
m.check_shared_dependencies = flip
failed = []; dep = newdep()
na = m.run_update_phase(["a", "b", "c"], "app", failed, dep)
assert dep["down"] is True, f"expected down: {dep}"
assert dep["culprit"] == "b", f"culprit should be b: {dep}"
assert dep["last_good"] == "a", f"last_good should be a: {dep}"
assert na == ["c"], f"c should be not attempted: {na}"
assert failed == [], f"no per-module failures on a clean update: {failed}"
assert dep["evidence"] == {"unbound_checkconf": "STUB"}, f"evidence captured: {dep}"

# Once dep is down entering a phase, every module is not attempted.
m.check_shared_dependencies = lambda: []  # would be healthy, but dep is already down
failed = []; dep = {"down": True, "culprit": "x", "last_good": "w", "failures": [], "evidence": {}}
na = m.run_update_phase(["p", "q"], "foundation", failed, dep)
assert na == ["p", "q"] and failed == [], f"already-down phase skips all: na={na}"
PY
    then
        passed=$((passed + 1))
    else
        echo "  ✗ #517 shared-dependency invariant unit test FAILED"
        failed=$((failed + 1))
    fi
else
    echo "  ⊘ #517 invariant unit test skipped (source or env python not found)"
fi

# ── 5) Unit: preflight guard refuses root (#533) ─────────────────────
# require_operator() must exit(1) when euid is 0 (a manual `sudo update-tappaas`)
# and be a no-op otherwise. os.geteuid is monkeypatched so the test needs no
# actual root.
if [[ -f "$main_py" && -x "$py" ]]; then
    if "$py" - "$main_py" <<'PY'
import importlib.util, sys, logging
logging.disable(logging.CRITICAL)
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# non-root euid -> returns without raising
m.os.geteuid = lambda: 1000
m.require_operator()

# root euid -> SystemExit(1)
m.os.geteuid = lambda: 0
raised = None
try:
    m.require_operator()
except SystemExit as e:
    raised = e
assert raised is not None and raised.code == 1, f"root must exit(1), got {raised!r}"
PY
    then
        passed=$((passed + 1))
    else
        echo "  ✗ #533 require_operator guard unit test FAILED"
        failed=$((failed + 1))
    fi
else
    echo "  ⊘ #533 guard unit test skipped (source or env python not found)"
fi

echo "update-tappaas test: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
