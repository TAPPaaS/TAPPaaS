#!/usr/bin/env bash
#
# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# migrate-bootstrap.sh — swap a MAINLINE TAPPaaS cicd onto the ADR-007 toolchain.
#
# WHY THIS EXISTS (the toolchain-swap gap, found on the first real migration test):
# You cannot migrate a mainline node just by pinning the branch and running
# `update-tappaas`. `update-tappaas` calls `~/bin/update-module.sh`, whose
# pre-update.sh does `git checkout <ADR007>` — but the ADR-007 refactor RELOCATED
# the control-plane scripts (`tappaas-cicd/scripts/*` → `manager/`, `lib/`,
# `controller/`). So the moment the branch switches, `~/bin/update-module.sh` (and
# the mainline pre-update logic that is mid-execution, e.g. `cd opnsense-controller`
# which moved to `controller/`) dangle/fail — aborting BEFORE the ADR-007 relink
# runs. The node is left half-migrated: tree on ADR-007, ~/bin dangling, every
# module update failing. A mainline pre-update.sh simply cannot migrate itself
# across the reorg.
#
# This script is the missing FIRST step: run it ONCE on the cicd, from the
# downloaded copy (it is not yet on PATH on a mainline system). It:
#   1. pins the TAPPaaS repo branch to the target (default ADR007) in configuration.json,
#   2. checks out that branch in ~/TAPPaaS (auto-stashing any local changes),
#   3. relinks the two bootstrap bins to their ADR-007 locations,
#   4. runs the ADR-007 tappaas-cicd update (--force) to relink ALL bins + build the
#      controllers (tolerating the pre-migration zones-check gate — the relink
#      completes before it),
#   5. verifies the ADR-007 toolchain resolves.
# Then the operator runs `migrate-to-adr007.sh --yes` (config→site, zones, envs)
# and, when ready, the supervised firewall→network cutover.
#
# Usage:
#   curl -fsSL <RAW>/ADR007/src/foundation/tappaas-cicd/scripts/migrate-bootstrap.sh -o /tmp/mb.sh
#   bash /tmp/mb.sh [--branch ADR007] [--repo-dir /home/tappaas/TAPPaaS]
#
# Run as the tappaas user on the cicd. Exit: 0 ok, 1 error.
#
set -uo pipefail   # NOT -e: best-effort bootstrap; steps warn and continue.

readonly RD=$'\033[01;31m' YW=$'\033[33m' GN=$'\033[1;92m' BL=$'\033[36m' CL=$'\033[m' BOLD=$'\033[1m'
info()  { echo -e "${GN}[migrate-bootstrap]${CL} $*"; }
warn()  { echo -e "${YW}[migrate-bootstrap][warn]${CL} $*"; }
error() { echo -e "${RD}[migrate-bootstrap][error]${CL} $*" >&2; }
die()   { error "$*"; exit 1; }

BRANCH="ADR007"
REPO_DIR="/home/tappaas/TAPPaaS"
BIN_DIR="${HOME}/bin"
CONFIG="${TAPPAAS_CONFIG:-/home/tappaas/config}/configuration.json"
REPO_NAME="TAPPaaS"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)   BRANCH="${2:?}"; shift 2 ;;
    --repo-dir) REPO_DIR="${2:?}"; shift 2 ;;
    --repo-name) REPO_NAME="${2:?}"; shift 2 ;;
    -h|--help)  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required."
[[ -d "$REPO_DIR/.git" ]] || die "Not a git checkout: ${REPO_DIR}"

info "${BOLD}Bootstrapping the ADR-007 toolchain onto this cicd (branch: ${BRANCH}).${CL}"

# ── 1. Pin the repo branch so future pre-update pulls stay on ADR-007 ──
if [[ -f "$CONFIG" ]]; then
  if jq -e --arg n "$REPO_NAME" '.tappaas.repositories[]? | select(.name==$n)' "$CONFIG" >/dev/null 2>&1; then
    tmp="$(mktemp)"
    if jq --arg n "$REPO_NAME" --arg b "$BRANCH" \
         '(.tappaas.repositories[] | select(.name==$n) | .branch) = $b' "$CONFIG" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$CONFIG"; info "  pinned ${REPO_NAME} branch → ${BRANCH} in configuration.json"
    else rm -f "$tmp"; warn "  could not pin the branch in configuration.json (continuing)"; fi
  else warn "  repo '${REPO_NAME}' not found in configuration.json — set repositories[].branch=${BRANCH} by hand if needed"; fi
else info "  no configuration.json (already site.json-native?) — skipping branch pin"; fi

# ── 2. Check out the branch (auto-stash local changes) ───────────────
info "Checking out ${BRANCH} in ${REPO_DIR} ..."
(
  cd "$REPO_DIR" || exit 1
  git fetch origin || warn "  git fetch failed"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    warn "  local changes present — auto-stashing (recover via 'git -C ${REPO_DIR} stash list')"
    git stash push -u -m "migrate-bootstrap auto-stash $(date +%Y%m%d-%H%M%S)" || warn "  stash failed"
  fi
  git checkout "$BRANCH" && git pull origin "$BRANCH" || warn "  checkout/pull ${BRANCH} failed"
)
_cur="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
[[ "$_cur" == "$BRANCH" ]] || die "Tree is on '${_cur}', not '${BRANCH}' — resolve the checkout, then re-run."
info "  ${GN}✓${CL} tree on ${BRANCH}"

# ── 3. Relink the two bootstrap bins to their ADR-007 locations ──────
# Everything else is relinked by the ADR-007 tappaas-cicd update in step 4, but
# that is driven THROUGH update-module.sh — so these two must resolve first.
_um="${REPO_DIR}/src/foundation/tappaas-cicd/manager/module-manager/update-module.sh"
_cir="${REPO_DIR}/src/foundation/tappaas-cicd/lib/common-install-routines.sh"
if [[ -f "$_um" && -f "$_cir" ]]; then
  mkdir -p "$BIN_DIR"
  chmod +x "$_um" "$_cir" 2>/dev/null || true
  ln -sf "$_um"  "${BIN_DIR}/update-module.sh"
  ln -sf "$_cir" "${BIN_DIR}/common-install-routines.sh"
  info "  ${GN}✓${CL} relinked update-module.sh + common-install-routines.sh"
else
  die "ADR-007 layout not found (expected ${_um}) — is ${BRANCH} the right branch?"
fi

# ── 4. Build + relink the full ADR-007 toolchain ─────────────────────
# `update-module.sh tappaas-cicd --force` runs the ADR-007 pre-update.sh, which
# relinks the bins and nix-builds the controllers — but it ABORTS at its
# zones-check gate (the live zones.json is still pre-migration, so the check
# errors) BEFORE the step that rebuilds update-tappaas. So the controllers get
# built here, but update-tappaas is (re)built explicitly in 4b below — otherwise
# the STALE mainline update-tappaas keeps running (it mis-handles site.json /
# zones.rename.json and lacks Phase-0). The zones-check failure is expected.
info "Building + relinking the ADR-007 toolchain (update-module.sh tappaas-cicd --force)..."
info "  (a 'zones-check'/pre-update failure here is expected pre-migration — verifying below)"
"${BIN_DIR}/update-module.sh" tappaas-cicd --force || warn "  tappaas-cicd update returned non-zero (expected: pre-migration zones-check) — continuing"

# ── 4b. Explicitly rebuild + relink update-tappaas ───────────────────
# pre-update.sh's update-tappaas build runs AFTER its zones-check gate, so the
# abort above skips it. Do it here so the operator gets the ADR-007 update-tappaas
# (with Phase 0 + the correct NON_MODULE_JSONS) rather than the stale mainline one.
_ut_dir="${REPO_DIR}/src/foundation/tappaas-cicd/update-tappaas"
if [[ -d "$_ut_dir" ]]; then
  info "Rebuilding update-tappaas (skipped by pre-update's zones-check gate)..."
  if ( cd "$_ut_dir" && nix-build -A default default.nix >/tmp/mb-update-tappaas-build.log 2>&1 ); then
    rm -f "${BIN_DIR}/update-tappaas"
    ln -s "${_ut_dir}/result/bin/update-tappaas" "${BIN_DIR}/update-tappaas"
    info "  ${GN}✓${CL} update-tappaas rebuilt + relinked"
  else
    warn "  update-tappaas nix-build failed (see /tmp/mb-update-tappaas-build.log) — the stale binary may remain"
  fi
else
  warn "  update-tappaas dir not found at ${_ut_dir}"
fi

# ── 5. Verify the toolchain resolves ─────────────────────────────────
info "Verifying the ADR-007 toolchain..."
missing=0
for b in update-module.sh update-tappaas migrate-to-adr007.sh network-manager site-manager module-manager opnsense-controller; do
  t="$(readlink -f "${BIN_DIR}/${b}" 2>/dev/null || true)"
  if [[ -n "$t" && -e "$t" ]]; then info "  ${GN}✓${CL} ${b}"; else warn "  ✗ ${b} not linked"; missing=$((missing+1)); fi
done
echo ""
if [[ $missing -eq 0 ]]; then
  info "${BOLD}${GN}ADR-007 toolchain is live.${CL} Next:"
  info "  1. Migrate the config:  ${BL}migrate-to-adr007.sh --yes${CL}   (config→site.json, zones-init, environments)"
  info "  2. Reconcile modules:   ${BL}update-tappaas --force${CL}"
  info "  3. Firewall→network (supervised, when ready):"
  info "       ${BL}migrate-to-adr007.sh --include-firewall --node <node.mgmt.internal> --dry-run${CL}  then --yes"
else
  die "${missing} toolchain bin(s) not linked — inspect the update-module.sh output above before continuing."
fi
exit 0
