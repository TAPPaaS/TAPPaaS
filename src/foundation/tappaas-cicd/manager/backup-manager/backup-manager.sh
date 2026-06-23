#!/usr/bin/env bash
# backup-manager.sh — TAPPaaS backup hierarchy manager (ADR-007 P9).
#
# Owns the Site -> Environment -> Module backup-policy cascade. Resolves the
# EFFECTIVE backup policy for any module by merging site.json .backup (base,
# .defaultRetention), the module's environment .backup, and the module's own
# .backup (module overrides environment overrides site). Read-only over config;
# delegates live PBS operations to backup-controller / the foundation
# backup/restore.sh.
#
# Subcommands:
#   resolve <module> [--environment <env>]   print the effective policy (JSON)
#   status [--config-dir DIR]                all modules + effective policy
#   restore [args...]                        delegate to backup-restore.sh
#   help
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-cascade.sh
. "${HERE}/lib-cascade.sh"

usage() {
    cat <<'EOF'
Usage: backup-manager <command> [options]

Commands:
  resolve <module> [--environment <env>] [--config-dir DIR]
        Resolve and print the effective backup policy (JSON) for a module by
        cascading site -> environment -> module settings. --environment overrides
        the module's recorded .environment.

  status [--config-dir DIR]
        Print the effective backup policy for every deployed module (one JSON
        object per line: module, enabled, retention, residency, inPbsJob).

  restore [args...]
        Restore operations. Delegates to backup-restore.sh (which wraps the
        foundation backup/restore.sh and backup-controller).

  help  Show this help.

Environment:
  CONFIG_DIR   Config directory (default /home/tappaas/config). --config-dir
               overrides it for a single invocation (used by tests/fixtures).
EOF
}

cmd_resolve() {
    local module="" env_override=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --environment) env_override="$2"; shift 2 ;;
            --config-dir) CONFIG_DIR="$2"; CASCADE_CONFIG_DIR="$2"; export CONFIG_DIR; shift 2 ;;
            -*) echo "Unknown option: $1" >&2; return 2 ;;
            *) module="$1"; shift ;;
        esac
    done
    [[ -n "$module" ]] || { echo "resolve: <module> required" >&2; return 2; }
    bc_resolve "$module" "$env_override"
}

cmd_status() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config-dir) CONFIG_DIR="$2"; CASCADE_CONFIG_DIR="$2"; export CONFIG_DIR; shift 2 ;;
            *) shift ;;
        esac
    done
    exec "${HERE}/backup-status.sh" --config-dir "${CASCADE_CONFIG_DIR}"
}

main() {
    local cmd="${1:-help}"
    [[ $# -gt 0 ]] && shift || true
    case "$cmd" in
        resolve) cmd_resolve "$@" ;;
        status)  cmd_status "$@" ;;
        restore) exec "${HERE}/backup-restore.sh" "$@" ;;
        help|-h|--help) usage ;;
        *) echo "Unknown command: ${cmd}" >&2; usage >&2; return 2 ;;
    esac
}

main "$@"
