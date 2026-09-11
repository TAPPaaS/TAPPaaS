#!/usr/bin/env bash
# TAPPaaS CICD Module Pre-Update
#

set -euo pipefail

. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/lib/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
info "Starting TAPPaaS-CICD module update for VM: $VMNAME on node: $NODE"

# ── Control-plane refresh (pull + relink + component build) ──────────
# Extracted to scripts/refresh-control-plane.sh and hoisted to update-tappaas
# Phase 0, so a failing pre-update test can no longer block the mothership from
# updating ITSELF (#595). Still called here so `module modify tappaas-cicd` is
# correct standalone; idempotent, so the Phase 0 run makes this one a no-op.
#
# rc 10 == refreshed, but some component group failed to build (bins STALE).
# Non-fatal here exactly as it was inline, and reported at the end of this file.
_refresh="${TAPPAAS_CICD_DIR:-/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd}/scripts/refresh-control-plane.sh"
_comp_failed=0
if [ -x "${_refresh}" ]; then
  _rrc=0
  "${_refresh}" || _rrc=$?
  case "${_rrc}" in
    0)  ;;
    10) _comp_failed=1 ;;
    *)  die "control-plane refresh failed (rc ${_rrc}) — the checkout is not usable" ;;
  esac
else
  die "scripts/refresh-control-plane.sh not found — cannot refresh the control plane"
fi

# get to the right directory (the rest of this file is relative to it)
cd /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd || die "TAPPaaS-CICD directory not found!"

# --- Refresh configuration.json (re-discover nodes, validate) ---
# F2: ONLY refresh when the legacy configuration.json ALREADY exists (a system
# not yet migrated to site.json). On a fresh, site.json-native install there is
# no configuration.json and `create-configuration.sh --update` would MINT a
# vestigial one (with a placeholder domain) — so it must not run. site.json is
# the source of truth for fresh installs; the node-discovery refresh applies only
# to legacy systems still backed by configuration.json.
if [[ -f /home/tappaas/config/configuration.json && -x /home/tappaas/bin/create-configuration.sh ]]; then
    info "Refreshing configuration.json (legacy system)..."
    /home/tappaas/bin/create-configuration.sh --update || {
        warn "Configuration refresh failed. Using existing configuration.json."
    }
fi

# --- ADR-007 P8 rename leftover: firewall:proxy -> network:proxy ---
# A system CONVERTED to ADR-007 keeps its deployed module configs, and the
# 3-way merge PINS the old dependency name as an operator customization
# (orig-backfill semantics) — update-module then dies "Cannot find provider
# module 'firewall'" and rolls the firewall VM back (production incident
# 2026-07-07). One-time, idempotent rewrite of the renamed dependency.
for _cfg in /home/tappaas/config/*.json; do
  [[ -f "$_cfg" ]] || continue
  if jq -e '(.dependsOn // []) | index("firewall:proxy")' "$_cfg" >/dev/null 2>&1; then
    info "  migrating dependsOn firewall:proxy -> network:proxy in $(basename "$_cfg")"
    _tmp=$(mktemp)
    jq '.dependsOn |= map(if . == "firewall:proxy" then "network:proxy" else . end)' "$_cfg" > "$_tmp" \
      && mv "$_tmp" "$_cfg" || { rm -f "$_tmp"; warn "  migration failed for $_cfg — leaving unchanged"; }
  fi
done

# --- Install foundation config files into /home/tappaas/config/ ---
# module-fields.json: the COMPOSED view, regenerated (#567).
#
# It used to be a symlink to schemas/module-fields.json. That file now holds
# only the 19 fields no service owns; the other 55 definitions live with the
# service that owns them, so the single document every reader still expects has
# to be composed. Regenerated here on every update, and by tappaas_schema_file()
# on demand for the window before this has run.
#
# A real file, not a symlink: it is derived, and a symlink would point at a
# document that is now only part of the answer.
# Gated on EXISTENCE and invoked through `bash` — deliberately not on the
# executable bit. `[ -x ]` over a repo file is a silent feature switch: tracked
# 100644 the guard is false, control falls to the legacy branch below, and a
# 19-field base tier gets installed over a good 74-field cache with nothing
# said. That is #579, and #578 (an add rejecting its own --vmname) was its
# symptom. 201dc45a fixed the mode; this removes the switch.
if [ -f "./scripts/compose-fields.sh" ]; then
  _cf_tmp="$(mktemp)"
  if bash ./scripts/compose-fields.sh "$(realpath ..)" > "${_cf_tmp}" 2>/dev/null && [ -s "${_cf_tmp}" ]; then
    # mv alone: it replaces the old symlink as readily as a file, and the rm
    # that used to precede it only opened a window with no schema on disk.
    chmod 644 "${_cf_tmp}" 2>/dev/null || true
    mv "${_cf_tmp}" /home/tappaas/config/module-fields.json
    debug "  composed module-fields.json ($(jq -r '.fields|length' /home/tappaas/config/module-fields.json) fields)"
  else
    rm -f "${_cf_tmp}" 2>/dev/null || true
    warn "could not compose module-fields.json — leaving the existing one"
  fi
elif [ -f "../schemas/module-fields.json" ]; then
  # No composer in the tree at all — a pre-#567 checkout, where
  # schemas/module-fields.json IS the whole document and the symlink is right.
  # Announced regardless: post-#567 that same path holds only the base tier, so
  # a substitution that halves the schema must never be silent (#579).
  warn "no compose-fields.sh — linking schemas/module-fields.json ($(jq -r '.fields|length' ../schemas/module-fields.json 2>/dev/null || echo '?') fields) as the module schema"
  rm -f /home/tappaas/config/module-fields.json 2>/dev/null || true
  ln -s "$(realpath ../schemas/module-fields.json)" /home/tappaas/config/module-fields.json
fi

# --- OPNsense local patch/plugin state (ensure-patches; Phase 5 / D5) ---
# The firewall-mutation snippets (os-caddy ToDomain patch #237, InterfaceAssign
# controller patch + ACL, os-acme-client/os-ddclient plugin retrofit #254,
# credentials skeleton) live in the controller that owns the firewall:
# `opnsense-ensure-patches` (controller/opnsense-controller/, linked by its
# install.sh above). Idempotent + reachability-guarded. Sequenced HERE — before
# the zone-key migration — because the migration's Stage 5 (network:proxy
# update-service per affected module) needs the caddy patch to write
# underscored upstreams without OPNsense validation failures.
# NON-FATAL by design: ensure-patches returns non-zero when a patch step had
# issues, and under `set -e` + `pipefail` a bare failing pipeline would abort
# this WHOLE script (the zones-check pitfall) — the trailing `|| warn` keeps
# a firewall-patch hiccup from killing the update.
if command -v opnsense-ensure-patches >/dev/null 2>&1; then
  opnsense-ensure-patches 2>&1 | while IFS= read -r _l; do
    case "$_l" in
      *'[Warning]'*|*'[Error]'*|*✓*) printf '%s\n' "$_l" ;;
      *) debug "  $_l" ;;
    esac
  done || warn "  opnsense-ensure-patches reported issues — continuing (retried next cycle)"
else
  warn "opnsense-ensure-patches not on PATH yet — skipping firewall patch ensure this run."
fi

# --- Reconcile zones.json against upstream (rename-aware 3-way merge; #209 / ADR-007 Design A) ---
# install.sh seeds /home/tappaas/config/zones.json on first install but never
# revisits it. `network-manager merge` closes that gap (replacing the
# retired apply-zones-merge.sh): every update-tappaas run re-bases the repo
# template into THIS installation's renamed namespace (zones.rename.json), then
# 3-way-merges zones.json vs zones.json.orig vs zones.rename.json — adopting
# release changes for zones the operator hasn't touched, preserving operator
# customizations (always pins `state`), reporting new/orphan/renamed zones, and
# advancing zones.json.orig to the renamed source. Because srv/home/guest are
# renamed away in the source, the merge can never re-introduce them (the old
# duplicate-VLAN corruption). No-ops if network-manager is not yet on PATH
# (first install before its bin is linked above).
if command -v network-manager >/dev/null 2>&1 \
   && [ -f /home/tappaas/config/zones.json ]; then
  info "Reconciling zones.json against upstream (rename-aware 3-way merge)..."
  network-manager merge 2>&1 | while IFS= read -r line; do debug "  $line"; done \
    || warn "  zones.json merge reported an error — continuing"
fi

# --- Consistency-check zones.json against the installation (ADR-007 S6 N4) ---
# Report-only audit run at every update: validates zones.json is well-formed,
# VLAN/subId-unique, referentially intact, has an active mgmt zone, and that
# every installed module's zone exists and is Active. Non-fatal by design — a
# non-zero result is warned and the update continues. No-ops if network-manager
# is not yet on PATH (first install before its bin is linked above).
if command -v network-manager >/dev/null 2>&1 \
   && [ -f /home/tappaas/config/zones.json ]; then
  info "Checking zones.json consistency (network-manager zones-check)..."
  # Report-only: this must NEVER abort pre-update. Under `set -e` + `pipefail` a
  # standalone failing pipeline aborts the SCRIPT before the PIPESTATUS check
  # below can run — so a non-zero zones-check (e.g. a mid-migration zones.json)
  # would silently skip the rest of pre-update: the opnsense/identity/update-tappaas
  # nix-builds and the OPNsense controller-patch copy. Disable errexit around the
  # pipeline, capture the real rc, then restore. (`|| true` is NOT enough — it
  # clobbers PIPESTATUS, killing the warn.)
  set +e
  network-manager zones-check 2>&1 | while IFS= read -r line; do debug "  $line"; done
  zc_rc=${PIPESTATUS[0]}
  set -e
  if [ "${zc_rc}" -ne 0 ]; then
    warn "  zones-check reported errors — continuing (report-only; review the lines above)"
  fi
fi

# (The whole-VM build blocks, the credentials skeleton and the firewall patch
# copies that used to end this file all moved into the components: builds into
# each component's contract install.sh — Phase 4 / F9+F10 — and the firewall
# patch/plugin/credentials state into `opnsense-ensure-patches`, called above
# before the zone-key migration — Phase 5 / D5.)

# Report what actually happened. The refresh already named a failed component
# build; repeat it here so the pre-update hook never ends on a bare ✓ while the
# mothership's own managers are stale — that silence is what let #467 run for
# weeks.
if [ "${_comp_failed}" -gt 0 ]; then
  warn "TAPPaaS-CICD pre-update done, but the control-plane refresh left component bins STALE (see warnings above)."
else
  info "${GN}✓${CL} TAPPaaS-CICD pre-update completed successfully."
fi
