#!/usr/bin/env bash
# update-tappaas/install.sh — P10 compiled-component installer.
#
# Idempotently (re)builds the update-tappaas Python package via nix (with a
# GC-rooted out-link) and relinks its CLI into ~/bin. Replaces the whole-VM
# pre-update.sh build block (ADR-007 post-implementation refactor, Phase 4).
# NOTE: update-tappaas lives outside manager/ + controller/, so no dispatcher
# runs this — pre-update.sh calls it explicitly.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${here}/../lib/component-install-lib.sh"
build_and_link_nix_component "${here}" "update-tappaas"
