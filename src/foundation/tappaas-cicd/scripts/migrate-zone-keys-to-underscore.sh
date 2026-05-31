#!/usr/bin/env bash
#
# migrate-zone-keys-to-underscore.sh — one-shot rename of zone keys from
# hyphen to underscore on the live operator system (#237).
#
# Runs once per cluster (gated by a marker file in ${CONFIG_DIR}). Rewrites:
#   - ${CONFIG_DIR}/zones.json + zones.json.orig (keys + access-to +
#     pinhole-allowed-from). If apply-zones-merge.sh already brought both old
#     and new zone names in alongside each other, drops the hyphen variant.
#   - Every ${CONFIG_DIR}/<module>.json — zone0/zone1, proxyAllowedZones,
#     discoveryMdns, masquerade, ingress.from/egress.to, trunks0/trunks1
#     (semicolon strings), and any discoveryUdpRelay[].zones[] entries.
#   - Pushes the renamed labels to OPNsense via zone-manager --execute.
#   - Re-registers DNS records (lookup current IP from OPNsense leases for
#     each module's vmname, then dns-manager add new + dns-manager delete old).
#   - Reloads Caddy by running firewall:proxy update-service per affected
#     module (its handle's upstream is regenerated from the new zone0).
#
# The migration is idempotent if the marker is removed, but the safer path
# is to keep the marker file and trust the per-update-tappaas no-op.
#
# Usage:
#   migrate-zone-keys-to-underscore.sh              # apply the migration
#   migrate-zone-keys-to-underscore.sh --dry-run    # report only, do not write
#   migrate-zone-keys-to-underscore.sh --force      # ignore the marker; re-run
#
# Exit codes:
#   0  migrated (or no-op when marker present)
#   1  internal failure (backup written, file unchanged)
#   2  bad arguments
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

readonly MARKER="${CONFIG_DIR}/.migration-237-done"
readonly BACKUP_DIR="${CONFIG_DIR}/.backup-237"
readonly ZONES_CURRENT="${CONFIG_DIR}/zones.json"
readonly ZONES_ORIG="${CONFIG_DIR}/zones.json.orig"

# Rename map. Derived from the upstream source jq filter — kept literal here
# so the helper is self-contained and works even without the source tree
# (e.g. when run in a sandboxed test).
readonly RENAME_MAP='{
  "iot-cams":"iot_cams",
  "iot-cloud":"iot_cloud",
  "iot-local":"iot_local",
  "iot-untrust":"iot_untrust",
  "srv-cust":"srv_cust",
  "srv-dev":"srv_dev",
  "srv-home":"srv_home",
  "srv-work":"srv_work"
}'

indent() { sed 's/^/      /'; }

OPT_DRY_RUN=0
OPT_FORCE=0

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--dry-run|--force]

Rename hyphenated zone keys (srv-home → srv_home, …) across:
    ${ZONES_CURRENT}
    ${ZONES_ORIG}
    ${CONFIG_DIR}/<module>.json    (zone0, zone1, proxyAllowedZones,
                                     discoveryMdns, masquerade, trunks0/1,
                                     ingress.from, egress.to, discoveryUdpRelay[].zones)

Then pushes the renamed interface labels to OPNsense, re-registers DNS
records under the new hostnames, and reloads Caddy so reverse-proxy
upstreams pick up the new internal names.

Options:
    --dry-run   Report what would change; do not write anything.
    --force     Ignore the ${MARKER} marker and re-run.
    -h, --help

Exit codes:
    0  migrated (or already done — marker present)
    1  internal failure
    2  bad arguments
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --dry-run) OPT_DRY_RUN=1; shift ;;
        --force)   OPT_FORCE=1; shift ;;
        *)         error "Unknown argument: $1"; usage; exit 2 ;;
    esac
done

# ── Mutex via marker ─────────────────────────────────────────────────

if [[ -f "${MARKER}" && "${OPT_FORCE}" -eq 0 ]]; then
    debug "  #237 migration already applied (marker: ${MARKER}); skipping"
    exit 0
fi

# ── Backup ───────────────────────────────────────────────────────────

if [[ "${OPT_DRY_RUN}" -eq 0 ]]; then
    info "Backing up live configs to ${BACKUP_DIR}/..."
    mkdir -p "${BACKUP_DIR}"
    for f in "${ZONES_CURRENT}" "${ZONES_ORIG}" "${CONFIG_DIR}"/*.json; do
        [[ -f "$f" ]] || continue
        # Don't backup files under .backup-237 itself
        [[ "$f" == "${BACKUP_DIR}/"* ]] && continue
        cp -a "$f" "${BACKUP_DIR}/$(basename "$f")"
    done
fi

# ── Helpers ──────────────────────────────────────────────────────────

# Rewrite a zones.json shape — keys + access-to + pinhole-allowed-from.
rewrite_zones_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    local tmp
    tmp=$(mktemp)
    jq --argjson m "${RENAME_MAP}" '
        def rename: $m[.] // .;
        def maparr: map(if type == "string" then rename else . end);
        # First: merge the new-name entry over the old-name entry if both exist
        # (apply-zones-merge.sh may have brought both in). New wins; old dropped.
        reduce (keys[] | select($m[.] != null)) as $old (
            .;
            ($m[$old]) as $new
            | if has($new) then
                # Both present: prefer the new entry but adopt anything the old
                # had that the new lacks (defensive).
                .[$new] = (.[$old] + .[$new]) | del(.[$old])
              else
                .[$new] = .[$old] | del(.[$old])
              end
        )
        # Then map access-to and pinhole-allowed-from inside every zone value.
        | with_entries(
            .value.["access-to"] = ((.value.["access-to"] // []) | maparr)
            | .value.["pinhole-allowed-from"] = ((.value.["pinhole-allowed-from"] // []) | maparr)
        )
    ' "$f" > "${tmp}" || { rm -f "${tmp}"; return 1; }
    jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; return 1; }
    if [[ "${OPT_DRY_RUN}" -eq 0 ]]; then
        mv "${tmp}" "$f"
    else
        rm -f "${tmp}"
    fi
}

# Rewrite a single module config (Pattern A-aware via jq_module_write).
# Filter goes BEFORE the jq args per jq_module_write's signature.
rewrite_module_config() {
    local m="$1"
    jq_module_write "$m" '
        def rename: $m[.] // .;
        def rename_semilist:
            if . == null then . else split(";") | map(rename) | join(";") end;
        walk(
            if type == "object" then
                (if has("zone0")  and (.zone0  | type) == "string" then .zone0  |= rename else . end)
                | (if has("zone1")  and (.zone1  | type) == "string" then .zone1  |= rename else . end)
                | (if has("trunks0") and (.trunks0 | type) == "string" then .trunks0 |= rename_semilist else . end)
                | (if has("trunks1") and (.trunks1 | type) == "string" then .trunks1 |= rename_semilist else . end)
                | (if has("proxyAllowedZones") and (.proxyAllowedZones | type) == "array" then .proxyAllowedZones |= map(if type == "string" then rename else . end) else . end)
                | (if has("discoveryMdns")     and (.discoveryMdns     | type) == "array" then .discoveryMdns     |= map(if type == "string" then rename else . end) else . end)
                | (if has("masquerade")        and (.masquerade        | type) == "array" then .masquerade        |= map(if type == "string" then rename else . end) else . end)
                | (if has("from") and (.from | type) == "string" then .from |= rename else . end)
                | (if has("to")   and (.to   | type) == "string" then .to   |= rename else . end)
                | (if has("zones") and (.zones | type) == "array" then .zones |= map(if type == "string" then rename else . end) else . end)
            else . end
        )
    ' --argjson m "${RENAME_MAP}"
}

# Did module M reference any hyphenated zone before rewrite?
module_needs_rewrite() {
    local m="$1"
    local p="${CONFIG_DIR}/${m}.json"
    [[ -f "$p" ]] || return 1
    # Quick pattern check — any of the 8 hyphenated names anywhere in the file
    grep -qE '"(srv-home|srv-work|srv-cust|srv-dev|iot-local|iot-cloud|iot-cams|iot-untrust)"|;(srv-home|srv-work|srv-cust|srv-dev|iot-local|iot-cloud|iot-cams|iot-untrust)|(srv-home|srv-work|srv-cust|srv-dev|iot-local|iot-cloud|iot-cams|iot-untrust);' "$p"
}

# ── Stage 1: rewrite zones.json + zones.json.orig ────────────────────

info "${BOLD}Stage 1: rewriting zones.json + zones.json.orig${CL}"

if [[ ! -f "${ZONES_CURRENT}" ]]; then
    die "  ${ZONES_CURRENT} not found — nothing to migrate"
fi

# Capture the renamed zone names that actually appear in the live file (so
# we know which modules + DNS records need attention).
LIVE_HYPHENATED=$(jq -r '
    keys[] | select(test("-"))
' "${ZONES_CURRENT}" 2>/dev/null | sort -u || true)

if [[ -z "${LIVE_HYPHENATED}" ]]; then
    info "  No hyphenated zone keys in ${ZONES_CURRENT} — migration is a no-op"
else
    info "  Found hyphenated zone keys: $(echo "${LIVE_HYPHENATED}" | tr '\n' ' ')"
fi

if [[ -n "${LIVE_HYPHENATED}" ]]; then
    if rewrite_zones_file "${ZONES_CURRENT}"; then
        info "  ${GN}✓${CL} ${ZONES_CURRENT} rewritten"
    else
        die "  Failed to rewrite ${ZONES_CURRENT}"
    fi
fi

if [[ -f "${ZONES_ORIG}" ]]; then
    if rewrite_zones_file "${ZONES_ORIG}"; then
        info "  ${GN}✓${CL} ${ZONES_ORIG} rewritten"
    else
        die "  Failed to rewrite ${ZONES_ORIG}"
    fi
fi

# ── Stage 2: rewrite every module config ─────────────────────────────

info "${BOLD}Stage 2: rewriting installed module configs${CL}"

# Modules we'll need to touch downstream (for DNS + Caddy reload).
declare -a TOUCHED_MODULES=()

for p in "${CONFIG_DIR}"/*.json; do
    [[ -f "$p" ]] || continue
    bn=$(basename "$p" .json)
    case "$bn" in
        configuration|zones|zones.json|module-fields|firewall.json.bak.*) continue ;;
    esac
    # The auto-load $JSON-on-source path normalizes $1=basename, but doesn't apply
    # here (we're iterating). Use the helper directly per-module.
    if module_needs_rewrite "$bn"; then
        if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
            info "  [dry-run] would rewrite ${bn}.json"
        elif rewrite_module_config "$bn"; then
            info "  ${GN}✓${CL} ${bn}.json rewritten"
            TOUCHED_MODULES+=("$bn")
        else
            warn "  ${bn}.json rewrite failed — left unchanged"
        fi
    fi
done

if [[ "${#TOUCHED_MODULES[@]}" -eq 0 ]]; then
    info "  No installed module configs needed updating"
fi

# ── Stage 3: push renamed labels to OPNsense ─────────────────────────

if [[ "${OPT_DRY_RUN}" -eq 0 && -n "${LIVE_HYPHENATED}" ]]; then
    info "${BOLD}Stage 3: pushing renamed interface labels to OPNsense${CL}"
    if command -v zone-manager >/dev/null 2>&1; then
        # --force-rename-labels: with the labels rewritten in zones.json, this
        # tells zone-manager to PATCH the OPNsense interface description in place.
        if zone-manager --no-ssl-verify --execute --force-rename-labels \
                --zones-file "${ZONES_CURRENT}" 2>&1 | tail -20 | indent; then
            info "  ${GN}✓${CL} zone-manager executed"
        else
            warn "  zone-manager reported issues — review the output above"
        fi
    else
        warn "  zone-manager not in PATH — operator must run manually"
    fi
fi

# ── Stage 4: re-register DNS records ─────────────────────────────────

if [[ "${OPT_DRY_RUN}" -eq 0 && "${#TOUCHED_MODULES[@]}" -gt 0 ]]; then
    info "${BOLD}Stage 4: re-registering DNS records under new hostnames${CL}"
    if ! command -v dns-manager >/dev/null 2>&1; then
        warn "  dns-manager not in PATH — DNS re-registration skipped"
    else
        for m in "${TOUCHED_MODULES[@]}"; do
            # Resolve new zone0
            new_zone=$(read_module_config "$m" 2>/dev/null | jq -r '.zone0 // empty')
            new_vmname=$(read_module_config "$m" 2>/dev/null | jq -r '.vmname // empty')
            [[ -z "${new_zone}" || -z "${new_vmname}" ]] && continue

            # Find the old zone name (reverse map from RENAME_MAP)
            old_zone=$(jq -nr --argjson m "${RENAME_MAP}" --arg n "${new_zone}" '
                $m | to_entries[] | select(.value == $n) | .key' | head -1)
            [[ -z "${old_zone}" || "${old_zone}" == "${new_zone}" ]] && continue

            # Look up the current IP for vmname.old_zone.internal — try the
            # leases DB via OPNsense; if not present, skip and warn.
            ip=$(dig +short A "${new_vmname}.${old_zone}.internal" 2>/dev/null | head -1)
            if [[ -z "${ip}" ]]; then
                warn "  ${new_vmname}: no IP resolvable for ${new_vmname}.${old_zone}.internal — skipping DNS re-registration"
                continue
            fi

            info "  ${new_vmname}: ${BL}${old_zone}${CL} → ${BL}${new_zone}${CL} (ip=${ip})"
            dns-manager --no-ssl-verify add "${new_vmname}" "${new_zone}.internal" "${ip}" \
                2>&1 | indent || warn "    dns-manager add failed"
            dns-manager --no-ssl-verify delete "${new_vmname}" "${old_zone}.internal" \
                2>&1 | indent || warn "    dns-manager delete failed (record may not have existed)"
        done
    fi
fi

# ── Stage 5: reload Caddy reverse-proxy handlers ─────────────────────

if [[ "${OPT_DRY_RUN}" -eq 0 && "${#TOUCHED_MODULES[@]}" -gt 0 ]]; then
    info "${BOLD}Stage 5: refreshing Caddy reverse-proxy upstreams${CL}"
    # Each affected module's firewall:proxy update-service regenerates its
    # Caddy handler upstream from the new zone0, so the hostname in the
    # handler config matches the new DNS record. Modules without a
    # firewall:proxy dependency are silently skipped by the runner.
    for m in "${TOUCHED_MODULES[@]}"; do
        deps=$(read_module_config "$m" 2>/dev/null | jq -r '(.dependsOn // []) | join(",")')
        if [[ ",${deps}," == *",firewall:proxy,"* ]]; then
            location=$(read_module_config "$m" 2>/dev/null | jq -r '.location // ""')
            if [[ -n "${location}" && -x "${location}/../../firewall/services/proxy/update-service.sh" ]]; then
                if /home/tappaas/TAPPaaS/src/foundation/firewall/services/proxy/update-service.sh "$m" 2>&1 | indent; then
                    info "  ${GN}✓${CL} ${m}: Caddy handler refreshed"
                else
                    warn "  ${m}: Caddy handler refresh failed"
                fi
            fi
        fi
    done
fi

# ── Write marker ─────────────────────────────────────────────────────

if [[ "${OPT_DRY_RUN}" -eq 0 ]]; then
    if [[ -z "${LIVE_HYPHENATED}" && "${#TOUCHED_MODULES[@]}" -eq 0 ]]; then
        info "${BOLD}Migration: no changes needed (already on underscore form)${CL}"
    else
        info "${BOLD}Migration complete${CL}"
        info "  Backup at: ${BACKUP_DIR}"
    fi
    {
        echo "# #237 zone-key migration marker"
        echo "completed_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "renamed_zones=$(echo "${LIVE_HYPHENATED}" | tr '\n' ' ')"
        echo "touched_modules=${TOUCHED_MODULES[*]:-}"
    } > "${MARKER}"
else
    info "${BOLD}Dry-run complete — no changes written${CL}"
fi

exit 0
