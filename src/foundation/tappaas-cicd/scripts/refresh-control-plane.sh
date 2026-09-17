#!/usr/bin/env bash
# Refresh the TAPPaaS control plane: pull the tracked repositories, relink the
# script/lib symlinks into ~/bin, and rebuild every compiled component.
#
# This is the mothership updating ITSELF, and it is a PREREQUISITE of the sweep
# rather than a step inside it (#595). It used to live inline in pre-update.sh,
# i.e. behind update-module.sh's Step 2 pre-update test — so a single failing
# check aborted the tappaas-cicd module update before the pull ran, and the pull
# that would have carried the FIX was behind a test of the broken code. Three
# nightly sweeps in a row (2026-09-07..09) stalled that way, and the shared
# manager binaries the whole fleet reconciles through went unrebuilt.
#
# Both callers run it, and it is idempotent so running it twice costs nothing:
#   update-tappaas Phase 0   — before any module is touched (the ungated path)
#   pre-update.sh            — so `module modify tappaas-cicd` stands alone
#
# Exit codes are the contract:
#   0   everything refreshed
#   10  pull + relink succeeded, but N component group(s) failed to BUILD —
#       those bins are STALE and still the previous build. Deliberately not a
#       hard failure: a broken component must not block the fleet update (the
#       Test-11 smoke slice is what surfaces it). Deliberately not silent
#       either — #467 ran for weeks on exactly that silence.
#   12  a repository did not sync (failed, or unpushed commits block it,
#       #433) and holds no pull hold. Relink and builds still ran. The unit's
#       prepare step (ADR-017 D3) treats it as fatal; older callers read it as
#       a failure and continue, as they did before.
#   1   hard failure — the checkout itself is not usable.
#
# Environment:
#   TAPPAAS_NO_GIT_PULL=1   skip the pull; refresh whatever is checked out
#   TAPPAAS_CONFIG_DIR      where .repo-hold/ lives (default $CONFIG_DIR, else ~/config)
#
# A repository with an active pull hold (#653, `site-manager repository hold`)
# is not pulled; an expired hold is removed and the repository pulls again.
#   TAPPAAS_CICD_DIR        override the cicd directory (tests)
#   TAPPAAS_BIN             override the bin directory (tests)

set -euo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CICD_DIR="${TAPPAAS_CICD_DIR:-$(dirname "${_here}")}"
BIN_DIR="${TAPPAAS_BIN:-/home/tappaas/bin}"

# shellcheck source=../lib/common-install-routines.sh
. "${CICD_DIR}/lib/common-install-routines.sh"
# shellcheck source=../lib/repo-sync.sh
. "${CICD_DIR}/lib/repo-sync.sh"
# shellcheck source=../lib/repo-hold.sh
. "${CICD_DIR}/lib/repo-hold.sh"
HOLD_DIR_CONFIG="${TAPPAAS_CONFIG_DIR:-${CONFIG_DIR:-/home/tappaas/config}}"

# ── 1. Pull the tracked repositories ─────────────────────────────────
# The repository list is canonical in site.json .repositories; get_repositories()
# reads it there first and falls back to the legacy configuration.json
# .tappaas.repositories while both files coexist (so updates keep pulling after
# configuration.json is deleted).
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

# TAPPAAS_NO_GIT_PULL=1 (site-manager update --no-git-pull): refresh whatever is
# checked out, without pulling. Lets an operator test local, not-yet-pushed
# changes across the whole sweep before they reach Codeberg.
if [ "${TAPPAAS_NO_GIT_PULL:-0}" = "1" ]; then
  info "TAPPAAS_NO_GIT_PULL=1 — skipping repository pull; refreshing whatever is checked out."
else
_sync_failed="$(mktemp)"
trap 'rm -f "${_sync_failed}"' EXIT
REPOS_JSON="$(get_repositories)"
REPO_COUNT=$(echo "$REPOS_JSON" | jq 'length' 2>/dev/null || echo "0")
if [ "$REPO_COUNT" -gt 0 ]; then
  info "Pulling latest changes from ${REPO_COUNT} repository/repositories..."
  for i in $(seq 0 $(( REPO_COUNT - 1 ))); do
    REPO_NAME=$(echo "$REPOS_JSON" | jq -r ".[$i].name")
    REPO_PATH=$(echo "$REPOS_JSON" | jq -r ".[$i].path")
    REPO_BRANCH=$(echo "$REPOS_JSON" | jq -r ".[$i].branch")
    REPO_URL=$(echo "$REPOS_JSON" | jq -r ".[$i].url")
    HOLD="$(repo_hold_state "$REPO_NAME" "$HOLD_DIR_CONFIG")"
    case "$HOLD" in
      active*)
        warn "  ${REPO_NAME}: pull HELD — ${HOLD#active }; running on what is checked out"
        continue ;;
      expired*)
        warn "  ${REPO_NAME}: the pull hold expired ${HOLD#expired } — removing it and pulling again"
        repo_hold_clear "$REPO_NAME" "$HOLD_DIR_CONFIG" ;;
    esac
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
          2) error "${REPO_NAME}: NOT synced — unpushed commits block the origin change (see above). Push them, or run: site-manager repository modify ${REPO_NAME} --url ${REPO_URL} --force"
             echo "${REPO_NAME}" >> "${_sync_failed}" ;;
          *) warn "Failed to sync ${REPO_NAME}"
             echo "${REPO_NAME}" >> "${_sync_failed}" ;;
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
      echo "${REPO_NAME}" >> "${_sync_failed}"
    fi
  done
else
  info "No repositories configured — pulling TAPPaaS from default location..."
  ( git pull origin ) || warn "Failed to pull TAPPaaS from the default location"
fi
fi

cd "${CICD_DIR}" || die "TAPPaaS-CICD directory not found: ${CICD_DIR}"

# ── 2. Relink the script/lib symlinks into ~/bin ─────────────────────
# NOTE: symlinks must be installed BEFORE refreshing config, so that
# create-configuration.sh in ~/bin/ points to the updated repo version.
info "Installing scripts to ${BIN_DIR}/..."
# scripts/*.sh AND lib/*.sh — mirrors install.sh (ADR-007 S0 moved shared
# sourced libraries to lib/; a system UPDATED across that relocation never
# re-linked them, leaving e.g. apply-json-merge.sh missing from ~/bin and
# every module update silently skipping the 3-way config merge — found on
# the production cluster 2026-07-07).
mkdir -p "${BIN_DIR}"
for script in scripts/*.sh lib/*.sh; do
  if [ -f "$script" ]; then
    script_name=$(basename "$script")
    target="${BIN_DIR}/$script_name"
    # Remove the existing entry first — on NixOS it may be a symlink into a
    # read-only /etc/static/ path (issue #184), which would otherwise make
    # the subsequent chmod fail with EROFS.
    rm -f "$target" 2>/dev/null || true
    src="$(realpath "$script")"
    # chmod the resolved source, not the symlink: chmod follows symlinks,
    # so chmod'ing a ${BIN_DIR}/*.sh symlink that points into
    # /etc/static would still fail. The source lives in the writable repo.
    # #565: only chmod files the repo tracks executable — a sourced lib
    # (linked here so it can be `.`-sourced from ~/bin) stays 100644.
    if tappaas_should_be_executable "$src"; then chmod +x "$src"; fi
    ln -s "$src" "$target"
  fi
done

# ── 3. Build + link every compiled component ─────────────────────────
# ADR-007 S0/P10: the scripts/*.sh glob above only covers scripts NOT yet
# relocated. Every manager/<x>/ and controller/<x>/ component builds and links
# its own bins via its install.sh, driven by the per-directory dispatcher —
# including the COMPILED components (the TS managers, opnsense-controller and
# identity-controller nix builds). Idempotent: nix no-ops when inputs are
# unchanged. A component build failure is reported in the exit code, not raised
# as a hard error — the previous (stale) bins keep working and the Test-11 smoke
# slice is what surfaces a broken build.
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

# Report what actually happened. A failed component build stays non-fatal (see
# the dispatch rationale above), but claiming success afterwards is what let
# #467 run unnoticed: every nightly logged two warnings and then a ✓ line, so
# the mothership's own managers went unbuilt for weeks with no visible signal.
if [ -s "${_sync_failed:-/dev/null}" ]; then
  _stale=""; [ "${_comp_failed}" -gt 0 ] && _stale="; ${_comp_failed} component group(s) STALE"
  error "Control plane NOT current: $(sort -u "${_sync_failed}" | paste -sd, -) did not sync (see above)${_stale}."
  exit 12
fi
if [ "${_comp_failed}" -gt 0 ]; then
  warn "Control plane refreshed, but ${_comp_failed} component group(s) failed to build — those bins are STALE (see warnings above)."
  exit 10
fi
info "${GN}✓${CL} Control plane refreshed (repositories, ~/bin scripts, components)."
