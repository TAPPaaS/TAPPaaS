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
  ( cd "$dir" && install-module.sh "$m" ) || { error "  install of ${m} failed"; return 1; }
  info "  ${GN}✓${CL} ${m} installed"
}

# ── Install the foundation modules ───────────────────────────────────
info "${BOLD}Installing the rest of the TAPPaaS foundation${CL} (${FOUNDATION_MODULES[*]})"
declare -a FAILED=()
for m in "${FOUNDATION_MODULES[@]}"; do
  install_one "$m" || FAILED+=("$m")
done

# ── Final system update + regression tests ───────────────────────────
if [[ "$SKIP_UPDATE" == "0" ]]; then
  echo ""
  info "${BOLD}── Final system update + tests (update-tappaas) ──${CL}"
  if command -v update-tappaas >/dev/null 2>&1; then
    update-tappaas || warn "update-tappaas reported issues — review the output above."
  else
    warn "update-tappaas not found on PATH — skipping the final update."
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────
domain="$(jq -r '.tappaas.domain // "<not set>"' "${CONFIG_DIR}/configuration.json" 2>/dev/null || echo '<unknown>')"
nodes="$(pvesh get /cluster/resources --type node --output-format json 2>/dev/null \
          | jq -r '.[].node' 2>/dev/null | paste -sd', ' - 2>/dev/null || true)"
if [[ -z "$nodes" ]]; then
  nodes="$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@tappaas1.mgmt.internal \
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

What's next:
  • Add app stacks:  repository.sh add <store> --branch main
                     cd ~/TAPPaaS/src/apps/<name> && install-module.sh <name>
  • If not done yet: set your real domain (create-configuration.sh --update
    --domain <yourdomain>) and add the Caddy DNS-01 provider token so public
    TLS certificates issue.
  • Optional hardening: take tappaas1 off the upstream network so Proxmox is
    reachable only via the mgmt net / firewall / netbird:
        ssh root@tappaas1.mgmt.internal '~/tappaas/config-network.sh --drop-upstream'
EOF
  exit 0
else
  error "Foundation install incomplete — failed: ${FAILED[*]}"
  warn "Fix the issues above and re-run rest-of-foundation.sh (it is idempotent)."
  exit 1
fi
