#!/usr/bin/env bash
# node-provisioner/install.sh — P10 compiled-component installer.
# Idempotently (re)builds the node-provisioner Python package via nix (with
# a GC-rooted out-link, same idiom as every compiled component) and relinks
# its CLI entry point into ~/bin so it tracks the repo build (no
# nixos-rebuild required).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${here}/../../lib/component-install-lib.sh"
build_and_link_nix_component "${here}" "node-provisioner" \
    node-provisioner
