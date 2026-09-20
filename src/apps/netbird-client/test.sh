#!/usr/bin/env bash
# test.sh — verify the module is functioning (invoked by test-module.sh).
#
# ── REPLACE THE BODY BELOW WITH THIS MODULE'S OWN TESTS ──────────────────
# A typical test first confirms the module is running and that tappaas-cicd
# can ssh into it, then checks it does what it is supposed to — e.g. for a web
# server, that it serves the expected content. Exit non-zero on failure so the
# update gate and the regression sweep flag it.
#
# Delete the warning when you write the tests: while it is here, this module
# reports that it has none. It exits 0 deliberately — an unimplemented test
# must not block an update — so the warning is the only thing that says so.
# ─────────────────────────────────────────────────────────────────────────

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

warn "test.sh has not been implemented for this module — it is a template stub, so nothing was verified. Please contact the module's developer."
