#!/usr/bin/env bash
#
# migrate-zone-keys-to-camelcase.sh — rename zone keys from snake_case to
# camelCase on the live operator system (convention decided in #278 comment).
#
# Rename map (12 compound zones; single-word zones are unchanged):
#   srv_home    → srvHome      iot_local   → iotLocal
#   srv_work    → srvWork      iot_cloud   → iotCloud
#   srv_cust    → srvCust      iot_cams    → iotCams
#   srv_dev     → srvDev       iot_untrust → iotUntrust
#   srv_test    → srvTest      test_allow_a → testAllowA
#                              test_allow_b → testAllowB
#                              test_pinhole → testPinhole
#
# Stages (same pattern as migrate-zone-keys-to-underscore.sh / #237):
#   1. Backup live configs
#   2. Rewrite zones.json + zones.json.orig (keys + access-to + pinhole-allowed-from)
#   3. Rewrite every installed module config (zone0/1, trunks, arrays, etc.)
#   4. Push renamed labels to OPNsense via zone-manager --force-rename-labels
#   5. Re-register DNS: add new vm.srvHome.internal (canonical) +
#      keep vm.srv_home.internal as compat alias until --cleanup is run
#   6. Refresh Caddy upstreams per affected module (firewall:proxy update-service)
#   7. --verify: confirm DNS resolves under both old and new names for all
#      touched modules; report pass/fail per record
#
# Usage:
#   migrate-zone-keys-to-camelcase.sh              # full migration
#   migrate-zone-keys-to-camelcase.sh --dry-run    # report only, no writes
#   migrate-zone-keys-to-camelcase.sh --verify     # DNS check only (post-migration)
#   migrate-zone-keys-to-camelcase.sh --cleanup    # remove compat DNS aliases
#   migrate-zone-keys-to-camelcase.sh --force      # ignore marker; re-run
#
# Exit codes:
#   0  success (or already done / no-op)
#   1  internal failure
#   2  bad arguments
#   3  --verify found DNS failures (see output)
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

readonly MARKER="${CONFIG_DIR}/.migration-camelcase-done"
readonly BACKUP_DIR="${CONFIG_DIR}/.backup-camelcase"
readonly ZONES_CURRENT="${CONFIG_DIR}/zones.json"
readonly ZONES_ORIG="${CONFIG_DIR}/zones.json.orig"

readonly RENAME_MAP='{
  "srv_home":    "srvHome",
  "srv_work":    "srvWork",
  "srv_cust":    "srvCust",
  "srv_dev":     "srvDev",
  "srv_test":    "srvTest",
  "iot_local":   "iotLocal",
  "iot_cloud":   "iotCloud",
  "iot_cams":    "iotCams",
  "iot_untrust": "iotUntrust",
  "test_allow_a":"testAllowA",
  "test_allow_b":"testAllowB",
  "test_pinhole":"testPinhole"
}'

# Reverse map — new → old (used in --verify and --cleanup).
# Derived at runtime so we don't duplicate the map.
reverse_map() {
    jq -n --argjson m "${RENAME_MAP}" '$m | to_entries | map({key:.value,value:.key}) | from_entries'
}

indent() { sed 's/^/      /'; }

OPT_DRY_RUN=0
OPT_FORCE=0
OPT_VERIFY=0
OPT_CLEANUP=0

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--dry-run|--verify|--cleanup|--force]

Rename zone keys from snake_case to camelCase in:
    ${ZONES_CURRENT}
    ${ZONES_ORIG}
    ${CONFIG_DIR}/<module>.json   (zone0/1, trunks0/1, arrays, ingress/egress)

Then pushes renamed labels to OPNsense, re-registers DNS under new names
(keeping old names as compat aliases), and refreshes Caddy upstreams.

Options:
    --dry-run   Report changes without writing anything.
    --verify    DNS verification only — check both old and new names resolve.
                Run after migration to confirm correctness. Exit 3 on failure.
    --cleanup   Remove compat (old snake_case) DNS aliases after successful
                verification. Run only after --verify passes.
    --force     Ignore the marker file and re-run the migration.
    -h, --help

Exit codes:
    0  success / no-op
    1  internal failure
    2  bad arguments
    3  --verify detected DNS resolution failures
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)    usage; exit 0 ;;
        --dry-run)    OPT_DRY_RUN=1; shift ;;
        --force)      OPT_FORCE=1; shift ;;
        --verify)     OPT_VERIFY=1; shift ;;
        --cleanup)    OPT_CLEANUP=1; shift ;;
        *) error "Unknown argument: $1"; usage; exit 2 ;;
    esac
done

# ── --verify mode ─────────────────────────────────────────────────────

if [[ "${OPT_VERIFY}" -eq 1 ]]; then
    info "${BOLD}Verify: DNS resolution check (old compat + new canonical)${CL}"
    VERIFY_FAIL=0
    RMAP=$(reverse_map)

    while IFS= read -r p; do
        [[ -f "$p" ]] || continue
        bn=$(basename "$p" .json)
        case "$bn" in
            configuration|zones|module-fields|firewall.json.bak.*) continue ;;
        esac
        vmname=$(jq -r '.vmname // empty' "$p" 2>/dev/null)
        new_zone=$(jq -r '.zone0 // empty' "$p" 2>/dev/null)
        [[ -z "${vmname}" || -z "${new_zone}" ]] && continue

        # Only check modules whose zone0 is one of the renamed zones.
        old_zone=$(jq -nr --argjson m "${RMAP}" --arg z "${new_zone}" '$m[$z] // empty')
        [[ -z "${old_zone}" ]] && continue

        new_fqdn="${vmname}.${new_zone}.internal"
        old_fqdn="${vmname}.${old_zone}.internal"

        new_ip=$(dig +short A "${new_fqdn}" 2>/dev/null | head -1)
        old_ip=$(dig +short A "${old_fqdn}" 2>/dev/null | head -1)

        if [[ -n "${new_ip}" ]]; then
            info "  ${GN}✓${CL} ${new_fqdn} → ${new_ip} (canonical)"
        else
            warn "  ${RD}✗${CL} ${new_fqdn} — NOT RESOLVING (canonical record missing)"
            VERIFY_FAIL=1
        fi

        if [[ -n "${old_ip}" ]]; then
            info "  ${GN}✓${CL} ${old_fqdn} → ${old_ip} (compat alias)"
        else
            warn "  ${YW}!${CL} ${old_fqdn} — not resolving (compat alias absent or already removed)"
        fi
    done < <(find "${CONFIG_DIR}" -maxdepth 1 -name '*.json' | sort)

    if [[ "${VERIFY_FAIL}" -eq 1 ]]; then
        error "DNS verify FAILED — one or more canonical records are missing"
        exit 3
    fi
    info "${BOLD}Verify: all canonical records resolve OK${CL}"
    exit 0
fi

# ── --cleanup mode ────────────────────────────────────────────────────

if [[ "${OPT_CLEANUP}" -eq 1 ]]; then
    info "${BOLD}Cleanup: removing compat (snake_case) DNS aliases${CL}"
    if ! command -v dns-manager >/dev/null 2>&1; then
        die "dns-manager not in PATH — cannot remove compat aliases"
    fi
    RMAP=$(reverse_map)
    REMOVED=0

    while IFS= read -r p; do
        [[ -f "$p" ]] || continue
        bn=$(basename "$p" .json)
        case "$bn" in
            configuration|zones|module-fields|firewall.json.bak.*) continue ;;
        esac
        vmname=$(jq -r '.vmname // empty' "$p" 2>/dev/null)
        new_zone=$(jq -r '.zone0 // empty' "$p" 2>/dev/null)
        [[ -z "${vmname}" || -z "${new_zone}" ]] && continue
        old_zone=$(jq -nr --argjson m "${RMAP}" --arg z "${new_zone}" '$m[$z] // empty')
        [[ -z "${old_zone}" ]] && continue

        if dns-manager --no-ssl-verify delete "${vmname}" "${old_zone}.internal" \
                2>&1 | indent; then
            info "  ${GN}✓${CL} removed compat alias ${vmname}.${old_zone}.internal"
            REMOVED=$((REMOVED + 1))
        else
            warn "  ${vmname}.${old_zone}.internal — delete failed or already absent"
        fi
    done < <(find "${CONFIG_DIR}" -maxdepth 1 -name '*.json' | sort)

    info "${BOLD}Cleanup complete — ${REMOVED} compat alias(es) removed${CL}"
    exit 0
fi

# ── Migration guard ───────────────────────────────────────────────────
#
# If the marker exists we do a sweep instead of a full re-run: per-item checks
# in each stage handle idempotency, so only remaining snake_case occurrences
# are touched. Exit 0 immediately only when no snake_case remains anywhere.

OPT_SWEEP=0
if [[ -f "${MARKER}" && "${OPT_FORCE}" -eq 0 ]]; then
    REMAINING=$(grep -rlE \
        '"(srv_home|srv_work|srv_cust|srv_dev|srv_test|iot_local|iot_cloud|iot_cams|iot_untrust|test_allow_a|test_allow_b|test_pinhole)"' \
        "${ZONES_CURRENT}" "${CONFIG_DIR}"/*.json 2>/dev/null \
        | grep -v "^${BACKUP_DIR}/" | wc -l || true)
    if [[ "${REMAINING}" -eq 0 ]]; then
        debug "  camelCase migration already applied, no snake_case remaining — nothing to do"
        exit 0
    fi
    warn "  Marker present but ${REMAINING} file(s) still contain snake_case — running sweep"
    OPT_SWEEP=1
fi

# ── Helpers ───────────────────────────────────────────────────────────

rewrite_zones_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    local tmp
    tmp=$(mktemp)
    jq --argjson m "${RENAME_MAP}" '
        def rename: $m[.] // .;
        def maparr: map(if type == "string" then rename else . end);
        reduce (keys[] | select($m[.] != null)) as $old (
            .;
            ($m[$old]) as $new
            | if has($new) then
                .[$new] = (.[$old] + .[$new]) | del(.[$old])
              else
                .[$new] = .[$old] | del(.[$old])
              end
        )
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

module_needs_rewrite() {
    local m="$1"
    local p="${CONFIG_DIR}/${m}.json"
    [[ -f "$p" ]] || return 1
    grep -qE '"(srv_home|srv_work|srv_cust|srv_dev|srv_test|iot_local|iot_cloud|iot_cams|iot_untrust|test_allow_a|test_allow_b|test_pinhole)"|;(srv_home|srv_work|srv_cust|srv_dev|srv_test|iot_local|iot_cloud|iot_cams|iot_untrust|test_allow_a|test_allow_b|test_pinhole)|(srv_home|srv_work|srv_cust|srv_dev|srv_test|iot_local|iot_cloud|iot_cams|iot_untrust|test_allow_a|test_allow_b|test_pinhole);' "$p"
}

# ── Stage 1: backup ───────────────────────────────────────────────────

info "${BOLD}Stage 1: backup live configs → ${BACKUP_DIR}/${CL}"
if [[ "${OPT_DRY_RUN}" -eq 0 ]]; then
    if [[ "${OPT_SWEEP}" -eq 1 && -d "${BACKUP_DIR}" ]]; then
        info "  Sweep mode — backup already exists at ${BACKUP_DIR}, skipping overwrite"
    else
        mkdir -p "${BACKUP_DIR}"
        for f in "${ZONES_CURRENT}" "${ZONES_ORIG}" "${CONFIG_DIR}"/*.json; do
            [[ -f "$f" ]] || continue
            [[ "$f" == "${BACKUP_DIR}/"* ]] && continue
            cp -a "$f" "${BACKUP_DIR}/$(basename "$f")"
        done
        info "  ${GN}✓${CL} backup complete"
    fi
else
    info "  [dry-run] would backup to ${BACKUP_DIR}"
fi

# ── Stage 2: rewrite zones.json ───────────────────────────────────────

info "${BOLD}Stage 2: rewriting zones.json + zones.json.orig${CL}"

LIVE_SNAKE=$(jq -r --argjson m "${RENAME_MAP}" 'keys[] | select($m[.] != null)' "${ZONES_CURRENT}" 2>/dev/null | sort -u || true)

if [[ -z "${LIVE_SNAKE}" ]]; then
    info "  No snake_case zone keys in ${ZONES_CURRENT} — zones already camelCase or no-op"
else
    info "  Found snake_case keys: $(echo "${LIVE_SNAKE}" | tr '\n' ' ')"
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        info "  [dry-run] would rewrite ${ZONES_CURRENT}"
    elif rewrite_zones_file "${ZONES_CURRENT}"; then
        info "  ${GN}✓${CL} ${ZONES_CURRENT} rewritten"
    else
        die "  Failed to rewrite ${ZONES_CURRENT}"
    fi
fi

if [[ -f "${ZONES_ORIG}" ]]; then
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        info "  [dry-run] would rewrite ${ZONES_ORIG}"
    elif rewrite_zones_file "${ZONES_ORIG}"; then
        info "  ${GN}✓${CL} ${ZONES_ORIG} rewritten"
    else
        warn "  Failed to rewrite ${ZONES_ORIG} — continuing"
    fi
fi

# ── Stage 3: rewrite installed module configs ─────────────────────────

info "${BOLD}Stage 3: rewriting installed module configs${CL}"
declare -a TOUCHED_MODULES=()

for p in "${CONFIG_DIR}"/*.json; do
    [[ -f "$p" ]] || continue
    bn=$(basename "$p" .json)
    case "$bn" in
        configuration|zones|module-fields|firewall.json.bak.*) continue ;;
    esac
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

if [[ "${#TOUCHED_MODULES[@]}" -eq 0 && "${OPT_DRY_RUN}" -eq 0 ]]; then
    info "  No installed module configs needed updating"
fi

# ── Stage 4: push renamed labels to OPNsense ─────────────────────────

if [[ "${OPT_DRY_RUN}" -eq 0 && -n "${LIVE_SNAKE}" ]]; then
    info "${BOLD}Stage 4: pushing renamed labels to OPNsense${CL}"
    if command -v zone-manager >/dev/null 2>&1; then
        # Sweep mode: omit --force-rename-labels — VLAN descriptions and firewall
        # rules are idempotent; interface label rename is disruptive and should
        # not be re-triggered on an already-partially-migrated cluster.
        # Full run (first time, no marker): include --force-rename-labels.
        ZM_FLAGS="--no-ssl-verify --execute --zones-file ${ZONES_CURRENT}"
        if [[ "${OPT_SWEEP}" -eq 0 ]]; then
            ZM_FLAGS="${ZM_FLAGS} --force-rename-labels"
        else
            info "  Sweep mode — skipping --force-rename-labels (already applied or disruptive)"
        fi
        # shellcheck disable=SC2086
        if zone-manager ${ZM_FLAGS} 2>&1 | tail -20 | indent; then
            info "  ${GN}✓${CL} zone-manager executed"
        else
            warn "  zone-manager reported issues — review the output above"
        fi
    else
        warn "  zone-manager not in PATH — operator must run manually"
    fi
elif [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
    ZM_DRY_FLAGS="--force-rename-labels"
    [[ "${OPT_SWEEP}" -eq 1 ]] && ZM_DRY_FLAGS="(sweep: no --force-rename-labels)"
    info "  [dry-run] would run: zone-manager --execute ${ZM_DRY_FLAGS}"
fi

# ── Stage 5: re-register DNS (new canonical + keep old compat alias) ──

info "${BOLD}Stage 5: DNS registration (canonical new + compat old)${CL}"
RMAP=$(reverse_map)

if ! command -v dns-manager >/dev/null 2>&1; then
    warn "  dns-manager not in PATH — DNS registration skipped"
else
    for m in "${TOUCHED_MODULES[@]+"${TOUCHED_MODULES[@]}"}"; do
        new_zone=$(read_module_config "$m" 2>/dev/null | jq -r '.zone0 // empty')
        vmname=$(read_module_config "$m" 2>/dev/null | jq -r '.vmname // empty')
        [[ -z "${new_zone}" || -z "${vmname}" ]] && continue

        old_zone=$(jq -nr --argjson m "${RMAP}" --arg z "${new_zone}" '$m[$z] // empty')
        [[ -z "${old_zone}" || "${old_zone}" == "${new_zone}" ]] && continue

        ip=$(dig +short A "${vmname}.${new_zone}.internal" 2>/dev/null | head -1)
        if [[ -z "${ip}" ]]; then
            ip=$(dig +short A "${vmname}.${old_zone}.internal" 2>/dev/null | head -1)
        fi
        if [[ -z "${ip}" ]]; then
            warn "  ${vmname}: no IP resolvable — skipping DNS registration"
            continue
        fi

        info "  ${vmname}: ${vmname}.${new_zone}.internal (canonical) + ${vmname}.${old_zone}.internal (compat) → ${ip}"
        dns-manager --no-ssl-verify add "${vmname}" "${new_zone}.internal" "${ip}" \
            2>&1 | indent || warn "    add canonical failed"
        dns-manager --no-ssl-verify add "${vmname}" "${old_zone}.internal" "${ip}" \
            2>&1 | indent || warn "    add compat alias failed"
    done
fi

if [[ "${OPT_DRY_RUN}" -eq 1 && "${#TOUCHED_MODULES[@]}" -gt 0 ]]; then
    info "  [dry-run] would register DNS for: ${TOUCHED_MODULES[*]}"
fi

# ── Stage 6: refresh Caddy upstreams ─────────────────────────────────

if [[ "${OPT_DRY_RUN}" -eq 0 && "${#TOUCHED_MODULES[@]}" -gt 0 ]]; then
    info "${BOLD}Stage 6: refreshing Caddy reverse-proxy upstreams${CL}"
    proxy_update="/home/tappaas/TAPPaaS/src/foundation/firewall/services/proxy/update-service.sh"
    if [[ ! -x "${proxy_update}" ]]; then
        warn "  firewall:proxy update-service.sh not found at ${proxy_update}"
    else
        for m in "${TOUCHED_MODULES[@]}"; do
            deps=$(read_module_config "$m" 2>/dev/null | jq -r '(.dependsOn // []) | join(",")')
            if [[ ",${deps}," == *",firewall:proxy,"* ]]; then
                info "  ${m}: refreshing Caddy handler..."
                if "${proxy_update}" "$m" 2>&1 | indent; then
                    info "  ${GN}✓${CL} ${m}: Caddy handler refreshed"
                else
                    warn "  ${m}: Caddy refresh failed — compat DNS alias keeps upstream resolving"
                fi
            fi
        done
    fi
elif [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
    info "  [dry-run] would refresh Caddy upstreams for modules with firewall:proxy dependency"
fi

# ── Stage 7: built-in verify ─────────────────────────────────────────

if [[ "${OPT_DRY_RUN}" -eq 0 && "${#TOUCHED_MODULES[@]}" -gt 0 ]]; then
    info "${BOLD}Stage 7: DNS verification${CL}"
    VERIFY_FAIL=0
    for m in "${TOUCHED_MODULES[@]}"; do
        new_zone=$(read_module_config "$m" 2>/dev/null | jq -r '.zone0 // empty')
        vmname=$(read_module_config "$m" 2>/dev/null | jq -r '.vmname // empty')
        [[ -z "${new_zone}" || -z "${vmname}" ]] && continue

        new_ip=$(dig +short A "${vmname}.${new_zone}.internal" 2>/dev/null | head -1)
        if [[ -n "${new_ip}" ]]; then
            info "  ${GN}✓${CL} ${vmname}.${new_zone}.internal → ${new_ip}"
        else
            warn "  ${RD}✗${CL} ${vmname}.${new_zone}.internal — not resolving"
            VERIFY_FAIL=1
        fi
    done

    if [[ "${VERIFY_FAIL}" -eq 1 ]]; then
        warn "  DNS verify found failures — run with --verify for full detail"
        warn "  Compat aliases remain active. Backup at: ${BACKUP_DIR}"
    else
        info "  ${GN}All canonical records resolve OK${CL}"
    fi
fi

# ── Write marker ──────────────────────────────────────────────────────

if [[ "${OPT_DRY_RUN}" -eq 0 ]]; then
    {
        echo "# camelCase zone-key migration marker"
        echo "completed_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "renamed_zones=$(echo "${LIVE_SNAKE}" | tr '\n' ' ')"
        echo "touched_modules=${TOUCHED_MODULES[*]:-}"
    } > "${MARKER}"
    info "${BOLD}Migration complete. Backup at: ${BACKUP_DIR}${CL}"
    info "  Run --verify for full DNS check, --cleanup to remove compat aliases after testing"
else
    info "${BOLD}Dry-run complete — no changes written${CL}"
fi

exit 0
