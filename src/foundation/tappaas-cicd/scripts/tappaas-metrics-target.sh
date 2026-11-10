#!/usr/bin/env bash
#
# tappaas-metrics-target.sh — the metrics pipeline's targets, at the level the
# site, its environments and modules set (ADR-046 D1, D3).
#
#   pve | pbs | all      Proxmox's and PBS's external metric server, pointed at
#                        the logging VM's metrics store while the site's level
#                        is not off, removed when it is. site-manager's
#                        reconcile drives pve, backup-manager's pbs, logging's
#                        update all.
#   guest <module>       a guest's own pipeline: the runtime file its Alloy
#                        reads, for the level the cascade and any timed raise
#                        give now. logging:logs' update and health-manager perf
#                        drive it.
#   site apply           all of it after a site-level change: the store's
#                        identities and retention, the Proxmox and PBS targets,
#                        every guest's pipeline.
#   cost                 what the site's levels cost the store, as JSON.
#   purge <ci-id>        delete the CI's series from both Prometheus instances.
#
# Usage: tappaas-metrics-target.sh <pve|pbs|all> <status|apply>
#        tappaas-metrics-target.sh guest <module> <status|apply>
#        tappaas-metrics-target.sh cost
#        tappaas-metrics-target.sh purge <ci-id>
#   status  prints "<target> <state>" per target (in-sync, missing, stale,
#           unwanted, absent, unknown; a guest: its effective level as JSON);
#           exit 0 when nothing needs doing, 3 when apply would change
#           something, 2 when a target cannot be read
#   apply   converges; exit 0 when every target converged
set -uo pipefail

# shellcheck source=../lib/metrics-shipping.sh
. "${METRICS_SHIPPING_LIB:-${TAPPAAS_BIN:-/home/tappaas/bin}/metrics-shipping.sh}"
# get_all_node_hostnames, read by the library.
# shellcheck source=../lib/common-install-routines.sh
. "${TAPPAAS_BIN:-/home/tappaas/bin}/common-install-routines.sh" 2>/dev/null || true

usage() {
    echo "Usage: $0 <pve|pbs|all> <status|apply> | caddy <status|apply> | guest <module> <status|apply> | site apply | cost | purge <ci-id>" >&2
    exit 64
}

what="${1:-}"
case "${what}" in
    cost) metrics_cost; exit $? ;;
    site)
        [[ "${2:-}" == apply ]] || usage
        rc=0 n=0
        metrics_sync_logging >/dev/null || { echo "could not write the store's identities and retention" >&2; rc=1; }
        for t in pve pbs; do
            s="$("metrics_${t}_state")"
            case "${s}" in unwanted) "remove_metrics_${t}" >/dev/null || rc=1 ;; missing|stale) "apply_metrics_${t}" >/dev/null || rc=1 ;; esac
        done
        # The firewall's Caddy metrics listener, while a published service is at service.
        if [[ -f "$(_ls_config_dir)/network.json" ]]; then
            case "$(caddy_metrics_state)" in unwanted) remove_caddy_metrics >/dev/null || rc=1 ;; missing|stale) apply_caddy_metrics >/dev/null || rc=1 ;; esac
        fi
        for f in "$(_ls_config_dir)"/*.json; do
            m="$(basename "${f}" .json)"
            jq -e '.kind == "vm" or .kind == "lxc"' "${f}" >/dev/null 2>&1 || continue
            log_shipping_wanted "${m}" || continue
            if out="$(apply_metrics_guest "${m}" 2>&1)"; then [[ "${out}" == changed* ]] && n=$((n + 1)); else echo "${m}: ${out##*$'\n'}" >&2; rc=1; fi
        done
        echo "the performance level is applied: the Proxmox and PBS metric servers, the store, ${n} guest pipeline(s) changed"
        exit "${rc}" ;;
    purge) metrics_purge "${2:-}" && echo "deleted the series of ${2:-} from the store and its trends"; exit $? ;;
    guest)
        module="${2:-}" verb="${3:-}"
        [[ -n "${module}" && -f "$(_ls_config_dir)/${module}.json" ]] || { echo "no module '${module}' on this site" >&2; exit 64; }
        case "${verb}" in
            status) metrics_effective "${module}"; exit 0 ;;
            apply)
                apply_metrics_guest "${module}"; rc=$?
                # A published service follows its module's level (ADR-046 P3): the
                # controller's Caddy scrape and probes, and the firewall's listener.
                if [[ "${module}" != "${SERVICE_CONTROLLER}" ]] && jq -e --arg m "${module}" 'any(.[]; .module == $m)' <<<"$(service_routes_json)" >/dev/null 2>&1; then
                    log_shipping_wanted "${SERVICE_CONTROLLER}" && { apply_metrics_guest "${SERVICE_CONTROLLER}" >/dev/null || rc=1; }
                    if [[ -f "$(_ls_config_dir)/network.json" ]]; then
                        case "$(caddy_metrics_state)" in unwanted) remove_caddy_metrics >/dev/null || rc=1 ;; missing|stale) apply_caddy_metrics >/dev/null || rc=1 ;; esac
                    fi
                fi
                exit "${rc}" ;;
            *) usage ;;
        esac ;;
    caddy)
        case "${2:-}" in
            status) caddy_metrics_state; exit 0 ;;
            apply) case "$(caddy_metrics_state)" in unwanted) remove_caddy_metrics ;; missing|stale) apply_caddy_metrics ;; in-sync|absent) echo "caddy metrics: in sync" ;; *) echo "caddy metrics: the firewall did not answer" >&2; exit 2 ;; esac; exit $? ;;
            *) usage ;;
        esac ;;
    pve) targets=(pve) ;; pbs) targets=(pbs) ;; all) targets=(pve pbs) ;;
    *) usage ;;
esac
verb="${2:-}"
case "${verb}" in status|apply) ;; *) usage ;; esac

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
