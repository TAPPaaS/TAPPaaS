#!/usr/bin/env bash
# opnsense-controller/install.sh — P10 compiled-component installer.
#
# Idempotently (re)builds the opnsense-controller Python package via nix (with
# a GC-rooted out-link) and relinks the whole *-manager CLI family into ~/bin
# so every tool tracks the repo build via update-tappaas (issue #206), plus
# the ADR-008 `opnsense-manager` alias for zone-manager.
#
# This brings the component into the mandatory install/update/test contract —
# it replaces the whole-VM pre-update.sh build block (ADR-007 post-
# implementation refactor, Phase 4 / F9).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
. "${here}/../../lib/component-install-lib.sh"

build_and_link_nix_component "${here}" "opnsense-controller" \
    opnsense-controller zone-manager dns-manager unbound-manager caddy-manager \
    nat-manager opnsense-firewall rules-manager syslog-manager \
    test-network-manager acme-manager

# ADR-008: opnsense-manager is an additive alias for the OPNsense zone
# reconciler (same nix binary as zone-manager); per ADR-008 the orchestrator
# eventually takes the `zone-manager` name. Link via the GC root so the alias
# tracks rebuilds without relinking.
gcroots="${TAPPAAS_GCROOTS:-${HOME}/.tappaas-gcroots}"
ln -sfn "${gcroots}/opnsense-controller/bin/zone-manager" "${bin}/opnsense-manager"
echo "  linked ${bin}/opnsense-manager (alias for zone-manager)"

# opnsense-ensure-patches — the firewall local patch/plugin convergence verb
# (Phase 5 / D5). A bash tool living next to the python package; linked
# explicitly (this component root also holds docs/examples that must NOT be
# linked, so the generic link helper is not used).
chmod +x "${here}/opnsense-ensure-patches"
ln -sfn "${here}/opnsense-ensure-patches" "${bin}/opnsense-ensure-patches"
echo "  linked ${bin}/opnsense-ensure-patches"
