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

echo "update-tappaas test: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
