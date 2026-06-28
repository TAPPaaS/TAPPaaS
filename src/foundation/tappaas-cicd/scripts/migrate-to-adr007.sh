#!/usr/bin/env bash
#
# migrate-to-adr007.sh — idempotent orchestrator that converges a TAPPaaS system
# onto the ADR-007 model (site.json + environments + the renamed network module).
#
# ADR-007 P1 (this script) + P2 (a Phase-0 caller inside update-tappaas) close the
# upgrade-path gap documented in docs/design/ADR-007-migration-design.md: a mainline
# system pointed at the ADR007 branch and updated previously got ONLY the
# configuration.json -> site.json step, leaving it with no environments and still on
# firewall.json. This sequences ALL the steps, each guarded so the whole run is a
# no-op on an already-migrated system and resumable after a partial run.
#
# Steps (in order; each is skipped when its result already exists):
#   1. configuration.json -> site.json          (migrate-configuration.sh)
#   2. zones-init --name <site.name>             (network-manager; org-zone setup)
#   3. mgmt + <name> environments                (create-minimal-environments.sh)
#   4. firewall -> network (deployed)            (OPT-IN/supervised; default: detect + warn)
#   5. validate: zones-check + structure audit   (loud on a half-migrated result)
#
# Steps 2 and 3 are guarded together on config/environments/<name>.json (mirroring
# the install.sh bootstrap), and a targeted backup of the mutated state files is
# taken first. The firewall->network step is supervised (it renames the VM and
# touches the OPNsense control lifeline) so it is NEVER run automatically — it only
# runs with --include-firewall + --node, otherwise the script just flags that the
# action is still required (apps keep working meanwhile via the back-compat alias).
#
# Usage: migrate-to-adr007.sh [OPTIONS]
#   --config-dir DIR     config dir (default: ${TAPPAAS_CONFIG:-/home/tappaas/config})
#   --include-firewall   also run the supervised firewall->network deployed rename
#                        (requires --node; keeps the firewall.mgmt.internal lifeline)
#   --node FQDN          Proxmox node FQDN for the firewall step's `qm` calls
#   --dry-run            print what each step WOULD do; change nothing
#   --yes                non-interactive (passed through to sub-steps)
#   -h, --help           show this help
#
# Exit codes:
#   0  fully migrated / clean (or dry-run)
#   1  hard error in a step
#   2  half-migrated — a manual action is still required (e.g. firewall->network)
#
set -euo pipefail

# ── Logging — reuse common-install-routines.sh when present ──────────
if ! declare -F info >/dev/null 2>&1; then
    if [[ -f /home/tappaas/bin/common-install-routines.sh ]]; then
        # shellcheck source=/dev/null
        . /home/tappaas/bin/common-install-routines.sh
    else
        : "${GN:=$'\033[1;92m'}"
        : "${RD:=$'\033[01;31m'}"
        : "${YW:=$'\033[33m'}"
        : "${DGN:=$'\033[32m'}"
        : "${CL:=$'\033[m'}"
        info()  { echo -e "${DGN}[Info]${CL} $*"; }
        debug() { :; }
        warn()  { echo -e "${YW}[Warning]${CL} $*"; }
        error() { echo -e "${RD}[Error]${CL} $*" >&2; }
        die()   { error "$*"; exit 1; }
    fi
fi

command -v jq >/dev/null 2>&1 || die "jq is required but not installed."

# ── Defaults + argument parsing ──────────────────────────────────────
CONFIG_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}"
BIN_DIR="/home/tappaas/bin"
INCLUDE_FIREWALL=0
NODE_FQDN=""
DRY_RUN=0
ASSUME_YES=0

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-dir)       CONFIG_DIR="${2:?--config-dir needs a value}"; shift 2 ;;
        --include-firewall) INCLUDE_FIREWALL=1; shift ;;
        --node)             NODE_FQDN="${2:?--node needs a value}"; shift 2 ;;
        --dry-run)          DRY_RUN=1; shift ;;
        --yes)              ASSUME_YES=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  die "Unknown argument: $1 (try --help)" ;;
    esac
done
CONFIG_DIR="${CONFIG_DIR%/}"
[[ -d "$CONFIG_DIR" ]] || die "config dir not found: ${CONFIG_DIR}"

SITE="${CONFIG_DIR}/site.json"
CONFIGURATION="${CONFIG_DIR}/configuration.json"
ZONES="${CONFIG_DIR}/zones.json"
FW_JSON="${CONFIG_DIR}/firewall.json"
NET_JSON="${CONFIG_DIR}/network.json"
ENV_DIR="${CONFIG_DIR}/environments"

NEEDS_ACTION=0   # set to 1 by a step that requires a follow-up manual action

# ── Helpers ──────────────────────────────────────────────────────────

# Resolve a tool path, preferring ~/bin (the deployed convention) then PATH.
# Under --dry-run we are producing a PLAN, not executing: resolve to the deployed
# ~/bin convention even when the bin isn't present on this host (e.g. a dev
# checkout) so the plan is complete and host-independent (a real run happens on
# the cicd where the bins exist). run() only prints these paths under dry-run.
tool() {
    local t="$1"
    if [[ -x "${BIN_DIR}/${t}" ]]; then printf '%s\n' "${BIN_DIR}/${t}"
    elif command -v "$t" >/dev/null 2>&1; then command -v "$t"
    elif [[ $DRY_RUN -eq 1 ]]; then printf '%s\n' "${BIN_DIR}/${t}"
    else printf '\n'; fi
}

# Run a mutating command — or just print it under --dry-run.
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "  would run: $*"
        return 0
    fi
    "$@"
}

# Derive the installation name: prefer site.json .name, fall back to the first
# label of configuration.json .tappaas.domain (the transition source).
derive_name() {
    local n=""
    [[ -f "$SITE" ]] && n="$(jq -r '.name // empty' "$SITE" 2>/dev/null || true)"
    if [[ -z "$n" && -f "$CONFIGURATION" ]]; then
        n="$(jq -r '.tappaas.domain // empty' "$CONFIGURATION" 2>/dev/null | cut -d. -f1)"
    fi
    printf '%s\n' "$n"
}

# The default environment's public domain lives in configuration.json during the
# transition (site.json deliberately drops it). Empty is fine (mgmt-only).
derive_domain() {
    [[ -f "$CONFIGURATION" ]] && jq -r '.tappaas.domain // empty' "$CONFIGURATION" 2>/dev/null || true
}

backup_state() {
    [[ $DRY_RUN -eq 1 ]] && { info "  would back up zones.json/configuration.json/site.json first"; return 0; }
    local stamp dest
    stamp="$(date +%Y%m%d-%H%M%S)"
    dest="${CONFIG_DIR}/.adr007-backup-${stamp}"
    mkdir -p "$dest"
    local f
    for f in "$ZONES" "$CONFIGURATION" "$SITE"; do
        [[ -f "$f" ]] && cp -a "$f" "${dest}/" 2>/dev/null || true
    done
    info "  backed up zones.json/configuration.json/site.json -> ${dest}"
}

# ── Step 1: configuration.json -> site.json ──────────────────────────
step_site() {
    info "Step 1/5: configuration.json -> site.json"
    if [[ -f "$SITE" ]]; then
        info "  site.json already present — skipping (idempotent)."
        return 0
    fi
    if [[ ! -f "$CONFIGURATION" ]]; then
        die "  neither site.json nor configuration.json in ${CONFIG_DIR} — not a TAPPaaS config dir?"
    fi
    local mig; mig="$(tool migrate-configuration.sh)"
    [[ -n "$mig" ]] || { warn "  migrate-configuration.sh not on PATH — skipping (run again once cicd is updated)."; NEEDS_ACTION=1; return 0; }
    run "$mig" --config-dir "$CONFIG_DIR" \
        || { warn "  site.json migration reported an error — continuing (configuration.json untouched)."; NEEDS_ACTION=1; }
}

# ── Steps 2+3: zones-init + base environments (guarded together) ─────
step_zones_and_envs() {
    local name domain envfile
    name="$(derive_name)"
    domain="$(derive_domain)"
    if [[ -z "$name" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then name="<site.name>"; else
            warn "Steps 2-3/5: cannot derive installation name (no site.json .name yet) — skipping; re-run after Step 1 lands."
            NEEDS_ACTION=1; return 0
        fi
    fi
    envfile="${ENV_DIR}/${name}.json"

    info "Step 2/5: zones-init (org-zone setup for '${name}')"
    info "Step 3/5: base environments (mgmt + ${name})"
    if [[ -f "$envfile" ]]; then
        info "  environments/${name}.json exists — zones-init + environments already done, skipping."
        return 0
    fi

    backup_state

    local nm cme
    nm="$(tool network-manager)"
    cme="$(tool create-minimal-environments.sh)"
    if [[ -z "$nm" || -z "$cme" ]]; then
        warn "  network-manager / create-minimal-environments.sh not on PATH — skipping; re-run once cicd is updated."
        NEEDS_ACTION=1; return 0
    fi

    run "$nm" zones-init --name "$name" --force \
        || { warn "  zones-init reported a non-zero rc — continuing."; NEEDS_ACTION=1; }

    local args=(--name "$name")
    [[ -n "$domain" ]] && args+=(--domain "$domain")
    run "$cme" "${args[@]}" \
        || { warn "  create-minimal-environments reported a non-zero rc — continuing."; NEEDS_ACTION=1; }
}

# ── Step 4: firewall -> network (deployed) — supervised / opt-in ─────
step_firewall() {
    info "Step 4/5: firewall -> network (deployed VM/config rename)"
    if [[ -f "$NET_JSON" && ! -f "$FW_JSON" ]]; then
        info "  network.json present and firewall.json gone — already migrated, skipping."
        return 0
    fi
    if [[ -f "$NET_JSON" && -f "$FW_JSON" ]]; then
        warn "  HALF-MIGRATED: both firewall.json AND network.json exist. update-tappaas"
        warn "  will silently prefer network.json and leave firewall.json a stale orphan."
        warn "  Reconcile by completing/rolling back the firewall->network migration."
        NEEDS_ACTION=1
        return 0
    fi
    if [[ ! -f "$FW_JSON" ]]; then
        info "  no firewall.json and no network.json — nothing to do."
        return 0
    fi
    # firewall.json is still the live network-module config.
    if [[ $INCLUDE_FIREWALL -eq 1 ]]; then
        [[ -n "$NODE_FQDN" ]] || die "  --include-firewall requires --node <FQDN>"
        local mig; mig="$(tool migrate-firewall-to-network.sh)"
        [[ -n "$mig" ]] || { warn "  migrate-firewall-to-network.sh not on PATH — skipping."; NEEDS_ACTION=1; return 0; }
        info "  running supervised firewall->network migration (node ${NODE_FQDN})..."
        local args=(--config-dir "$CONFIG_DIR" --node "$NODE_FQDN")
        [[ $DRY_RUN -eq 1 ]]   && args+=(--dry-run)
        [[ $ASSUME_YES -eq 1 ]] && args+=(--yes)
        "$mig" "${args[@]}" \
            || { warn "  firewall->network migration reported an error."; NEEDS_ACTION=1; }
    else
        warn "  ACTION REQUIRED — this system still runs on firewall.json."
        warn "  The firewall->network deployed rename renames the OPNsense VM and touches"
        warn "  the control lifeline, so it is supervised and NOT run automatically."
        warn "  When ready:  migrate-to-adr007.sh --include-firewall --node <FQDN> --yes"
        warn "  (apps keep working meanwhile via the firewall<->network back-compat alias.)"
        NEEDS_ACTION=1
    fi
}

# ── Step 5: validate the resulting structure ────────────────────────
step_validate() {
    info "Step 5/5: validating ADR-007 structure"
    local issues=()

    if [[ -f "$SITE" ]]; then
        jq empty "$SITE" 2>/dev/null || issues+=("site.json is not valid JSON")
        [[ -n "$(jq -r '.name // empty' "$SITE" 2>/dev/null)" ]] || issues+=("site.json has no .name")
    else
        issues+=("site.json missing")
    fi

    local name; name="$(derive_name)"
    [[ -f "${ENV_DIR}/mgmt.json" ]] || issues+=("environments/mgmt.json missing")
    if [[ -n "$name" && "$name" != "<site.name>" ]]; then
        [[ -f "${ENV_DIR}/${name}.json" ]] || issues+=("environments/${name}.json missing")
    fi

    [[ -f "$FW_JSON" && -f "$NET_JSON" ]] && issues+=("both firewall.json and network.json present (half-migrated)")
    [[ -f "$FW_JSON" && ! -f "$NET_JSON" ]] && issues+=("still on firewall.json (firewall->network not done)")

    # Report-only zones audit (never fatal here). This is a real read of live
    # state, not a planned action, so it only runs when the bin is actually
    # executable — never against the dry-run convention path.
    local nm; nm="$(tool network-manager)"
    if [[ -x "$nm" && -f "$ZONES" ]]; then
        if ! "$nm" zones-check >/dev/null 2>&1; then
            warn "  zones-check reported issues — run 'network-manager zones-check' to review."
        fi
    fi

    if [[ ${#issues[@]} -eq 0 ]]; then
        info "  ${GN:-}✓${CL:-} system is on the ADR-007 model."
    else
        warn "  structure audit found ${#issues[@]} item(s) still pending:"
        local it; for it in "${issues[@]}"; do warn "    - ${it}"; done
        NEEDS_ACTION=1
    fi
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
    info "ADR-007 migration orchestrator (config-dir: ${CONFIG_DIR}${DRY_RUN:+, dry-run})"
    [[ $DRY_RUN -eq 1 ]] && info "  DRY RUN — no changes will be made."

    step_site
    step_zones_and_envs
    step_firewall
    step_validate

    echo ""
    if [[ $NEEDS_ACTION -eq 1 ]]; then
        warn "ADR-007 migration: INCOMPLETE — manual action required (see items above)."
        exit 2
    fi
    info "${GN:-}✓${CL:-} ADR-007 migration: system is fully converged."
    exit 0
}

main
