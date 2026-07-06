#!/usr/bin/env bash
# identity-controller/install.sh — P10 compiled-component installer.
# Idempotently (re)builds the identity-controller Python package via nix (with
# a GC-rooted out-link, same idiom as every compiled component) and relinks its
# CLI entry points (authentik-manager, identity-controller) into ~/bin so they
# track the repo build (no nixos-rebuild required).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${here}/../../lib/component-install-lib.sh"
build_and_link_nix_component "${here}" "identity-controller" \
    authentik-manager identity-controller
