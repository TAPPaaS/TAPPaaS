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

echo "update-tappaas test: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
