#!/usr/bin/env bash
# update-tappaas/test.sh — offline smoke: the built CLI loads (argparse help).
# Fast + non-disruptive; TAPPAAS_TEST_DEEP adds nothing here (a real update run
# is exercised by the module-level deep suites).
set -uo pipefail
if ! command -v update-tappaas >/dev/null 2>&1; then
    echo "update-tappaas: bin not installed — skipping (run install.sh first)"
    exit 0
fi
if update-tappaas --help >/dev/null 2>&1; then
    echo "update-tappaas test: 1 passed, 0 failed"
    exit 0
fi
echo "update-tappaas test: --help FAILED (broken build linked into ~/bin?)"
exit 1
