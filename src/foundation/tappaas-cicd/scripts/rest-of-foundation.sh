#!/usr/bin/env bash
#
# TAPPaaS — install the rest of the foundation
#
# Run on the tappaas-cicd mothership AFTER the platform is up (install-platform.sh
# / the chained first-node bootstrap). It installs the foundation modules that sit
# on top of the platform, runs a final system update + tests, and prints a summary.
#
#   backup    Proxmox Backup Server
#   identity  Identity provider (SSO)
#   logging   Loki / Grafana / Promtail
#
# Idempotent: install-module.sh and update-tappaas reconcile an already-installed
# module rather than duplicating it, so this script is safe to re-run.
#
# Usage: rest-of-foundation.sh [--skip-update] [-h|--help]
#
# Exit codes: 0 all good, 1 one or more modules failed.

set -euo pipefail

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

readonly SRC="/home/tappaas/TAPPaaS/src/foundation"
readonly CONFIG_DIR="/home/tappaas/config"
readonly FOUNDATION_MODULES=(backup identity logging)

SKIP_UPDATE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-update) SKIP_UPDATE=1; shift ;;
    -h|--help) echo "Usage: rest-of-foundation.sh [--skip-update]"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$(hostname -s)" == "tappaas-cicd" ]] \
  || warn "Not running on tappaas-cicd — this is meant to run on the mothership."

# install-module.sh reads ./<module>.json from the current directory, so cd in.
install_one() {
  local m="$1"; local dir="${SRC}/${m}"
  echo ""
  info "${BOLD}── Foundation module: ${m} ──${CL}"
  if [[ ! -d "$dir" || ! -f "${dir}/${m}.json" ]]; then
    warn "  ${dir}/${m}.json not found — skipping ${m}"
    return 0
  fi
  # Already installed (deployed config exists)? SKIP — install-module.sh's
  # single-instance guard refuses a re-install, so without this check a re-run
  # of this "idempotent" script failed on every module that succeeded before.
  # (A half-installed module — VM up but a service step failed — is repaired
  # with `update-module.sh <m>`, which re-runs the dependency service installers.)
  if [[ -f "${CONFIG_DIR:-/home/tappaas/config}/${m}.json" ]]; then
    info "  ${m} already installed — skipping (repair/refresh via update-module.sh ${m})"
    return 0
  fi
  # Foundation modules live in the mgmt environment — pass it explicitly (the
  # tier:foundation default resolves to mgmt too, but be explicit + self-documenting).
  ( cd "$dir" && install-module.sh "$m" --environment mgmt ) || { error "  install of ${m} failed"; return 1; }
  info "  ${GN}✓${CL} ${m} installed"
}

# ── Install the foundation modules ───────────────────────────────────
info "${BOLD}Installing the rest of the TAPPaaS foundation${CL} (${FOUNDATION_MODULES[*]})"
declare -a FAILED=()
for m in "${FOUNDATION_MODULES[@]}"; do
  install_one "$m" || FAILED+=("$m")
done

# ── ADR-007 P1: bootstrap the minimum people domain (after identity) ─────
# Once identity (Authentik) is up and config/people is still empty (first
# install), create the minimal org + admin/users groups + installer user and
# sync them into Authentik. Per ADR-007: `people-manager bootstrap` copies
# minimal-org/ into ~tappaas/config/people with the installation name +
# installer identity substituted (the retired user-setup.sh, native since the
# ADR-007 refactor Phase 8.2); `people-manager reconcile --apply` then
# reconciles them into Authentik (via identity-controller). Idempotent: skipped
# once config/people exists, so re-runs never disturb operator-added people.
# (Supersedes the old ADR-006 roles-ensure bootstrap — ADR-007 is authoritative.)
if [[ " ${FAILED[*]} " != *" identity "* ]]; then
  people_dir="${TAPPAAS_CONFIG:-${CONFIG_DIR}}/people"
  if [[ ! -d "$people_dir" || -z "$(ls -A "$people_dir" 2>/dev/null)" ]]; then
    # Installer identity: email from site.json .email (installer_email), the
    # org/domain from the default environment (get_variant_config) and site name
    # (get_site_value) — all fall back to configuration.json.
    inst_email="$(installer_email)"
    inst_domain="$(jq -r '.domain // ""' <<<"$(get_variant_config "" 2>/dev/null || echo '{}')")"
    inst_org="$(get_site_value '.defaultEnvironment // .name' 'name')"  # default org (#426), not the site code
    [[ -n "$inst_org" ]] || inst_org="${inst_domain%%.*}"   # first domain label
    inst_user="${inst_email%@*}"                            # email local-part
    inst_user="$(printf '%s' "$inst_user" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//')"
    if [[ -n "$inst_org" && -n "$inst_user" && -n "$inst_email" ]]; then
      echo ""
      info "${BOLD}── People bootstrap (ADR-007): org=${inst_org} user=${inst_user} ──${CL}"
      if people-manager bootstrap --org "$inst_org" --user "$inst_user" --email "$inst_email"; then
        people-manager reconcile --apply || warn "  people-manager reconcile reported issues — review the output above."
        # Backfill the bootstrap environments' ownerOrg NOW that the org exists.
        # The environment bootstrap (environment-manager add, in install.sh)
        # runs before any organization can exist,
        # so it leaves ownerOrg empty — which fails the environment schema until
        # someone closes the gap (found by the ADR-007 refactor's deep gate:
        # environments stayed invalid forever). This is the moment the reference
        # becomes satisfiable, so close it here via the manager verb.
        for _envf in "${CONFIG_DIR:-/home/tappaas/config}/environments/"*.json; do
          [[ -f "$_envf" ]] || continue
          if [[ -z "$(jq -r '.ownerOrg // empty' "$_envf")" ]]; then
            _envn="$(basename "$_envf" .json)"
            info "  backfilling ownerOrg=${inst_org} on bootstrap environment '${_envn}'"
            environment-manager modify "$_envn" --owner "$inst_org" \
              || warn "  environment-manager modify ${_envn} --owner failed — fix by hand (environment-manager validate will flag it)"
          fi
        done
      else
        warn "  people-manager bootstrap failed — people bootstrap skipped (re-run rest-of-foundation.sh)."
      fi
    else
      warn "  Installer org/user/email not determinable from configuration.json — skipping people bootstrap."
    fi
  else
    info "  config/people already populated — skipping people bootstrap (idempotent)."
  fi
fi

# ── Final system update + regression tests ───────────────────────────
if [[ "$SKIP_UPDATE" == "0" ]]; then
  echo ""
  info "${BOLD}── Final system update + tests (update-tappaas) ──${CL}"
  if command -v update-tappaas >/dev/null 2>&1; then
    # --force: run now regardless of the configured update schedule — at install
    # time we are almost always off-schedule, and update-tappaas would otherwise
    # no-op (should_update_now) and skip the final update + regression tests.
    update-tappaas --force || warn "update-tappaas reported issues — review the output above."
  else
    warn "update-tappaas not found on PATH — skipping the final update."
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────
domain="$(jq -r '.domain // "<not set>"' <<<"$(get_variant_config "" 2>/dev/null || echo '{}')")"
nodes="$(pvesh get /cluster/resources --type node --output-format json 2>/dev/null \
          | jq -r '.[].node' 2>/dev/null | paste -sd', ' - 2>/dev/null || true)"
if [[ -z "$nodes" ]]; then
  nodes="$(tappaas_ssh root@tappaas1.mgmt.internal \
            'pvesh get /cluster/resources --type node --output-format json' 2>/dev/null \
            | jq -r '.[].node' 2>/dev/null | paste -sd', ' - || true)"
fi
installed="$(find "${CONFIG_DIR}" -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null \
              | sed 's/\.json$//' | grep -vE '^(configuration|zones)$' | sort | paste -sd', ' - || true)"

echo ""
if [[ ${#FAILED[@]} -eq 0 ]]; then
  cat <<EOF
${GN}${BOLD}🎉  Congratulations — your TAPPaaS foundation is installed.${CL}

  Cluster nodes : ${nodes:-tappaas1}
  Firewall      : OPNsense at https://10.0.0.1  (managed by tappaas-cicd via API)
  Mothership    : tappaas-cicd  (zone / caddy / rules / dns managers; module installs)
  Domain / TLS  : ${domain}
  Modules       : ${installed:-<none>}

EOF
  exit 0
else
  error "Foundation install incomplete — failed: ${FAILED[*]}"
  warn "Fix the issues above and re-run rest-of-foundation.sh (it is idempotent)."
  exit 1
fi
