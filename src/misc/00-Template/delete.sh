#!/usr/bin/env bash
# delete.sh — take down what deleting this module leaves behind.
#
# OPTIONAL (ADR-027 D2): delete-module.sh already removes the guest and the
# config. A module needs this file only when something else must be undone —
# the satellite's tunnel, the backup module's PBS datastore.
#
# ── EITHER REPLACE THE BODY BELOW WITH THE TEARDOWN, OR DELETE THIS FILE ──
# Deleting the file is the right answer for most modules, and is not a finding:
# a module that needs no teardown should not carry a stub that must be kept
# working. Keep it only if there is something to undo, and then say so here.
# ─────────────────────────────────────────────────────────────────────────

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

warn "delete.sh has not been implemented for this module — it is a template stub, so nothing beyond the guest and its config was removed. Please contact the module's developer."
