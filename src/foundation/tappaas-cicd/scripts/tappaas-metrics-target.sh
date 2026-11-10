#!/usr/bin/env bash
#
# tappaas-metrics-target.sh — Proxmox's and PBS's external metric server,
# pointed at the logging VM's metrics store while the site's performance level
# is not off, and removed when it is (ADR-046 D1, P1). site-manager's reconcile
# drives `pve`, backup-manager's `pbs`, logging's update `all`.
#
# Usage: tappaas-metrics-target.sh <pve|pbs|all> <status|apply>
#   status  prints "<target> <state>" per target (in-sync, missing, stale,
#           unwanted, absent, unknown); exit 0 when nothing needs doing,
#           3 when apply would change something, 2 when a target cannot be read
#   apply   converges; exit 0 when every target converged
set -uo pipefail

# shellcheck source=../lib/metrics-shipping.sh
. "${METRICS_SHIPPING_LIB:-${TAPPAAS_BIN:-/home/tappaas/bin}/metrics-shipping.sh}"
# get_all_node_hostnames, read by the library.
# shellcheck source=../lib/common-install-routines.sh
. "${TAPPAAS_BIN:-/home/tappaas/bin}/common-install-routines.sh" 2>/dev/null || true

what="${1:-}" verb="${2:-}"
case "${what}" in pve) targets=(pve) ;; pbs) targets=(pbs) ;; all) targets=(pve pbs) ;;
    *) echo "Usage: $0 <pve|pbs|all> <status|apply>" >&2; exit 64 ;; esac
case "${verb}" in status|apply) ;; *) echo "Usage: $0 <pve|pbs|all> <status|apply>" >&2; exit 64 ;; esac

rc=0
for t in "${targets[@]}"; do
    s="$("metrics_${t}_state")"
    if [[ "${verb}" == status ]]; then
        echo "${t} ${s}"
        case "${s}" in in-sync|absent) ;; unknown) [[ ${rc} -eq 0 ]] && rc=2 ;; *) rc=3 ;; esac
        continue
    fi
    case "${s}" in
        in-sync|absent) ;;
        unknown) echo "${t}: cannot be read — no node answers" >&2; rc=1 ;;
        unwanted) "remove_metrics_${t}" || rc=1 ;;
        *) "apply_metrics_${t}" || rc=1 ;;
    esac
done
exit "${rc}"
