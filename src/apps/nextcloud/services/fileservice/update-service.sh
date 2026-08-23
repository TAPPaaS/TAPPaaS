#!/usr/bin/env bash
#
# TAPPaaS Nextcloud Service - Update (the converge)
#
# This is the provider-side converge for an already-installed consumer, and it
# is what both `module modify` and `module reconcile --apply` invoke. It:
#   1. Checks Nextcloud is reachable (warn, not fatal — a re-apply must not fail
#      a whole reconcile because a peer VM is transiently down; install-service.sh
#      keeps the fatal gate for the install-time case).
#   2. Re-applies the ADR-COM-0002 OnlyOffice connector wiring when the consumer
#      declares it.
#
# Step 2 used to live ONLY in install-service.sh (#495), so a consumer whose
# proxyDomain or JWT changed never had the connector re-wired by an update —
# the same defect class as #493/#494 (Nextcloud trusted_domains converging on
# install but not on update).
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-unknown}"

readonly CONFIG_DIR="/home/tappaas/config"
readonly CONSUMER_JSON="${CONFIG_DIR}/${MODULE}.json"
# Resolve Nextcloud's config environment-awarely: a consumer deployed into an
# environment pairs with the same-environment provider; fall back to the shared
# config otherwise. Was .variant until that field was retired (#438).
CONSUMER_ENV=""
[[ -n "${MODULE}" && -f "${CONSUMER_JSON}" ]] && \
    CONSUMER_ENV=$(jq -r '.environment // empty' "${CONSUMER_JSON}" 2>/dev/null || true)
NEXTCLOUD_JSON="${CONFIG_DIR}/$(resolve_provider_module nextcloud "${CONSUMER_ENV}").json"
readonly NEXTCLOUD_JSON

VMNAME=$(jq -r '.vmname' "${NEXTCLOUD_JSON}")
ZONE=$(jq -r '.zone0' "${NEXTCLOUD_JSON}")
INTERNAL_URL="http://${VMNAME}.${ZONE}.internal"

info "nextcloud:fileservice update-service for module: ${MODULE}"

if curl -sf --max-time 10 "${INTERNAL_URL}/status.php" | grep -q '"installed":true'; then
    info "  ${GN}✓${CL} Nextcloud is reachable at ${INTERNAL_URL}"
else
    warn "  Nextcloud not responding at ${INTERNAL_URL}/status.php — connector sync may fail"
fi

# ── Connector wiring (ADR-COM-0002) — declarative, provider-owned ──────────────
# A consumer that wants the OnlyOffice editor DECLARES it in its own manifest, under the
# dependency capability:  config["nextcloud:fileservice"].connector == "onlyoffice".
# Nextcloud (the provider) then owns the wiring:
#   - URLs are DERIVED from the consumer manifest (SSOT) — no readFile, no hardcoding.
#   - the JWT secret is OWNED by the consumer (euro-office auto-generates it in nix on first
#     boot); we READ it once — the single runtime cross-VM step.
#   - we write the 4-var contract to /etc/secrets/onlyoffice.env on the Nextcloud VM; the
#     declarative nextcloud-configure-eurooffice.service applies it idempotently via occ.
# Generic: any onlyoffice consumer reuses this; non-declaring consumers are a no-op.
# CONSUMER_JSON already resolved (readonly) above for the environment-aware provider lookup.
CONNECTOR=""
# Read 'connector' from EITHER the raw manifest (nested under the dependency
# capability) OR the flattened on-disk canonical form (#207): install-module
# renders the consumer JSON to canonical Pattern A, which hoists the
# config["nextcloud:fileservice"].connector field to top-level. Checking both
# keeps this generic converge correct regardless of which form it's handed.
[[ -n "${MODULE}" && -f "${CONSUMER_JSON}" ]] && \
    CONNECTOR=$(jq -r '.config["nextcloud:fileservice"].connector // .connector // empty' "${CONSUMER_JSON}" 2>/dev/null || true)

if [[ "${CONNECTOR}" == "onlyoffice" ]]; then
    info "  ${MODULE} declares an onlyoffice connector — re-applying it (ADR-COM-0002)"

    EO_VMNAME=$(jq -r '.vmname' "${CONSUMER_JSON}")
    EO_ZONE=$(jq -r '.zone0' "${CONSUMER_JSON}")
    # Base domain from the consumer's environment (config/environments/<env>.json
    # via get_variant_config), falling back to legacy configuration.json.
    # get_variant_config takes an ENVIRONMENT name — it read .variant until that
    # field was retired (#438), which resolved a non-default consumer to the
    # DEFAULT environment's domain whenever the mirror was absent.
    TAPPAAS_DOMAIN=$(jq -r '.domain // empty' <<<"$(get_variant_config "${CONSUMER_ENV}" 2>/dev/null || echo '{}')")
    [[ -z "${TAPPAAS_DOMAIN}" ]] && TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' "${CONFIG_DIR}/configuration.json" 2>/dev/null || true)
    EO_HOST="${EO_VMNAME}.${EO_ZONE}.internal"
    NC_HOST="${VMNAME}.${ZONE}.internal"

    # URLs — derived from each module's resolved proxyDomain (the real public route
    # + Nextcloud trusted_domain), NOT <vmname>.<base-domain>. For a variant the
    # proxyDomain is <name>.<variant-domain> (e.g. euro-office.test.gridtefy.com),
    # which differs from <vmname>.<domain> (euro-office-test.gridtefy.com) — using the
    # latter pointed OnlyOffice at a non-trusted host → "DocumentServer unreachable".
    # Fall back to the old form only if no proxyDomain is set. Pattern-A flattens the
    # field to top-level (#207); also accept the nested config form.
    EO_PROXY=$(jq -r '.config["network:proxy"].proxyDomain // .proxyDomain // empty' "${CONSUMER_JSON}" 2>/dev/null || true)
    NC_PROXY=$(jq -r '.config["network:proxy"].proxyDomain // .proxyDomain // empty' "${NEXTCLOUD_JSON}" 2>/dev/null || true)
    EURO_OFFICE_URL="https://${EO_PROXY:-${EO_VMNAME}.${TAPPAAS_DOMAIN}}"
    EURO_OFFICE_INTERNAL_URL="http://${EO_HOST}/"
    NEXTCLOUD_PUBLIC_URL="${NC_PROXY:-${VMNAME}.${TAPPAAS_DOMAIN}}"

    # JWT — owned + generated by euro-office (nix, first boot). Read once.
    JWT_SECRET=$(ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        "tappaas@${EO_HOST}" \
        "sudo grep -h '^JWT_SECRET=' /etc/secrets/euro-office.env 2>/dev/null | cut -d= -f2-" 2>/dev/null || true)

    if [[ -z "${JWT_SECRET}" ]]; then
        warn "  euro-office JWT not available yet on ${EO_HOST} — connector left unconfigured; it will wire on the next nextcloud sync once euro-office has booted."
    else
        # Write the 4-var contract on the Nextcloud VM; the idempotent
        # nextcloud-configure-eurooffice.service applies it via occ.
        if printf 'JWT_SECRET=%s\nEURO_OFFICE_URL=%s\nEURO_OFFICE_INTERNAL_URL=%s\nNEXTCLOUD_PUBLIC_URL=%s\n' \
                "${JWT_SECRET}" "${EURO_OFFICE_URL}" "${EURO_OFFICE_INTERNAL_URL}" "${NEXTCLOUD_PUBLIC_URL}" \
            | ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
                "tappaas@${NC_HOST}" \
                "sudo install -m600 -o root -g root /dev/stdin /etc/secrets/onlyoffice.env && \
                 sudo systemctl restart nextcloud-configure-eurooffice.service"
        then
            info "${GN}✓${CL} onlyoffice connector wired for ${MODULE}"

            # ── Verify the integration actually works ──────────────────────
            # Writing the env and restarting the configure service is NOT proof
            # the connector works. The document server must also be able to pull
            # a document back OUT of Nextcloud (StorageUrl); when it cannot, the
            # connector stores `settings_error` and HIDES the editor entirely —
            # no "open in Euro-Office" action appears, while every service here
            # still reports converged. That exact state survived a full
            # `reconcile --apply` (the error was stale from when Nextcloud was
            # still internal-only), which is precisely what a converge must not
            # allow: success reported over a broken integration.
            #
            # `onlyoffice:documentserver --check` re-runs the round trip and
            # rewrites settings_error. Its stdout is swallowed by the NixOS
            # nextcloud-occ wrapper (systemd-run) when there is no TTY, and its
            # exit code is not a reliable failure signal, so read the resulting
            # settings_error straight from the DB — the authoritative state, and
            # the same route test-service.sh already uses.
            _oo_err=""
            for _attempt in 1 2 3; do
                ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
                    "tappaas@${NC_HOST}" "sudo nextcloud-occ onlyoffice:documentserver --check" \
                    >/dev/null 2>&1 || true
                _oo_err=$(ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
                    "tappaas@${NC_HOST}" \
                    "sudo -u postgres psql -d nextcloud -tAc \"SELECT configvalue FROM oc_appconfig WHERE appid='onlyoffice' AND configkey='settings_error'\"" \
                    2>/dev/null | tr -d '[:space:]') || _oo_err=""
                [[ -z "${_oo_err}" ]] && break
                # The document server may still be booting on a fresh install.
                [[ "${_attempt}" -lt 3 ]] && sleep 15
            done

            if [[ -z "${_oo_err}" ]]; then
                info "${GN}✓${CL} onlyoffice document server round-trip verified"

                # ── Point the document server's splash page at this Nextcloud ──
                # The stock image serves a "Docs installed — now integrate me"
                # page at /welcome/ (and redirects / to it). On a TAPPaaS deploy
                # that is noise, and it is internet-facing whenever the module is
                # published. We own the wiring here (ADR-COM-0002), and this is
                # the only side that knows the Nextcloud public URL.
                #
                # euro-office.nix bind-mounts /etc/euro-office/ds-example.conf
                # over the container's nginx include, so rewriting it + reloading
                # nginx applies without restarting the container (which would cut
                # off live editing sessions). Only rewrite when the content
                # actually changes, so a reconcile is not disruptive.
                _eo_conf=$(printf '%s\n' \
                    "# Managed by nextcloud:fileservice update-service.sh." \
                    "# Redirects the document server's splash page at the Nextcloud it serves." \
                    "location ~ ^(\\/welcome\\/.*)\$ { return 302 https://${NEXTCLOUD_PUBLIC_URL}/; }")

                _eo_remote=$(ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
                    "tappaas@${EO_HOST}" "cat /etc/euro-office/ds-example.conf 2>/dev/null" 2>/dev/null || true)

                if [[ "${_eo_remote}" != "${_eo_conf}" ]]; then
                    if printf '%s\n' "${_eo_conf}" | ssh -o BatchMode=yes -o ConnectTimeout=15 \
                            -o StrictHostKeyChecking=accept-new "tappaas@${EO_HOST}" \
                            "sudo install -m644 -o root -g root /dev/stdin /etc/euro-office/ds-example.conf && \
                             sudo podman exec euro-office nginx -s reload" >/dev/null 2>&1
                    then
                        info "  ${GN}✓${CL} document server splash redirects to https://${NEXTCLOUD_PUBLIC_URL}/"
                    else
                        # Non-fatal: cosmetic. The integration itself is verified above.
                        warn "  could not point the document server splash at Nextcloud on ${EO_HOST} (editing is unaffected)"
                    fi
                fi
            else
                error "  onlyoffice connector is wired but NOT working: ${_oo_err}"
                error "  Nextcloud hides the editor while this is set. Most often the document"
                error "  server cannot reach Nextcloud at StorageUrl — check that ${MODULE} and"
                error "  the Nextcloud module can reach each other (network:rules egress, and"
                error "  network:proxy proxyAllowedZones on BOTH, since the browser loads the"
                error "  editor from the document server's own URL)."
                exit 1
            fi
        else
            warn "  failed to apply onlyoffice.env on ${NC_HOST} — re-run after both VMs are up"
        fi
    fi
fi
