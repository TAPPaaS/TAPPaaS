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

# Merge each node's live tankXY zpools into site.json hardware.nodes[].storagePools.
# migrate-configuration.sh is a pure OFFLINE transform (writes storagePools: []);
# this is the "later step" its field-mapping references — the online discovery
# belongs here in the orchestrator, not in the transform (which must stay
# deterministic/unit-testable). Same query create-site.sh uses (zpool list per
# node, NOT the cluster storage.cfg). Best-effort: an unreachable node keeps [] +
# a warning. No-op when site.json has no nodes.
populate_storage_pools() {
    local nodes host fqdn pools pools_arr tmp
    nodes="$(jq -r '.hardware.nodes[]?.name // empty' "$SITE" 2>/dev/null || true)"
    [[ -n "$nodes" ]] || return 0
    info "  Discovering storagePools per node (zpool list)..."
    while IFS= read -r host; do
        [[ -n "$host" ]] || continue
        fqdn="${host}.mgmt.internal"
        pools="$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            "root@${fqdn}" "zpool list -H -o name 2>/dev/null" 2>/dev/null \
            | grep -E '^tank' | LC_ALL=C sort || true)"
        if [[ -z "$pools" ]]; then
            warn "  ${host}: no tank* pools discovered (unreachable or none) — storagePools left empty; refresh later with 'create-site.sh --force'."
            continue
        fi
        pools_arr="$(printf '%s\n' "$pools" | jq -R . | jq -s 'map(select(length>0))')"
        tmp="$(mktemp "${SITE}.XXXXXX")"
        if jq --arg h "$host" --argjson p "$pools_arr" \
              '.hardware.nodes |= map(if .name == $h then .storagePools = $p else . end)' \
              "$SITE" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$SITE"
            info "  ${host}: storagePools = [${pools//$'\n'/, }]"
        else
            rm -f "$tmp"; warn "  ${host}: failed to merge storagePools into site.json."
        fi
    done <<< "$nodes"
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

    # The "later step": populate storagePools from live per-node discovery
    # (migrate-configuration.sh writes []). Real mode only — under --dry-run the
    # site.json was not written, so nothing to enrich.
    if [[ $DRY_RUN -eq 1 ]]; then
        info "  (dry-run) would discover storagePools per node and merge into site.json"
    elif [[ -f "$SITE" ]]; then
        populate_storage_pools
    fi
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
        # migrate-firewall-to-network.sh is NOT symlinked into ~/bin — it ships in
        # the network module dir. Prefer a real executable there; fall back to the
        # tool() path only so the --dry-run plan stays host-independent.
        local mig; mig="$(tool migrate-firewall-to-network.sh)"
        local _fw2net="${TAPPAAS_REPO:-/home/tappaas/TAPPaaS}/src/foundation/network/migrate-firewall-to-network.sh"
        [[ -x "$_fw2net" ]] && mig="$_fw2net"
        if [[ $DRY_RUN -eq 0 && ! -x "$mig" ]]; then
            warn "  migrate-firewall-to-network.sh not found (~/bin, PATH, or ${_fw2net}) — skipping."; NEEDS_ACTION=1; return 0
        fi
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
# ── Step (env): backfill module .environment on the deployed configs ──
# A fresh ADR-007 install writes `.environment` on every deployed module config
# (foundation-tier → mgmt, apps → the default/org environment) — but a system
# MIGRATED from main has module configs with no `.environment`, so
# `environment-manager reconcile <env> --deep` can't find them. Backfill it here
# using the module's tier from the repository catalog (resolve-module.sh). Only
# touches configs that (a) resolve to a catalog module and (b) have no
# `.environment` yet — idempotent, and never clobbers an operator-set value.
step_backfill_environment() {
    info "Step (env): backfill module .environment on deployed configs"
    if [[ ! -f "$SITE" ]]; then
        [[ $DRY_RUN -eq 1 ]] && { info "  (dry-run) would backfill .environment after site.json exists"; return 0; }
        warn "  no site.json yet — skipping .environment backfill (re-run after Step 1)."; NEEDS_ACTION=1; return 0
    fi
    local _rm="/home/tappaas/bin/resolve-module.sh"
    [[ -x "$_rm" ]] || _rm="$(tool resolve-module.sh)"
    if [[ -z "$_rm" || ! -x "$_rm" ]]; then
        warn "  resolve-module.sh not on PATH — skipping .environment backfill (re-run once cicd is updated)."; NEEDS_ACTION=1; return 0
    fi
    local default_env; default_env="$(jq -r '.name // empty' "$SITE" 2>/dev/null || true)"
    local f m cur tier env tmp changed=0
    for f in "${CONFIG_DIR}"/*.json; do
        [[ -e "$f" ]] || continue
        m="$(basename "$f" .json)"
        cur="$(jq -r '.environment // empty' "$f" 2>/dev/null || true)"
        [[ -z "$cur" ]] || continue   # already set — leave the operator's value
        tier="$("$_rm" "$m" --config-dir "${CONFIG_DIR}" --field tier 2>/dev/null || true)"
        [[ -n "$tier" ]] || continue  # not a catalog module (site.json/zones.json/…) — skip
        if [[ "$tier" == "foundation" ]]; then env="mgmt"; else env="${default_env}"; fi
        [[ -n "$env" ]] || { warn "  ${m}: no default environment (site .name unset) — skipping"; NEEDS_ACTION=1; continue; }
        if [[ $DRY_RUN -eq 1 ]]; then
            info "  (dry-run) would set ${m}.environment = ${env}  (tier=${tier})"; continue
        fi
        tmp="$(mktemp "${f}.XXXXXX")"
        if jq --arg e "$env" '.environment = $e' "$f" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$f"; info "  ${m}.environment = ${env}  (tier=${tier})"; changed=$((changed + 1))
        else
            command rm -f "$tmp"; warn "  ${m}: failed to write .environment"; NEEDS_ACTION=1
        fi
    done
    [[ $DRY_RUN -eq 1 ]] || info "  Backfilled ${changed} module config(s)."
}

# ── Step (people): bootstrap the owner organization + identity ───────
# The migration analogue of rest-of-foundation.sh's fresh-install people
# bootstrap. When config/people is empty, create the owner org (named after the
# site) + installer/root users + the users group + roles via user-setup.sh
# (config only), then push them to the identity service with
# `people-manager reconcile`. site.json's owner/organizations already REFERENCE
# this org (create-site / migrate-configuration set them) — this makes the
# reference real. Idempotent: skipped once config/people exists (never disturbs
# operator-added people). Best-effort: a reconcile failure (identity unreachable)
# leaves the org in config to sync later, and flags a manual follow-up.
step_people_bootstrap() {
    info "Step (people): owner organization + identity"
    local people_dir="${CONFIG_DIR}/people"
    if [[ -d "$people_dir" && -n "$(ls -A "$people_dir" 2>/dev/null)" ]]; then
        info "  config/people already populated — skipping (idempotent)."
        return 0
    fi
    if [[ ! -f "$SITE" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then info "  (dry-run) would bootstrap the owner org from site.json (org=<site.name>)"; return 0; fi
        warn "  no site.json yet — skipping people bootstrap (re-run after Step 1)."; NEEDS_ACTION=1; return 0
    fi
    local org email user
    org="$(jq -r '.name // empty' "$SITE" 2>/dev/null || true)"
    email="$(jq -r '.email // empty' "$SITE" 2>/dev/null || true)"
    user="${email%@*}"
    user="$(printf '%s' "$user" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//')"
    if [[ -z "$org" || -z "$email" || -z "$user" ]]; then
        warn "  cannot derive org/user/email from site.json (org='${org}' user='${user}' email='${email}') — skipping people bootstrap."; NEEDS_ACTION=1; return 0
    fi
    local us pm; us="$(tool user-setup.sh)"; pm="$(tool people-manager)"
    if [[ -z "$us" || -z "$pm" ]]; then
        warn "  user-setup.sh / people-manager not on PATH — skipping people bootstrap."; NEEDS_ACTION=1; return 0
    fi
    info "  Bootstrapping People domain: org=${org} user=${user} email=${email}"
    if run "$us" --org "$org" --user "$user" --email "$email"; then
        run "$pm" reconcile --apply \
            || { warn "  people-manager reconcile reported issues — the org is in config; re-run 'people-manager reconcile --apply' once identity is reachable."; NEEDS_ACTION=1; }
    else
        warn "  user-setup.sh failed — people bootstrap skipped."; NEEDS_ACTION=1
    fi
}

main() {
    # NB: $DRY_RUN is 0/1 — both non-empty — so ${DRY_RUN:+…} always expands. Use a
    # numeric test so the header only says "dry-run" when actually dry-running.
    local _dry=""; [[ $DRY_RUN -eq 1 ]] && _dry=", dry-run"
    info "ADR-007 migration orchestrator (config-dir: ${CONFIG_DIR}${_dry})"
    [[ $DRY_RUN -eq 1 ]] && info "  DRY RUN — no changes will be made."

    step_site
    step_backfill_environment
    step_zones_and_envs
    step_people_bootstrap
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
