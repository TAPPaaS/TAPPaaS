#!/usr/bin/env bash
# TAPPaaS CICD Module Pre-Update
#

set -euo pipefail

. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/lib/common-install-routines.sh
. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/lib/repo-sync.sh

VMNAME="$(get_config_value 'vmname' "$1")"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
info "Starting TAPPaaS-CICD module update for VM: $VMNAME on node: $NODE"

# Pull all tracked repositories. The repository list is now canonical in
# site.json .repositories; get_repositories() reads it there first and falls
# back to the legacy configuration.json .tappaas.repositories while both files
# coexist (so updates keep pulling after configuration.json is deleted).
CONFIG_FILE="/home/tappaas/config/configuration.json"

# Legacy one-shot migration: upstreamGit+branch -> .tappaas.repositories. This
# is retired once configuration.json is gone, so it is fully guarded on the file
# actually existing (must never error on a missing configuration.json).
if [ -f "$CONFIG_FILE" ] && jq -e '.tappaas.upstreamGit' "$CONFIG_FILE" >/dev/null 2>&1; then
  info "Migrating configuration.json from upstreamGit/branch to repositories format..."
  OLD_URL=$(jq -r '.tappaas.upstreamGit' "$CONFIG_FILE")
  OLD_BRANCH=$(jq -r '.tappaas.branch // "stable"' "$CONFIG_FILE")
  OLD_NAME="${OLD_URL##*/}"
  OLD_NAME="${OLD_NAME%.git}"
  tmp_file=$(mktemp)
  jq --arg name "$OLD_NAME" --arg url "$OLD_URL" --arg branch "$OLD_BRANCH" \
    --arg path "/home/tappaas/${OLD_NAME}" \
    '.tappaas.repositories = [{"name": $name, "url": $url, "branch": $branch, "path": $path}] | del(.tappaas.upstreamGit) | del(.tappaas.branch)' \
    "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
  info "  Migrated: upstreamGit=${OLD_URL} branch=${OLD_BRANCH} -> repositories[0]"
fi

REPOS_JSON="$(get_repositories)"
REPO_COUNT=$(echo "$REPOS_JSON" | jq 'length' 2>/dev/null || echo "0")
if [ "$REPO_COUNT" -gt 0 ]; then
  info "Pulling latest changes from ${REPO_COUNT} repository/repositories..."
  for i in $(seq 0 $(( REPO_COUNT - 1 ))); do
    REPO_NAME=$(echo "$REPOS_JSON" | jq -r ".[$i].name")
    REPO_PATH=$(echo "$REPOS_JSON" | jq -r ".[$i].path")
    REPO_BRANCH=$(echo "$REPOS_JSON" | jq -r ".[$i].branch")
    REPO_URL=$(echo "$REPOS_JSON" | jq -r ".[$i].url")
    if [ -d "$REPO_PATH" ]; then
      info "  Syncing ${REPO_NAME} -> ${REPO_URL} (branch: ${REPO_BRANCH})..."
      # reconcile_repo_checkout (lib/repo-sync.sh) re-points `origin` when the
      # site.json url changed forge/repo, then checks out the branch at the
      # remote tip — so a hand-edited OR `repository modify`-driven change to the
      # repo's url/branch is actually applied here (was: fetch+checkout+pull on
      # the OLD origin, which silently pulled the wrong forge — Codeberg incident).
      (
        # allow_discard is NOT passed: an unattended run must never orphan commits
        # that exist only in the checkout. rc 2 == blocked on that decision (#433);
        # the repo is left untouched and re-reported every run until a human acts.
        # `|| _rc=$?` (not a bare call) — set -e would abort the subshell on rc 2
        # before we could tell "blocked" apart from "failed".
        _rc=0
        reconcile_repo_checkout "$REPO_PATH" "$REPO_URL" "$REPO_BRANCH" || _rc=$?
        case "${_rc}" in
          0) ;;
          2) error "${REPO_NAME}: NOT synced — unpushed commits block the origin change (see above). Push them, or run: site-manager repository modify ${REPO_NAME} --url ${REPO_URL} --force" ;;
          *) warn "Failed to sync ${REPO_NAME}" ;;
        esac
      ) 2>&1 | while IFS= read -r _l; do
        # Keep tagged log lines ([Info]/[Warning]/[Error]); route raw git output to [Debug].
        case "$_l" in
          *'[Info]'*|*'[Warning]'*|*'[Error]'*) printf '%s\n' "$_l" ;;
          *) debug "  $_l" ;;
        esac
      done
    else
      warn "Repository directory not found: ${REPO_PATH} (${REPO_NAME})"
    fi
  done
else
  info "No repositories configured — pulling TAPPaaS from default location..."
  cd
  cd TAPPaaS || die "TAPPaaS directory not found!"
  git pull origin
fi
# get to the right directory
cd /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd || die "TAPPaaS-CICD directory not found!"

# --- Install scripts as symlinks into /home/tappaas/bin/ ---
# NOTE: symlinks must be installed BEFORE refreshing config, so that
# create-configuration.sh in ~/bin/ points to the updated repo version.
info "Installing scripts to /home/tappaas/bin/..."
# scripts/*.sh AND lib/*.sh — mirrors install.sh (ADR-007 S0 moved shared
# sourced libraries to lib/; a system UPDATED across that relocation never
# re-linked them, leaving e.g. apply-json-merge.sh missing from ~/bin and
# every module update silently skipping the 3-way config merge — found on
# the production cluster 2026-07-07).
for script in scripts/*.sh lib/*.sh; do
  if [ -f "$script" ]; then
    script_name=$(basename "$script")
    target="/home/tappaas/bin/$script_name"
    # Remove the existing entry first — on NixOS it may be a symlink into a
    # read-only /etc/static/ path (issue #184), which would otherwise make
    # the subsequent chmod fail with EROFS.
    rm -f "$target" 2>/dev/null || true
    src="$(realpath "$script")"
    # chmod the resolved source, not the symlink: chmod follows symlinks,
    # so chmod'ing a /home/tappaas/bin/*.sh symlink that points into
    # /etc/static would still fail. The source lives in the writable repo.
    # #565: only chmod files the repo tracks executable — a sourced lib
    # (linked here so it can be `.`-sourced from ~/bin) stays 100644.
    if tappaas_should_be_executable "$src"; then chmod +x "$src"; fi
    ln -s "$src" "$target"
  fi
done

# --- ADR-007 S0/P10: two-level dispatch builds + links every component ---
# The scripts/*.sh glob above only covers scripts NOT yet relocated. Every
# manager/<x>/ and controller/<x>/ component builds and links its own bins via
# its install.sh, driven by the per-directory dispatcher — including the
# COMPILED components (the TS managers, opnsense-controller and
# identity-controller nix builds; the whole-VM build blocks that used to live
# further down in this file are gone). Idempotent: nix no-ops when inputs are
# unchanged. A component build failure WARNS and the update continues with the
# previous (stale) bins — the Test-11 smoke slice is what surfaces a broken
# build, so a bad component never blocks the fleet update.
_comp_failed=0
for _disp in manager controller; do
  if [ -x "${_disp}/install.sh" ]; then
    info "  linking ${_disp}/ components..."
    "./${_disp}/install.sh" || { warn "  ${_disp}/install.sh reported non-zero rc"; _comp_failed=$((_comp_failed + 1)); }
  fi
done

# update-tappaas lives OUTSIDE manager/ + controller/ (it drives them), so no
# dispatcher covers it — build + link it via its own contract install.sh.
if [ -x update-tappaas/install.sh ]; then
  ./update-tappaas/install.sh || { warn "  update-tappaas/install.sh reported non-zero rc"; _comp_failed=$((_comp_failed + 1)); }
fi

# (The legacy zone-controller/zone-state bash scripts are retired — their verbs
# are native in the network-manager TS bin linked by the dispatcher above:
# `network-manager add/delete/enable/disable/manual`; ADR-007 Phase 7.5.)

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

# --- ADR-007 P2 (S3a): auto-migrate configuration.json -> site.json ---
# PHASED migration: create site.json once, when configuration.json exists and
# site.json does NOT. configuration.json is NOT deleted here (the flag-day
# cutover is a later step), and existing configuration.json readers are left
# untouched. Idempotent + guarded: once site.json exists this is a no-op, and
# the migration script itself no-ops on an existing site.json.
if [[ -f /home/tappaas/config/configuration.json && ! -f /home/tappaas/config/site.json ]]; then
    if [[ -x /home/tappaas/bin/migrate-configuration.sh ]]; then
        info "Migrating configuration.json -> site.json (ADR-007 P2)..."
        /home/tappaas/bin/migrate-configuration.sh --config-dir /home/tappaas/config \
            || warn "  site.json migration reported an error — continuing (configuration.json untouched)"
    else
        warn "migrate-configuration.sh not on PATH yet; skipping site.json migration this run."
    fi
fi

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
if [ -x "./scripts/compose-fields.sh" ]; then
  _cf_tmp="$(mktemp)"
  if ./scripts/compose-fields.sh "$(realpath ..)" > "${_cf_tmp}" 2>/dev/null && [ -s "${_cf_tmp}" ]; then
    rm -f /home/tappaas/config/module-fields.json 2>/dev/null || true
    mv "${_cf_tmp}" /home/tappaas/config/module-fields.json
    echo "  composed module-fields.json ($(jq -r '.fields|length' /home/tappaas/config/module-fields.json) fields)"
  else
    rm -f "${_cf_tmp}" 2>/dev/null || true
    echo "  WARNING: could not compose module-fields.json — leaving the existing one" >&2
  fi
elif [ -f "../schemas/module-fields.json" ]; then
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

# --- One-shot rename: zone keys hyphen → underscore (issue #237) ---
# Marker-gated; runs exactly once per cluster, then becomes a no-op. Must run
# BEFORE the merge below — otherwise the merge would see srv-home (current)
# vs srvHome (source) as a possible-rename and flag both for review instead of
# resolving them automatically.
if [ -f /home/tappaas/bin/migrate-zone-keys-to-underscore.sh ] \
   && [ -f /home/tappaas/config/zones.json ]; then
  /home/tappaas/bin/migrate-zone-keys-to-underscore.sh \
      || warn "  #237 zone-key migration reported issues — continuing"
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

# Report what actually happened. A failed component build stays non-fatal (see
# the dispatch rationale above), but claiming success afterwards is what let
# #467 run unnoticed: every nightly logged two warnings and then this ✓ line,
# so the mothership's own managers went unbuilt for weeks with no visible signal.
if [ "${_comp_failed}" -gt 0 ]; then
  warn "TAPPaaS-CICD scripts installed, but ${_comp_failed} component group(s) failed to build — those bins are STALE (see warnings above)."
else
  info "${GN}✓${CL} All TAPPaaS-CICD programs and scripts installed successfully."
fi
