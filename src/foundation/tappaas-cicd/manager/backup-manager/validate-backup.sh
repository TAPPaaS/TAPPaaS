#!/usr/bin/env bash
# validate-backup.sh — the backup-manager `validate` verb (ADR-007 P9).
#
# Validates the Site -> Environment -> Module backup hierarchy is consistent.
# Read-only; exits NON-ZERO on any inconsistency. Checks:
#   1. retention strings parse (^[0-9]+[dwmy]$, e.g. 7y, 14d, 6m)
#   2. environment backup.residency is a valid enum (eu-only|global)
#   3. an eu-only environment is NOT targeted at a non-EU offsite
#   4. module backup.enabled:false is honoured (resolves to disabled — reported)
#   5. no dangling target: if any module has backup enabled and is wired into the
#      PBS job, site.backup.target must be set.
#
# Options:
#   --config-dir DIR   config directory (default $CONFIG_DIR or /home/tappaas/config)
#   --quiet            suppress per-check OK lines (errors still printed)
#   -h, --help
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-cascade.sh
. "${HERE}/lib-cascade.sh"

usage() { grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; 1d'; }

QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-dir) CONFIG_DIR="$2"; CASCADE_CONFIG_DIR="$2"; export CONFIG_DIR; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

errors=0
ok()   { [[ "$QUIET" -eq 1 ]] || printf '  ok: %s\n' "$1"; }
err()  { printf '  ERROR: %s\n' "$1" >&2; errors=$((errors + 1)); }

# A retention string is N followed by a unit d/w/m/y (PBS-style shorthand).
retention_valid() { [[ "$1" =~ ^[0-9]+[dwmy]$ ]]; }

site_file="${CASCADE_CONFIG_DIR}/site.json"
env_dir="${CASCADE_CONFIG_DIR}/environments"

# ── 1. site defaultRetention parses ──────────────────────────────────
if [[ -f "$site_file" ]]; then
    sret="$(jq -r '.backup.defaultRetention // "7y"' "$site_file")"
    if retention_valid "$sret"; then ok "site defaultRetention '${sret}' parses"
    else err "site backup.defaultRetention '${sret}' is not a valid retention (expected e.g. 7y, 14d)"; fi
fi

# ── 2/3. environment residency enum + eu-only vs offsite residency ───
offsite="$(jq -r '.backup.offsite // empty' "$site_file" 2>/dev/null || true)"
offsite_res="$(jq -r '.backup.offsiteResidency // "eu-only"' "$site_file" 2>/dev/null || echo eu-only)"
target="$(jq -r '.backup.target // empty' "$site_file" 2>/dev/null || true)"

if [[ -d "$env_dir" ]]; then
    shopt -s nullglob
    for ef in "$env_dir"/*.json; do
        ename="$(basename "$ef" .json)"
        # residency: prefer backup.residency, else dataResidency, else default.
        eres="$(jq -r '(.backup.residency // .dataResidency) // "eu-only"' "$ef")"
        case "$eres" in
            eu-only|global) ok "environment '${ename}' residency '${eres}' valid" ;;
            *) err "environment '${ename}' residency '${eres}' is not a valid enum (eu-only|global)" ;;
        esac
        # eu-only environment must not be backed up to a non-EU offsite.
        if [[ "$eres" == "eu-only" && -n "$offsite" && "$offsite_res" != "eu-only" ]]; then
            err "environment '${ename}' is eu-only but site offsite '${offsite}' is residency '${offsite_res}' (non-EU)"
        fi
        # environment retention (if set) must parse.
        eret="$(jq -r '.backup.retention // empty' "$ef")"
        if [[ -n "$eret" ]] && ! retention_valid "$eret"; then
            err "environment '${ename}' backup.retention '${eret}' is not a valid retention"
        fi
    done
    shopt -u nullglob
fi

# ── 4/5. per-module: enabled honoured, retention parses, dangling target ─
any_enabled_in_job=0
while IFS= read -r module; do
    [[ -n "$module" ]] || continue
    pol="$(bc_resolve "$module")" || { err "could not resolve policy for '${module}'"; continue; }
    enabled="$(jq -r '.enabled' <<<"$pol")"
    mret="$(jq -r '.retention' <<<"$pol")"
    if ! retention_valid "$mret"; then
        err "module '${module}' resolves to invalid retention '${mret}'"
    fi
    if [[ "$enabled" == "false" ]]; then
        ok "module '${module}' backup disabled (honoured)"
    fi
    if [[ "$enabled" == "true" ]] && bc_module_in_pbs_job "$module"; then
        any_enabled_in_job=1
    fi
done < <(bc_list_modules)

if [[ "$any_enabled_in_job" -eq 1 && -z "$target" ]]; then
    err "modules have backup enabled and are wired into the PBS job, but site.backup.target is not set (dangling)"
elif [[ -n "$target" ]]; then
    ok "site backup target '${target}' set"
fi

echo ""
if [[ "$errors" -gt 0 ]]; then
    echo "validate-backup: ${errors} error(s) found" >&2
    exit 1
fi
[[ "$QUIET" -eq 1 ]] || echo "validate-backup: hierarchy consistent"
exit 0
