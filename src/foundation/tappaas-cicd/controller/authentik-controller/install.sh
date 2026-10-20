#!/usr/bin/env bash
# authentik-controller/install.sh — P10 compiled-component installer.
# Idempotently (re)builds the authentik-controller Python package via nix (with
# a GC-rooted out-link, same idiom as every compiled component) and relinks its
# CLI entry points (authentik-controller, and authentik-manager and identity-controller,
# the old names kept as aliases for one release) into ~/bin so they
# track the repo build (no nixos-rebuild required).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${here}/../../lib/component-install-lib.sh"
build_and_link_nix_component "${here}" "authentik-controller" \
    authentik-controller authentik-manager identity-controller
