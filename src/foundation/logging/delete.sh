#!/usr/bin/env bash
#
# TAPPaaS logging module — delete (ADR-046).
#
# Run by `module-manager delete <instance>` while the instance's config still
# exists. Proxmox's and PBS's external metric servers point at this VM's
# metrics store; with the store gone they would fail every push, so they are
# removed here, and the nodes' sampler stops pushing (its config goes with the
# Proxmox target). The syslog forwarders and the logs' credentials are
# logging:logs' to remove, as each consumer's delete does.
#
# Usage: delete.sh <instance>

set -uo pipefail

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. "${TAPPAAS_BIN:-/home/tappaas/bin}/common-install-routines.sh"
# shellcheck source=../tappaas-cicd/lib/metrics-shipping.sh
. "${METRICS_SHIPPING_LIB:-/home/tappaas/bin/metrics-shipping.sh}"

info "Remove the Proxmox and PBS metric servers that point at ${1:-logging}"
if out="$(remove_metrics_pve 2>&1)"; then debug "  ${out}"; else warn "  could not remove Proxmox's metric server: ${out}"; fi
if out="$(remove_metrics_pbs 2>&1)"; then debug "  ${out}"; else warn "  could not remove PBS's metric server: ${out}"; fi
exit 0
